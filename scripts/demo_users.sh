#!/usr/bin/env bash
# Create the two demo Viewers (story 2.5, AD-34, A62). Idempotent.
#
#   ./scripts/demo_users.sh
#
# district.d and nurse.phc-a, password demo, Grafana HTTP API only.
# Team names come from heart360tk_schema.org_units and get_access_groups when
# Postgres is reachable, so a renamed demo tree still matches. Otherwise the
# A62 names are used: heart360tk_district_view_patients_district-d and
# heart360tk_facility_view_patients_phc-a.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/h360_env.sh"
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import urllib.parse

GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://localhost:3000").rstrip("/")
ADMIN_USER = os.environ.get("GRAFANA_ADMIN_USER") or os.environ.get("GRAFANA_USER") or "admin"
ADMIN_PASSWORD = os.environ.get("GRAFANA_ADMIN_PASSWORD") or os.environ.get("GRAFANA_PASSWORD") or "admin"
DEFAULT_DSN = (
    "postgres://h360tk_root:NGE5ZjljYjM1ZWEyNDI5N2I0YmZiZGM0"
    "@localhost:5432/heart360tk_database"
)
PASSWORD = "demo"

PEOPLE = (
    {
        "login": "district.d",
        "name": "District D",
        "email": "district.d@localhost",
        "level": "2",
        "slugs": ("district-d", "district_d"),
        "fallback": "heart360tk_district_view_patients_district-d",
    },
    {
        "login": "nurse.phc-a",
        "name": "Nurse PHC-A",
        "email": "nurse.phc-a@localhost",
        "level": "3",
        "slugs": ("phc-a", "phc_a"),
        "fallback": "heart360tk_facility_view_patients_phc-a",
    },
)

LOOKUP_SQL = """
SELECT ou.level::text, ou.id::text, ou.name,
       replace(lower(trim(ou.name)), ' ', '_') AS slug,
       COALESCE(
         (SELECT g.group_name::text
          FROM heart360tk_schema.get_access_groups(ou.id, 'patients') AS g
          WHERE g.group_name =
                'heart360tk_' || hc.var_name || '_view_patients_'
                || replace(lower(trim(ou.name)), ' ', '_')
          LIMIT 1),
         'heart360tk_' || hc.var_name || '_view_patients_'
           || replace(lower(trim(ou.name)), ' ', '_')
       ) AS team
FROM heart360tk_schema.org_units ou
JOIN heart360tk_schema.hierarchy_config hc ON hc.level = ou.level
WHERE replace(lower(trim(ou.name)), ' ', '_')
      IN ('district-d', 'district_d', 'phc-a', 'phc_a')
ORDER BY ou.level, ou.id
"""


def usage():
    print("""Usage: ./scripts/demo_users.sh

Creates Viewers district.d and nurse.phc-a (password demo) and their access
teams. Safe to run again: existing users, teams and memberships are kept.

  GRAFANA_URL                  default http://localhost:3000
  GRAFANA_ADMIN_USER/PASSWORD  default admin/admin
  DATABASE_URL or PGHOST, PGUSER, PGPASSWORD, PGDATABASE, PGPORT
""")
    return 0


def resolve_dsn():
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    if any(os.environ.get(key) for key in ("PGHOST", "PGUSER", "PGPASSWORD", "PGDATABASE", "PGPORT")):
        return None
    return DEFAULT_DSN


def grafana(method, path, payload=None):
    command = [
        "curl", "-sS", "--connect-timeout", "3", "--max-time", "15", "--retry", "0",
        "-u", f"{ADMIN_USER}:{ADMIN_PASSWORD}",
        "-H", "Accept: application/json",
        "-X", method,
        "-w", "\n%{http_code}",
    ]
    if payload is not None:
        command.extend(["-H", "Content-Type: application/json", "-d", json.dumps(payload)])
    command.append(GRAFANA_URL + path)
    proc = subprocess.run(command, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"curl exit {proc.returncode}").strip()
        raise SystemExit(
            f"Grafana is not reachable at {GRAFANA_URL}: {detail}\n"
            "Start the stack and re-run. Not hanging."
        )
    body, _, code = proc.stdout.rpartition("\n")
    try:
        http = int(code.strip())
    except ValueError:
        http = 0
    parsed = None
    if body.strip():
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = None
    return http, parsed, body


def require(http, parsed, body, what):
    if http < 200 or http >= 300:
        message = body.strip()[:300]
        if isinstance(parsed, dict) and parsed.get("message"):
            message = parsed["message"]
        raise SystemExit(f"FAIL {what}: http {http} {message}")
    return parsed


def psql_command():
    # No host psql (a stock Mac): run psql inside the postgres container instead.
    base = ["psql", "-X", "--no-psqlrc", "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t"]
    if shutil.which("psql"):
        return base
    passthrough = [arg for key in ("PGHOST", "PGUSER", "PGPASSWORD", "PGDATABASE", "PGPORT")
                   if os.environ.get(key) for arg in ("-e", key)]
    return ["docker", "exec", "-i", "-e", "PGCONNECT_TIMEOUT=3", *passthrough, os.environ.get("H360_PG_CONTAINER", "postgres"), *base]


def org_rows():
    command = psql_command()
    dsn = resolve_dsn()
    if dsn:
        command.append(dsn)
    command.extend(["-c", LOOKUP_SQL])
    env = os.environ.copy()
    env["PGCONNECT_TIMEOUT"] = "3"
    try:
        proc = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
    except subprocess.TimeoutExpired:
        return None, "database lookup timed out"
    except FileNotFoundError as exc:
        return None, f"{exc.filename} not found"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "psql failed").strip().splitlines()
        return None, detail[-1]
    rows = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        rows.append({
            "level": parts[0],
            "id": parts[1],
            "name": parts[2],
            "slug": parts[3],
            "team": parts[4],
        })
    return rows, ""


def choose_team(person, rows, problem):
    if rows is None:
        return person["fallback"], f"A62 fallback ({problem})"
    matches = [row for row in rows if row["level"] == person["level"] and row["slug"] in person["slugs"]]
    matches.sort(key=lambda row: (0 if row["slug"] == person["slugs"][0] else 1, int(row["id"])))
    if not matches:
        return person["fallback"], "A62 fallback (org unit not in the database)"
    row = matches[0]
    return row["team"], f"org unit {row['name']} id {row['id']}"


def password_works(login):
    proc = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "-u", f"{login}:{PASSWORD}", f"{GRAFANA_URL}/api/user"],
        capture_output=True, text=True, timeout=20,
    )
    return proc.stdout.strip() == "200"


def ensure_person(person, team, source):
    login = person["login"]
    http, parsed, body = grafana("GET", "/api/users/lookup?loginOrEmail=" + urllib.parse.quote(login))
    if http == 404:
        created_http, created, created_body = grafana("POST", "/api/admin/users", {
            "name": person["name"],
            "email": person["email"],
            "login": login,
            "password": PASSWORD,
        })
        require(created_http, created, created_body, f"create user {login}")
        user_id = int(created["id"])
        print(f"created user {login}")
    elif http == 200 and isinstance(parsed, dict) and "id" in parsed:
        user_id = int(parsed["id"])
        print(f"user {login} already exists")
    else:
        require(http, parsed, body, f"lookup user {login}")
        return

    pw_http, pw_parsed, pw_body = grafana(
        "PUT", f"/api/admin/users/{user_id}/password", {"password": PASSWORD}
    )
    if pw_http != 200 and password_works(login):
        # Grafana 12+ refuses a reset to the current password. The password is already right.
        pw_http = 200
    require(pw_http, pw_parsed, pw_body, f"set password for {login}")

    org_http, org, org_body = grafana(
        "GET", "/api/org/users/lookup?loginOrEmail=" + urllib.parse.quote(login)
    )
    if org_http == 404:
        add_http, add, add_body = grafana("POST", "/api/org/users", {
            "loginOrEmail": login,
            "role": "Viewer",
        })
        require(add_http, add, add_body, f"add {login} to the org")
        print(f"{login} added to the org as Viewer")
    elif org_http == 200 and isinstance(org, dict):
        if org.get("role") != "Viewer":
            role_http, role, role_body = grafana(
                "PATCH", f"/api/org/users/{user_id}", {"role": "Viewer"}
            )
            require(role_http, role, role_body, f"set {login} to Viewer")
            print(f"{login} role set to Viewer")
        else:
            print(f"{login} is already a Viewer")
    else:
        require(org_http, org, org_body, f"org lookup {login}")

    query = urllib.parse.urlencode({"name": team})
    team_http, team_body, team_raw = grafana("GET", "/api/teams/search?" + query)
    require(team_http, team_body, team_raw, f"search team {team}")
    teams = team_body.get("teams", []) if isinstance(team_body, dict) else []
    found = next((item for item in teams if item.get("name") == team), None)
    if found:
        team_id = int(found["id"])
        print(f"team {team} already exists ({source})")
    else:
        made_http, made, made_raw = grafana("POST", "/api/teams", {"name": team})
        require(made_http, made, made_raw, f"create team {team}")
        team_id = int(made.get("teamId") or made.get("id"))
        print(f"created team {team} ({source})")

    mem_http, members, mem_raw = grafana("GET", f"/api/teams/{team_id}/members")
    require(mem_http, members, mem_raw, f"list members of {team}")
    if not isinstance(members, list):
        raise SystemExit(f"FAIL members of {team}: unexpected response {mem_raw[:200]}")
    if any(member.get("userId") == user_id or member.get("login") == login for member in members):
        print(f"{login} is already on {team}")
        return
    add_http, add, add_raw = grafana("POST", f"/api/teams/{team_id}/members", {"userId": user_id})
    message = add.get("message", "") if isinstance(add, dict) else ""
    if add_http == 400 and "already" in message.lower():
        print(f"{login} is already on {team}")
        return
    require(add_http, add, add_raw, f"add {login} to {team}")
    print(f"added {login} to {team}")


def main(argv):
    if argv in (["--help"], ["-h"]):
        return usage()
    if argv:
        print(f"unknown arguments: {' '.join(argv)}", file=sys.stderr)
        usage()
        return 2
    try:
        grafana("GET", "/api/health")
    except SystemExit:
        raise
    rows, problem = org_rows()
    if rows is None:
        print(f"database lookup skipped: {problem}")
    for person in PEOPLE:
        team, source = choose_team(person, rows, problem)
        ensure_person(person, team, source)
    print("PASS demo users")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
