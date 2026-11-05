#!/usr/bin/env bash
# Chat verification (story 7.5, FR-43 to FR-49, SM-3, NFR-7).
#
#   ./scripts/verify_chat.sh                 needs the stack (Grafana :3000, h360-api :8090, postgres)
#   MONTH=2026-10-01 ./scripts/verify_chat.sh
#
# As district.d / demo (POST /login), asks every chip offered at PHC-E (11) and District-D (10)
# for MONTH, plus any nudge chip an answer offers (call_plan), and checks each answer:
#   - HTTP 200 in under 3 s, mode `offline` when no key is set (`claude`/`offline_fallback` allowed
#     when one is), and the honesty line exactly as h360_api/wording.py HONESTY;
#   - every number token in the visible answer (title, control line, reasons, also check, stock
#     line, nudge, plan; not the honesty line) appears in the output of the report_* / chat_*
#     functions for that place and month (report_window, report_flag_thresholds, the month itself
#     and the fudging sentence constant "1" from ranker.CONSTANTS are also allowed). The functions
#     are pooled per place and month: a number is not tied to one function. Numbers are compared
#     as decimals (75.0 = 75; 5.40 = 5.4).
#   - PHC-E why_control_low: control 72-78%, title starts `What to check at PHC-E?`, and the first
#     two reasons are the fudging and titration levers.
# nurse.phc-a asking about PHC-E gets 403 (chips and answer).
# Key leak: if ANTHROPIC_API_KEY is set (host env, .env, or the h360-api container), its value
# must not appear in docker_build/grafana_public, the widget Grafana serves, `docker logs` of
# h360-api and grafana, or the repository (git tracked and untracked files; .env and .git are
# excluded). With no key set, no `ANTHROPIC_API_KEY=<value>` assignment may appear in those places,
# and no `sk-ant-` token in the browser files or logs.
#
# PSQL follows AD-35 (PSQL="docker exec -i postgres psql -U h360tk_root"); without it, `psql` when
# on PATH, else that docker command.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import ast
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from decimal import Decimal, InvalidOperation
from http.cookiejar import CookieJar
from pathlib import Path

ROOT = Path.cwd()
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://localhost:3000").rstrip("/")
API_URL = os.environ.get("H360_API_URL", "http://localhost:8090").rstrip("/")
ORIGIN = os.environ.get("H360_ORIGIN", "http://localhost:3000")
MONTH = os.environ.get("MONTH", "2026-10-01")
DB = os.environ.get("H360_DB", "heart360tk_database")
PLACES = [(11, "PHC-E"), (10, "District-D")]
MAX_SECONDS = 3.0
NUMBER = re.compile(r"\d+(?:\.\d+)?")
SENTENCE_CONSTANTS = {"1"}  # ranker.CONSTANTS per_one ("for every 1 just over"); bp_line 140 is a histogram band

failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f" ({detail})" if detail else ""))
    if not ok:
        failures.append(label)


def honesty_line():
    tree = ast.parse((ROOT / "h360_api" / "wording.py").read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "HONESTY" for t in node.targets):
            return ast.literal_eval(node.value)
    raise SystemExit("HONESTY not found in h360_api/wording.py")


def psql_cmd():
    raw = os.environ.get("PSQL") or ("psql" if shutil.which("psql") else "docker exec -i postgres psql -U h360tk_root")
    return shlex.split(raw)


def psql_json(sql):
    proc = subprocess.run(psql_cmd() + ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", DB],
                          input=sql, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise SystemExit("psql failed: " + (proc.stderr or proc.stdout).strip())
    out = proc.stdout.strip()  # -q: no command tags; json_agg of rows spans several lines
    return json.loads(out) if out else None


class Session:
    def __init__(self, user, password):
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
        req = urllib.request.Request(GRAFANA_URL + "/login", headers={"Content-Type": "application/json"},
                                     data=json.dumps({"user": user, "password": password}).encode())
        try:
            self.opener.open(req, timeout=10).read()
        except (urllib.error.URLError, OSError) as exc:
            raise SystemExit(f"cannot sign in to Grafana as {user} at {GRAFANA_URL}: {exc}. "
                             "Run scripts/demo_users.sh and re-run.")

    def call(self, method, path, payload=None):
        headers = {"X-H360-Request": "1", "Origin": ORIGIN, "Accept": "application/json"}
        data = None
        if payload is not None:
            data, headers["Content-Type"] = json.dumps(payload).encode(), "application/json"
        req = urllib.request.Request(API_URL + path, data=data, headers=headers, method=method)
        started = time.perf_counter()
        try:
            with self.opener.open(req, timeout=30) as resp:
                status, body = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, body = err.code, err.read()
        elapsed = time.perf_counter() - started
        try:
            parsed = json.loads(body or b"null")
        except json.JSONDecodeError:
            parsed = body.decode("utf-8", "replace")
        return status, parsed, elapsed


def norm(token):
    try:
        return str(Decimal(token).normalize())
    except InvalidOperation:
        return token


def allowed_numbers(place_id):
    """Number tokens of every report_* / chat_* output for the place and month."""
    m = f"DATE '{MONTH}'"
    calls = [
        f"report_adherence({m}, {place_id}, true)", f"report_adherence({m}, {place_id}, false)",
        f"report_adherence_buckets({m}, {place_id}, true)", f"report_adherence_buckets({m}, {place_id}, false)",
        f"report_titration({m}, {place_id})", f"report_fudging({m}, {place_id})",
        f"report_fudging_histogram({m}, {place_id})", f"report_statins({m}, {place_id})",
        f"report_calling({m}, {place_id})", f"report_new_patients({m}, {place_id})",
        f"report_flags({m}, {place_id})", f"report_window({m})",
        f"chat_control_summary({m}, {place_id})", f"chat_drug_stock_gate({m}, {place_id})",
        f"chat_call_plan({m}, {place_id})", f"chat_facility_rank_district({m}, {place_id})",
        f"h360_control_summary({m}, {place_id})",
    ]
    present = set(psql_json(
        "SELECT coalesce(json_agg(p.proname), '[]') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = 'heart360tk_schema'"))
    parts = [f"(SELECT coalesce(json_agg(t), '[]') FROM heart360tk_schema.{c} t)"
             for c in calls if c.split("(")[0] in present]
    parts.append("(SELECT coalesce(json_agg(t), '[]') FROM heart360tk_schema.report_flag_thresholds t)")
    data = psql_json("SET search_path TO heart360tk_schema, public;\nSELECT json_build_array(" + ", ".join(parts) + ");")
    tokens = set(SENTENCE_CONSTANTS)
    tokens.update(norm(t) for t in NUMBER.findall(MONTH))

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, bool) or v is None:
            return
        else:
            tokens.update(norm(t) for t in NUMBER.findall(str(v)))

    walk(data)
    return tokens


def visible(answer):
    out = [answer.get("title"), answer.get("control_line")]
    for r in answer.get("reasons") or []:
        out += [r.get("text"), r.get("what_to_do")]
    out += [answer.get("also_check"), answer.get("stock_line")]
    if answer.get("nudge"):
        out.append(answer["nudge"].get("label"))
    if answer.get("plan"):
        p = answer["plan"]
        out.append(p.get("text"))
        out.append(" ".join(str(x) for x in [p.get("total"), *(p.get("weeks") or [])] if x is not None))
    return [s for s in out if isinstance(s, str) and s]


# ---------------------------------------------------------------------------- key
def key_values():
    values = set()
    if os.environ.get("ANTHROPIC_API_KEY", "").strip():
        values.add(os.environ["ANTHROPIC_API_KEY"].strip())
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8", errors="replace").splitlines():
            k, sep, v = line.partition("=")
            if sep and k.strip() == "ANTHROPIC_API_KEY" and v.strip().strip("'\""):
                values.add(v.strip().strip("'\""))
    proc = subprocess.run(["docker", "exec", "h360-api", "printenv", "ANTHROPIC_API_KEY"],
                          capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        values.add(proc.stdout.strip())
    return values


# A value: 8+ key characters on the same line (not `${ANTHROPIC_API_KEY:-}` or a blank `KEY=`).
ASSIGN = re.compile(rb"""ANTHROPIC_API_KEY["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9][A-Za-z0-9_\-]{7,})""")
SK = re.compile(rb"sk-ant-[A-Za-z0-9_\-]{6,}")


def key_sources():
    """(label, bytes) for browser files, served widget, container logs, repository."""
    for p in sorted((ROOT / "docker_build" / "grafana_public").rglob("*")):
        if p.is_file():
            yield "browser", str(p.relative_to(ROOT)), p.read_bytes()
    try:
        with urllib.request.urlopen(GRAFANA_URL + "/public/h360/chat-widget.js", timeout=10) as resp:
            yield "browser", "served /public/h360/chat-widget.js", resp.read()
    except (urllib.error.URLError, OSError) as exc:
        check("served widget readable", False, str(exc))
    for container in ("h360-api", "grafana"):
        proc = subprocess.run(["docker", "logs", container], capture_output=True)
        yield "logs", f"docker logs {container}", proc.stdout + proc.stderr
    listed = subprocess.run(["git", "ls-files", "-z", "-co", "--exclude-standard"], capture_output=True, check=True)
    for rel in listed.stdout.split(b"\0"):
        rel = rel.decode()
        if not rel or rel == ".env" or rel.startswith(".git/"):
            continue
        p = ROOT / rel
        if p.is_file():
            yield "repo", rel, p.read_bytes()


def key_check():
    values = key_values()
    hits, scanned = [], 0
    for kind, label, data in key_sources():
        scanned += 1
        if values:
            hits += [label for v in values if v.encode() in data]
        else:
            if ASSIGN.search(data):
                hits.append(f"{label}: ANTHROPIC_API_KEY={ASSIGN.search(data).group(1)[:4].decode(errors='replace')}...")
            if kind != "repo" and SK.search(data):
                hits.append(f"{label}: sk-ant- token")
    mode = "key value" if values else "no key set; key name with a value"
    check(f"no API key in browser files, logs or repository ({mode})", not hits,
          f"{scanned} sources" if not hits else "; ".join(hits[:10]))
    return bool(values)


# ---------------------------------------------------------------------------- run
honesty = honesty_line()
key_set = key_check()

district = Session("district.d", "demo")
for place_id, name in PLACES:
    status, chips, _ = district.call("GET", f"/chat/chips?org_unit_id={place_id}&reporting_month={MONTH}")
    if status != 200:
        check(f"{name} chips", False, f"http {status} {chips}")
        continue
    ids = [c["id"] for c in chips["chips"]]
    check(f"{name} chips offered", bool(ids), ", ".join(ids))
    allowed = allowed_numbers(place_id)
    queue = list(ids)
    for chip in queue:
        label = f"{name} {chip}"
        status, ans, secs = district.call("POST", "/chat", {"chip_id": chip, "org_unit_id": place_id,
                                                             "reporting_month": MONTH})
        if status != 200:
            check(label, False, f"http {status} {ans}")
            continue
        nudge = ans.get("nudge") or {}
        # A nudge chip (call_plan) is asked too; a nudge with a url or another place is a link.
        if nudge.get("chip_id") and not nudge.get("url") and "org_unit_id" not in nudge \
                and nudge["chip_id"] not in queue:
            queue.append(nudge["chip_id"])
        problems = []
        if secs >= MAX_SECONDS:
            problems.append(f"{secs:.2f}s")
        if ans.get("honesty") != honesty:
            problems.append("honesty line missing or changed")
        expected_modes = {"claude", "offline_fallback", "offline"} if key_set else {"offline"}
        if ans.get("mode") not in expected_modes:
            problems.append(f"mode {ans.get('mode')}")
        if (ans.get("place") or {}).get("org_unit_id") != place_id:
            problems.append(f"place {ans.get('place')}")
        numbers = [t for s in visible(ans) for t in NUMBER.findall(s)]
        missing = sorted({t for t in numbers if norm(t) not in allowed})
        if missing:
            problems.append("numbers not in the report or chat functions: " + ", ".join(missing))
        check(label, not problems, "; ".join(problems) if problems else
              f"{secs * 1000:.0f} ms, {len(numbers)} numbers matched, mode {ans.get('mode')}")

        if place_id == 11 and chip == "why_control_low":
            ctl = psql_json(f"SELECT to_json(controlled_pct) FROM heart360tk_schema.chat_control_summary("
                            f"DATE '{MONTH}', 11) WHERE is_selected")
            check("PHC-E control 72-78%", ctl is not None and 72 <= float(ctl) <= 78, f"{ctl}%")
            title = ans.get("title") or ""
            check("PHC-E title starts 'What to check at PHC-E?'", title.startswith("What to check at PHC-E?"), title)
            levers = [r.get("lever") for r in ans.get("reasons") or []]
            check("PHC-E first reasons are fudging then titration", levers[:2] == ["fudging_score", "titration_rate"],
                  ", ".join(str(x) for x in levers))

nurse = Session("nurse.phc-a", "demo")
status, body, _ = nurse.call("GET", f"/chat/chips?org_unit_id=11&reporting_month={MONTH}")
check("nurse.phc-a chips at PHC-E is 403", status == 403, f"http {status}")
status, body, _ = nurse.call("POST", "/chat", {"chip_id": "why_control_low", "org_unit_id": 11,
                                               "reporting_month": MONTH})
check("nurse.phc-a answer at PHC-E is 403", status == 403 and isinstance(body, dict)
      and body.get("message") == "You do not have access to this place.", f"http {status} {body}")
status, body, _ = nurse.call("POST", "/chat", {"chip_id": "why_control_low", "org_unit_id": 3,
                                               "reporting_month": MONTH})
check("nurse.phc-a answer at PHC-A is 200 (control)", status == 200, f"http {status}")

if failures:
    print(f"FAIL verify_chat ({len(failures)} checks): " + "; ".join(failures))
    sys.exit(1)
print("PASS verify_chat")
PY
