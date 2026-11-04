#!/usr/bin/env bash
# Security gate for the HEARTS360 MVP (AD-18, stories 2.7 and 2.11, PD-1).
#
#   ./scripts/verify_security.sh --g1a     floor: Viewer writes through Grafana fail,
#                                          GrafanaApi is absent, function allowlist holds
#   ./scripts/verify_security.sh           full G1b: the floor, plus h360-api /write/call-result
#   ./scripts/verify_security.sh --self-test
#
# The function allowlist is MATRIX and REPORT_CHAT_NAMES in this file.
# Add a new report_* or chat_* name to REPORT_CHAT_NAMES when a migration grants it.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://localhost:3000").rstrip("/")
API_URL = os.environ.get("H360_API_URL", "http://localhost:8090").rstrip("/")
DEFAULT_DSN = (
    "postgres://h360tk_root:NGE5ZjljYjM1ZWEyNDI5N2I0YmZiZGM0"
    "@localhost:5432/heart360tk_database"
)
APP_SCHEMAS = ("heart360tk_schema", "heart360tk_reporting")
ROLES = ("heart360tk_reader", "heart360tk_cached", "grafana_reader", "h360_api")
DATASOURCES = (
    "postgres-hypertension",
    "postgres-hypertension-cached",
    "postgres-grafana",
)

# Exact schema.name(identity args) each login role may EXECUTE.
# Sources: Grant matrix AD-14/15/16, 0.6.5_to_0.6.6.sql, and the invoker
# helpers granted again in 0.6.6_to_0.6.7.sql and 0.6.7_to_0.6.8.sql.
MATRIX = {
    "heart360tk_reader": [
        "heart360tk_schema.get_descendant_ids(integer)",
        "heart360tk_schema.get_ancestor_name(integer, integer)",
        "heart360tk_schema.get_breadcrumb_path(integer)",
        "heart360tk_schema.build_drill_url(integer)",
        "heart360tk_schema.get_child_level_name(integer)",
        "heart360tk_schema.get_access_groups(integer, character varying)",
        "heart360tk_reporting.drug_stock_on_hand_matrix(date, integer)",
        "heart360tk_reporting.drug_stock_patient_days_all(date, integer)",
        "heart360tk_schema.parse_obat(text)",
        "heart360tk_schema.classify_visit_step(bigint)",
    ],
    "heart360tk_cached": [
        "heart360tk_schema.get_descendant_ids(integer)",
        "heart360tk_schema.get_ancestor_name(integer, integer)",
        "heart360tk_schema.get_breadcrumb_path(integer)",
        "heart360tk_schema.build_drill_url(integer)",
        "heart360tk_schema.get_child_level_name(integer)",
        "heart360tk_schema.get_access_groups(integer, character varying)",
        "heart360tk_reporting.drug_stock_on_hand_matrix(date, integer)",
        "heart360tk_reporting.drug_stock_patient_days_all(date, integer)",
    ],
    "grafana_reader": [
        "heart360tk_schema.get_access_groups(integer, character varying)",
        "heart360tk_schema.get_user_visible_org_units(integer)",
        "heart360tk_reporting.start_async_refresh(text)",
    ],
    "h360_api": [
        "heart360tk_schema.h360_access_allows(boolean, text[], integer)",
        "heart360tk_schema.save_call_result(text, bigint, boolean, text[], bigint, text)",
    ],
}

# Add a report_* or chat_* name here when its migration grants EXECUTE.
# Any argument list is accepted, in heart360tk_schema or heart360tk_reporting.
# report_statins_patients is reader-only (AD-27). chat_* is h360_api only (story 6.1).
REPORT_CHAT_NAMES = {
    "heart360tk_reader": [
        "report_window",
        "report_flags",
        "report_adherence",
        "report_adherence_buckets",
        "report_titration",
        "report_fudging",
        "report_fudging_histogram",
        "report_statins",
        "report_statins_patients",
        "report_calling",
        "report_new_patients",
    ],
    "heart360tk_cached": [],
    "grafana_reader": [],
    "h360_api": [
        "report_window",
        "report_flags",
        "report_adherence",
        "report_adherence_buckets",
        "report_titration",
        "report_fudging",
        "report_fudging_histogram",
        "report_statins",
        "report_calling",
        "report_new_patients",
        "chat_control_summary",
        "chat_drug_stock_gate",
        "chat_call_plan",
        "chat_facility_rank_district",
        "chat_new_patient_return",
        "chat_phone_capture",
    ],
}

HTN_SQL = {
    "insert": (
        "INSERT INTO heart360tk_schema.call_results (patient_id, call_date, removed_reason) "
        "SELECT 0, DATE '2000-01-01', 'probe' WHERE false"
    ),
    "update": "UPDATE heart360tk_schema.patients SET patient_name = patient_name WHERE false",
    "delete": "DELETE FROM heart360tk_schema.patients WHERE false",
    "set_config_insert": (
        "WITH cfg AS (SELECT set_config('default_transaction_read_only','off',false) AS v) "
        "INSERT INTO heart360tk_schema.call_results (patient_id, call_date, removed_reason) "
        "SELECT 0, DATE '2000-01-01', cfg.v FROM cfg WHERE false"
    ),
}
GRAFANA_SQL = {
    "insert": 'INSERT INTO grafana_schema."user" (login) SELECT \'probe\' WHERE false',
    "update_user": 'UPDATE grafana_schema."user" SET login = login WHERE false',
    "delete": 'DELETE FROM grafana_schema."user" WHERE false',
    "set_config_insert": (
        "WITH cfg AS (SELECT set_config('default_transaction_read_only','off',false)) "
        'INSERT INTO grafana_schema."user" (login) SELECT \'probe\' FROM cfg WHERE false'
    ),
}

FAILURES = []


def check(name, ok, detail=""):
    suffix = f" ({detail})" if detail else ""
    print(("PASS " if ok else "FAIL ") + name + suffix)
    if not ok:
        FAILURES.append(name)
    return ok


# Longest first so "character varying" wins over a shorter token.
BASE_TYPES = (
    "timestamp with time zone",
    "timestamp without time zone",
    "character varying",
    "double precision",
    "timestamptz",
    "timestamp",
    "smallint",
    "integer",
    "bigint",
    "boolean",
    "varchar",
    "numeric",
    "interval",
    "bytea",
    "jsonb",
    "float8",
    "float4",
    "text",
    "date",
    "json",
    "uuid",
    "real",
    "int",
)
CANON_TYPE = {
    "character varying": "varchar",
    "timestamp with time zone": "timestamptz",
    "timestamp without time zone": "timestamp",
    "double precision": "float8",
    "int": "integer",
}


def split_top_commas(args):
    parts = []
    depth = 0
    start = 0
    for index, char in enumerate(args):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(args[start:index])
            start = index + 1
    tail = args[start:]
    if tail.strip():
        parts.append(tail)
    return parts


def drop_default(arg):
    depth = 0
    lower = arg.lower()
    index = 0
    while index < len(arg):
        char = arg[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif depth == 0 and lower.startswith("default", index):
            before = index == 0 or not (lower[index - 1].isalnum() or lower[index - 1] == "_")
            after = index + 7 == len(arg) or not (lower[index + 7].isalnum() or lower[index + 7] == "_")
            if before and after:
                return arg[:index]
        index += 1
    return arg


def arg_type(arg):
    text = re.sub(r"\s+", " ", drop_default(arg).strip().lower())
    text = re.sub(r"^(?:(?:in|out|inout|variadic)\s+)+", "", text)
    for base in BASE_TYPES:
        match = re.fullmatch(
            rf"(?:[a-z_][a-z0-9_]*\s+)?{re.escape(base)}(?:\(\d+(?:\s*,\s*\d+)?\))?(\s*\[\])?",
            text,
        )
        if match:
            array = "[]" if match.group(1) else ""
            return CANON_TYPE.get(base, base.replace(" ", "")) + array
    collapsed = re.sub(r"\s+", "", text)
    return collapsed


def parse_sig(sig):
    match = re.fullmatch(
        r"\s*(?:([A-Za-z_][A-Za-z0-9_]*)\.)?([A-Za-z_][A-Za-z0-9_]*)\((.*)\)\s*",
        sig,
        re.DOTALL,
    )
    if not match:
        raise ValueError(f"bad signature {sig}")
    schema = (match.group(1) or "").lower()
    name = match.group(2).lower()
    args = ",".join(arg_type(part) for part in split_top_commas(match.group(3)))
    return schema, name, args


def is_allowed(role, sig):
    try:
        schema, name, args = parse_sig(sig)
    except ValueError:
        return False
    full = f"{schema}.{name}({args})" if schema else f"{name}({args})"
    for item in MATRIX.get(role, []):
        item_schema, item_name, item_args = parse_sig(item)
        item_full = f"{item_schema}.{item_name}({item_args})" if item_schema else f"{item_name}({item_args})"
        if item_full == full:
            return True
    return schema in APP_SCHEMAS and name in REPORT_CHAT_NAMES.get(role, [])


def self_test():
    assert is_allowed("h360_api", "heart360tk_schema.save_call_result(text, bigint, boolean, text[], bigint, text)")
    assert not is_allowed("heart360tk_reader", "heart360tk_schema.save_call_result(text, bigint, boolean, text[], bigint, text)")
    assert not is_allowed("heart360tk_cached", "heart360tk_schema.save_call_result(text, bigint, boolean, text[], bigint, text)")
    assert not is_allowed("grafana_reader", "heart360tk_schema.h360_access_allows(boolean, text[], integer)")
    assert is_allowed("heart360tk_reader", "heart360tk_schema.report_statins_patients(date, integer)")
    assert not is_allowed("h360_api", "heart360tk_reporting.report_statins_patients(date, integer)")
    assert is_allowed("h360_api", "heart360tk_schema.report_fudging(date, integer)")
    assert is_allowed("grafana_reader", "heart360tk_reporting.start_async_refresh(text)")
    assert not is_allowed("heart360tk_reader", "heart360tk_reporting.start_async_refresh(text)")
    assert not is_allowed("heart360tk_reader", "heart360tk_schema.drug_stock_pull_apply(jsonb)")
    assert not is_allowed("heart360tk_cached", "heart360tk_schema.drug_stock_pull_apply(jsonb)")
    assert not is_allowed("h360_api", "heart360tk_schema.drug_stock_pull_apply(jsonb)")
    assert not is_allowed("heart360tk_reader", "heart360tk_reporting.delete_leaf_node_data(integer)")
    assert not is_allowed("heart360tk_reader", "heart360tk_schema.h360tk_admin_clean_data()")
    assert is_allowed("h360_api", "heart360tk_schema.chat_call_plan(date, integer)")
    assert not is_allowed("heart360tk_reader", "heart360tk_schema.chat_call_plan(integer, date)")
    assert is_allowed("heart360tk_reader", "heart360tk_schema.get_access_groups(integer, character varying)")
    assert is_allowed("heart360tk_cached", "heart360tk_reporting.drug_stock_patient_days_all(date, integer)")
    assert not is_allowed("h360_api", "heart360tk_schema.parse_obat(text)")
    # This server's pg_get_function_identity_arguments keeps argument names.
    assert is_allowed(
        "heart360tk_reader",
        "heart360tk_schema.get_descendant_ids(p_parent_id integer)",
    )
    assert is_allowed(
        "heart360tk_reader",
        "heart360tk_schema.get_access_groups(p_org_unit_id integer, p_access_type character varying)",
    )
    assert is_allowed(
        "heart360tk_cached",
        "heart360tk_reporting.drug_stock_on_hand_matrix(p_reporting_month date, p_org_unit_id integer)",
    )
    assert is_allowed(
        "grafana_reader",
        "heart360tk_reporting.start_async_refresh(p_user text DEFAULT NULL::text)",
    )
    assert not is_allowed(
        "heart360tk_cached",
        "heart360tk_reporting.delete_leaf_node_data(p_source_keys text[], p_delete_hierarchy boolean, p_purge_everything boolean)",
    )
    assert not is_allowed(
        "heart360tk_cached",
        "heart360tk_reporting.start_async_refresh(p_user text)",
    )
    assert not is_allowed("heart360tk_reader", "not a signature")
    print("PASS allowlist self-test")
    return 0


def usage():
    print("""Usage:
  ./scripts/verify_security.sh --g1a       Viewer SQL writes, GrafanaApi, function allowlist
  ./scripts/verify_security.sh             full gate, including POST /write/call-result
  ./scripts/verify_security.sh --self-test allowlist rules only (no Grafana, no database)

Allowlist (edit in this file when a migration grants a new function):
  MATRIX               exact signatures from AD-14/15/16 and 0.6.5_to_0.6.6.sql
  REPORT_CHAT_NAMES    report_* and chat_* names added in one place

Environment:
  GRAFANA_URL                 default http://localhost:3000
  GRAFANA_ADMIN_USER/PASSWORD default admin/admin (also GRAFANA_USER/GRAFANA_PASSWORD)
  GRAFANA_USERS               optional user:pass,user:pass replacing the default list
  H360_API_URL                default http://localhost:8090
  DATABASE_URL or PGHOST, PGUSER, PGPASSWORD, PGDATABASE, PGPORT
""")
    return 0


def resolve_dsn():
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    if any(os.environ.get(key) for key in ("PGHOST", "PGUSER", "PGPASSWORD", "PGDATABASE", "PGPORT")):
        return None
    return DEFAULT_DSN


def curl(args, timeout=15):
    command = [
        "curl", "-sS", "--connect-timeout", "3", "--max-time", str(timeout),
        "--retry", "0", "-w", "\n%{http_code}",
    ] + args
    proc = subprocess.run(command, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"curl exit {proc.returncode}").strip()
        raise ConnectionError(detail)
    body, _, code = proc.stdout.rpartition("\n")
    try:
        http = int(code.strip())
    except ValueError:
        http = 0
    return http, body


def reachable(url, label):
    try:
        curl(["-o", "/dev/null", url], timeout=5)
        return True
    except ConnectionError as exc:
        print(f"{label} is not reachable at {url}: {exc}", file=sys.stderr)
        print("Start the stack and re-run. Not hanging.", file=sys.stderr)
        return False


def users():
    raw = os.environ.get("GRAFANA_USERS", "").strip()
    if raw:
        parsed = []
        for part in raw.split(","):
            login, sep, password = part.strip().partition(":")
            if not sep or not login:
                raise SystemExit(f"GRAFANA_USERS entry {part!r} must be login:password")
            parsed.append((login, password, True))
        return parsed
    admin = os.environ.get("GRAFANA_ADMIN_USER") or os.environ.get("GRAFANA_USER") or "admin"
    password = os.environ.get("GRAFANA_ADMIN_PASSWORD") or os.environ.get("GRAFANA_PASSWORD") or "admin"
    return [(admin, password, True), ("district.d", "demo", False), ("nurse.phc-a", "demo", False)]


def login(login_name, password):
    jar = tempfile.NamedTemporaryFile(prefix="h360-grafana-", delete=False)
    jar.close()
    http, body = curl([
        "-c", jar.name, "-b", jar.name,
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"user": login_name, "password": password}),
        GRAFANA_URL + "/login",
    ])
    session = "grafana_session" in Path(jar.name).read_text(errors="replace")
    if http in (200, 302) and session:
        return jar.name
    Path(jar.name).unlink(missing_ok=True)
    return None


def post_sql(jar, uid, sql):
    payload = {
        "from": "1761955200000",
        "to": "1793491200000",
        "queries": [{
            "refId": "A",
            "datasource": {"type": "grafana-postgresql-datasource", "uid": uid},
            "rawSql": sql,
            "format": "table",
            "rawQuery": True,
            "editorMode": "code",
        }],
    }
    return curl([
        "-b", jar,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-d", json.dumps(payload),
        GRAFANA_URL + "/api/ds/query",
    ])


def write_was_allowed(http, body):
    """True when the SQL write was accepted. HTTP 401 is a dead session, not a SQL refusal."""
    if http == 401:
        return None, "session was not accepted"
    if http != 200:
        snippet = " ".join(body.split())[:180]
        return False, f"http {http} {snippet}".strip()
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return False, "non-json http 200"
    results = data.get("results")
    if not isinstance(results, dict) or not results:
        message = data.get("message") or "http 200 with no result frame"
        return False, str(message)[:180]
    for item in results.values():
        if not isinstance(item, dict):
            continue
        if item.get("error"):
            return False, str(item["error"])[:180]
        status = item.get("status", 200)
        if isinstance(status, int) and status >= 400:
            return False, f"status {status}"
    return True, "query returned without an error"


def datasource_writes(sessions):
    for login_name, jar in sessions:
        for uid in DATASOURCES:
            probes = GRAFANA_SQL if uid == "postgres-grafana" else HTN_SQL
            for probe, sql in probes.items():
                name = f"{probe} {uid} as {login_name}"
                try:
                    http, body = post_sql(jar, uid, sql)
                except ConnectionError as exc:
                    check(name, False, f"Grafana request failed: {exc}")
                    continue
                allowed, detail = write_was_allowed(http, body)
                if allowed is None:
                    check(name, False, detail)
                else:
                    check(name, not allowed, detail)


def grafana_api_absent(jar):
    try:
        http, body = curl([
            "-b", jar, "-H", "Accept: application/json",
            GRAFANA_URL + "/api/datasources",
        ])
    except ConnectionError as exc:
        check("GrafanaApi absent", False, str(exc))
        return
    if http != 200:
        check("GrafanaApi absent", False, f"GET /api/datasources http {http}")
        return
    try:
        rows = json.loads(body)
    except json.JSONDecodeError:
        check("GrafanaApi absent", False, "datasources response was not JSON")
        return
    names = []
    for row in rows if isinstance(rows, list) else []:
        if row.get("name") == "GrafanaApi" or row.get("uid") == "GrafanaApi":
            names.append(row.get("name") or row.get("uid"))
    check("GrafanaApi absent", not names, ", ".join(names))


def psql(sql):
    command = ["psql", "-X", "--no-psqlrc", "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t"]
    dsn = resolve_dsn()
    if dsn:
        command.append(dsn)
    command.extend(["-c", sql])
    env = os.environ.copy()
    env["PGCONNECT_TIMEOUT"] = "3"
    proc = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"psql exit {proc.returncode}").strip()
        raise RuntimeError(detail.splitlines()[-1])
    return proc.stdout.strip()


def allowlist():
    try:
        for role in ROLES:
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", role):
                check(f"allowlist {role}", False, "unsafe role name")
                continue
            exists = psql(f"SELECT 1 FROM pg_roles WHERE rolname = '{role}'")
            if exists != "1":
                check(f"allowlist {role}", False, "role does not exist; apply 0.6.5_to_0.6.6")
                continue
            rows = psql(
                "SELECT n.nspname || '.' || p.proname || '(' || "
                "pg_get_function_identity_arguments(p.oid) || ')' "
                "FROM pg_proc p "
                "JOIN pg_namespace n ON n.oid = p.pronamespace "
                "WHERE n.nspname IN ('heart360tk_schema', 'heart360tk_reporting') "
                f"AND has_function_privilege('{role}', p.oid, 'EXECUTE') "
                "ORDER BY 1"
            )
            extra = []
            held = [line for line in rows.splitlines() if line.strip()]
            for sig in held:
                if not is_allowed(role, sig):
                    extra.append(sig)
            if extra:
                check(f"allowlist {role}", False, "unexpected EXECUTE " + "; ".join(extra))
            else:
                check(f"allowlist {role}", True, f"{len(held)} functions")
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        check("allowlist", False, f"postgres: {exc}")


def snapshot():
    text = psql(
        "SELECT (SELECT count(*) FROM heart360tk_schema.call_results), "
        "(SELECT count(*) FROM heart360tk_schema.call_results_audit)"
    )
    calls, _, audits = text.partition("|")
    if not calls or not audits:
        calls, audits = text.split("\t")
    return int(calls), int(audits)


def patients():
    text = psql("""
WITH target AS (
  SELECT ou.id
  FROM heart360tk_schema.org_units ou
  WHERE ou.level = 3
    AND replace(lower(trim(ou.name)), ' ', '_') IN ('phc-a', 'phc_a')
  ORDER BY CASE replace(lower(trim(ou.name)), ' ', '_') WHEN 'phc-a' THEN 0 ELSE 1 END, ou.id
  LIMIT 1
),
tree AS (
  SELECT d.id FROM heart360tk_schema.get_descendant_ids((SELECT id FROM target)) AS d
)
SELECT
  COALESCE((SELECT id FROM target), 0),
  COALESCE((SELECT p.patient_id FROM heart360tk_schema.patients p
            WHERE p.org_unit_id IN (SELECT id FROM tree)
            ORDER BY p.patient_id LIMIT 1), 0),
  COALESCE((SELECT p.patient_id FROM heart360tk_schema.patients p
            WHERE p.org_unit_id IS NOT NULL
              AND p.org_unit_id NOT IN (SELECT id FROM tree)
            ORDER BY p.patient_id LIMIT 1), 0)
""")
    parts = re.split(r"[\t|]", text)
    if len(parts) != 3:
        raise RuntimeError(f"unexpected patient lookup {text!r}")
    return tuple(int(part) for part in parts)


def post_write(patient_id, jar=None, origin=None):
    args = [
        "-H", "Content-Type: application/json",
        "-H", "X-H360-Request: 1",
        "-H", "Accept: application/json",
        "-d", json.dumps({"patient_id": str(patient_id), "status": "Pending to call"}),
    ]
    if origin:
        args[0:0] = ["-H", f"Origin: {origin}"]
    if jar:
        args[0:0] = ["-b", jar]
    return curl(args + [API_URL + "/write/call-result"])


def write_path(sessions):
    nurse = dict(sessions).get("nurse.phc-a")
    if not nurse:
        check("write path nurse.phc-a", False, "user is missing; run scripts/demo_users.sh")
        return
    try:
        before_calls, before_audits = snapshot()
        facility_id, allowed_id, foreign_id = patients()
    except (RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
        check("write path database", False, str(exc))
        return
    if not allowed_id or not foreign_id:
        check(
            "write path patients",
            False,
            f"need one patient inside PHC-A and one outside (facility {facility_id}, "
            f"inside {allowed_id}, outside {foreign_id})",
        )
        return

    def unchanged(name):
        try:
            calls, audits = snapshot()
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            check(name + " no row", False, str(exc))
            return
        check(name + " no new call_results", calls == before_calls, f"count {calls} was {before_calls}")
        check(name + " no new audit", audits == before_audits, f"count {audits} was {before_audits}")

    try:
        http, body = post_write(allowed_id)
    except ConnectionError as exc:
        check("write no cookie", False, str(exc))
        return
    check("write no cookie", http == 401, f"http {http} {body[:120]}")
    unchanged("write no cookie")

    try:
        http, body = post_write(allowed_id, jar=nurse, origin="https://evil.example")
    except ConnectionError as exc:
        check("write foreign origin", False, str(exc))
        return
    check("write foreign origin", http == 403, f"http {http} {body[:120]}")
    unchanged("write foreign origin")

    try:
        http, body = post_write(foreign_id, jar=nurse, origin="http://localhost:3000")
    except ConnectionError as exc:
        check("write other facility", False, str(exc))
        return
    check("write other facility", http == 403, f"http {http} {body[:120]}")
    unchanged("write other facility")

    try:
        http, body = post_write(allowed_id, jar=nurse, origin="http://localhost:3000")
    except ConnectionError as exc:
        check("write allowed patient", False, str(exc))
        return
    ok_body = False
    try:
        ok_body = bool(json.loads(body).get("ok"))
    except json.JSONDecodeError:
        ok_body = False
    check("write allowed patient", http == 200 and ok_body, f"http {http} {body[:160]}")
    try:
        calls, audits = snapshot()
        today = int(psql(
            "SELECT count(*) FROM heart360tk_schema.call_results "
            f"WHERE patient_id = {int(allowed_id)} AND call_date = CURRENT_DATE"
        ))
        new_audit = int(psql(
            "SELECT count(*) FROM heart360tk_schema.call_results_audit "
            f"WHERE patient_id = {int(allowed_id)} AND actor_login = 'nurse.phc-a' "
            "AND status = 'Pending to call' AND recorded_at > now() - interval '5 minutes'"
        ))
    except (RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
        check("write allowed audit", False, str(exc))
        return
    check("write allowed one call_results row", today == 1, f"rows today {today}")
    check(
        "write allowed one audit row",
        audits == before_audits + 1 and new_audit >= 1,
        f"audit {audits} was {before_audits}, recent nurse rows {new_audit}",
    )
    if calls < before_calls:
        check("write allowed call_results not deleted", False, f"{calls} was {before_calls}")


def main(argv):
    if argv in (["--help"], ["-h"]):
        return usage()
    if argv == ["--self-test"]:
        return self_test()
    if argv == ["--g1a"]:
        mode = "g1a"
    elif argv == []:
        mode = "full"
    else:
        print(f"unknown arguments: {' '.join(argv)}", file=sys.stderr)
        usage()
        return 2

    if not reachable(GRAFANA_URL + "/api/health", "Grafana"):
        return 1

    jars = []
    try:
        for login_name, password, required in users():
            if mode == "full" and login_name == "nurse.phc-a":
                required = True
            try:
                jar = login(login_name, password)
            except ConnectionError as exc:
                print(f"Grafana is not reachable at {GRAFANA_URL}: {exc}", file=sys.stderr)
                return 1
            if jar:
                jars.append((login_name, jar))
                print(f"login {login_name}")
            elif required:
                check(f"login {login_name}", False, "rejected")
            else:
                print(f"SKIP {login_name} (not created yet; run scripts/demo_users.sh)")
        if not jars:
            check("login", False, "no Grafana session")
            return 1
        datasource_writes(jars)
        admin_jar = dict(jars).get(users()[0][0]) or jars[0][1]
        grafana_api_absent(admin_jar)
        allowlist()
        if mode == "g1a":
            print("PASS g1a" if not FAILURES else f"FAIL g1a ({len(FAILURES)} checks)")
            return 1 if FAILURES else 0
        if not reachable(API_URL + "/healthz", "h360-api"):
            if FAILURES:
                print(f"FAIL g1a ({len(FAILURES)} checks) and h360-api is down")
            return 1
        write_path(jars)
    finally:
        for _, jar in jars:
            Path(jar).unlink(missing_ok=True)

    if FAILURES:
        print(f"FAIL full ({len(FAILURES)} checks)")
        return 1
    print("PASS full")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
