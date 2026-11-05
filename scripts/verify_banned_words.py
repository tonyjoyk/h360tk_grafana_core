#!/usr/bin/env python3
"""Banned-word and plain-language check (story 7.3, FR-48, NFR-8, PD-5, UX-DR10).

Fails when user-visible text contains a banned word, or when a flag reason or a chat sentence is
longer than 20 words.

Banned (case-insensitive):
  fudg                                       prefix: fudge, fudging, fudged ...
  will, guarantee, guarantees, guaranteed    whole words only (so `willing` and `goodwill` pass)

What is scanned
  1. Dashboards. The generated Reports dashboard (every visible string), and the other provisioned
     dashboards' NEW strings: visible strings that are not in the same file at the baseline ref
     (default 08a2894, the check_htn_dm_untouched.py baseline). A dashboard absent at the baseline
     is new in full.
  2. The chat widget, docker_build/grafana_public/h360/chat-widget.js (JS rules below).
  3. Report function outputs, via PSQL: `flag_reason` of every report_* function for each org unit
     at levels 0 to 3 (0 = national) and the last --months completed months up to --month; the
     report_adherence_buckets labels and report_statins_patients reason_eligible values (banned
     words only).
  4. h360-api answers: POST /chat for every chip that GET /chat/chips offers, at every district
     and facility, for --month, signed in to Grafana as the admin. Chip labels and every visible
     answer string are scanned; the honesty line is checked too.
  Every flag reason and every chat sentence must be 20 words or fewer.

Visible-text heuristics (dashboards and the widget)
  - Grafana JSON is walked by key. Plain text keys: title, description, label, tooltip,
    displayName, noValue, text, placeholder, searchPlaceholder, iconFilterLabel, iconClickTooltip.
    HTML keys: content, defaultContent. JS keys: afterRender, beforeRender, getOption, helpers,
    onRender, callback, code. SQL keys: rawSql, definition, query. Every other key is an id,
    element key, option, colour, unit, CSS or URL and is not scanned (styles, url, uid, name, ...).
  - HTML: tags, <script>/<style> bodies, Handlebars {{...}} and entities are removed; text nodes are
    kept, plus the visible attributes title, alt, placeholder, aria-label.
  - JS: comments are removed, then only string literals ('...', "...", `...` with ${...} removed)
    are read, so identifiers, property names and code never count. A literal that is a single
    lower-case token ([a-z0-9_.:/#-] only, e.g. 'fudging', 'rpt-head', 'report_fudging') is an
    internal id, key or class name and is skipped. A literal holding HTML is reduced to its text.
  - SQL: only string literals '...' and double-quoted column aliases after AS ("Patients seen") are
    read. Identifiers (report_fudging, flag_reason) never count; single lower-case token literals
    are skipped as above.

Usage
  python3 scripts/verify_banned_words.py              full check (needs the stack)
  python3 scripts/verify_banned_words.py --no-db --no-api   files only
  python3 scripts/verify_banned_words.py --self-test  plants violations; exits 0 only if caught

PSQL follows AD-35: PSQL="docker exec -i postgres psql -U h360tk_root". Without PSQL it uses `psql`
when on PATH, else that docker command.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DASH_DIR = ROOT / "grafana_provisioning" / "dashboards"
REPORTS = DASH_DIR / "HEARTS360 Dashboards" / "heart360.reports.json"
WIDGET = ROOT / "docker_build" / "grafana_public" / "h360" / "chat-widget.js"
BASELINE_REF = "08a2894"
DB_NAME = os.environ.get("H360_DB", "heart360tk_database")
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://localhost:3000").rstrip("/")
API_URL = os.environ.get("H360_API_URL", "http://localhost:8090").rstrip("/")
ORIGIN = os.environ.get("H360_ORIGIN", "http://localhost:3000")
MAX_WORDS = 20

BANNED_RE = re.compile(r"\bfudg\w*|\b(?:will|guarantee|guarantees|guaranteed)\b", re.IGNORECASE)
WORD_RE = re.compile(r"\S+")
SENTENCE_END = re.compile(r"(?<=[.?!])\s+")

TEXT_KEYS = {"title", "description", "label", "tooltip", "displayName", "noValue", "text",
             "placeholder", "searchPlaceholder", "iconFilterLabel", "iconClickTooltip"}
HTML_KEYS = {"content", "defaultContent"}
JS_KEYS = {"afterRender", "beforeRender", "getOption", "helpers", "onRender", "callback", "code"}
SQL_KEYS = {"rawSql", "definition", "query"}

ID_TOKEN = re.compile(r"^[a-z0-9_.:/#\-]*$")
VISIBLE_ATTR = re.compile(r"""\b(?:title|alt|placeholder|aria-label)\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.I)

# Report functions: (name, extra args after (month, org), visible text columns, length-checked).
REPORT_TEXT = [
    ("report_adherence", ", true", "flag_reason", True),
    ("report_adherence", ", false", "flag_reason", True),
    ("report_titration", "", "flag_reason", True),
    ("report_fudging", "", "flag_reason", True),
    ("report_statins", "", "flag_reason", True),
    ("report_calling", "", "flag_reason", True),
    ("report_new_patients", "", "flag_reason", True),
    ("report_flags", "", "flag_reason", True),
    ("report_adherence_buckets", ", true", "label", False),
    ("report_statins_patients", "", "reason_eligible", False),
]


class Findings:
    def __init__(self) -> None:
        self.items: list[str] = []
        self.counts: dict[str, int] = {}

    def scanned(self, source: str, n: int = 1) -> None:
        self.counts[source] = self.counts.get(source, 0) + n

    def add(self, source: str, where: str, problem: str, text: str) -> None:
        snippet = text if len(text) <= 160 else text[:157] + "..."
        self.items.append(f"{source}: {where}: {problem}: {snippet!r}")


def banned_in(text: str) -> list[str]:
    return sorted({m.group(0) for m in BANNED_RE.finditer(text)})


def check_text(f: Findings, source: str, where: str, text: str, length: bool = False) -> None:
    text = " ".join(text.split())
    if not text:
        return
    f.scanned(source)
    hits = banned_in(text)
    if hits:
        f.add(source, where, "banned " + ",".join(hits), text)
    if length:
        for sentence in SENTENCE_END.split(text):
            n = len(WORD_RE.findall(sentence))
            if n > MAX_WORDS:
                f.add(source, where, f"{n} words (max {MAX_WORDS})", sentence)


# --------------------------------------------------------------------------- text extraction


def html_text(src: str) -> list[str]:
    """Visible text of an HTML / Handlebars / markdown fragment."""
    out = [a or b for a, b in VISIBLE_ATTR.findall(src)]
    s = re.sub(r"(?is)<(script|style)\b.*?</\1\s*>", " ", src)
    s = re.sub(r"\{\{\{?.*?\}\}\}?", " ", s, flags=re.S)
    s = re.sub(r"(?s)<!--.*?-->", " ", s)
    s = re.sub(r"(?s)<[^>]*>", "\n", s)
    s = html.unescape(s)
    out += [line.strip() for line in s.split("\n") if line.strip()]
    return out


REGEX_PREV = set("(,=:[!&|?{};+-*%<>~^") | {""}


def js_literals(src: str) -> list[str]:
    """String literal contents of JS source, in one pass that also skips comments and regex
    literals (so a quote inside /[&<>"']/ or a comment does not open a string). ${...} is dropped."""
    out, i, n = [], 0, len(src)
    prev = ""  # last significant character outside strings and comments
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == "/" and (prev in REGEX_PREV or re.search(r"\b(return|typeof|case)\s*$", src[max(0, i - 8):i])):
            j, in_class = i + 1, False
            while j < n and src[j] != "\n":
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "[":
                    in_class = True
                elif src[j] == "]":
                    in_class = False
                elif src[j] == "/" and not in_class:
                    break
                j += 1
            i, prev = j + 1, "r"
            continue
        if c in "'\"`":
            j, buf = i + 1, []
            while j < n and src[j] != c:
                if src[j] == "\\" and j + 1 < n:
                    buf.append(src[j + 1])
                    j += 2
                    continue
                if c == "`" and src.startswith("${", j):
                    depth, j = 1, j + 2
                    while j < n and depth:
                        depth += {"{": 1, "}": -1}.get(src[j], 0)
                        j += 1
                    buf.append(" ")
                    continue
                buf.append(src[j])
                j += 1
            out.append("".join(buf))
            i, prev = j + 1, "s"
            continue
        if not c.isspace():
            prev = c
        i += 1
    return out


def visible_from_literal(lit: str) -> list[str]:
    s = lit.strip()
    if not s or ID_TOKEN.match(s):
        return []
    if "<" in s and ">" in s:
        return html_text(s)
    return [s]


def js_text(src: str) -> list[str]:
    out = []
    for lit in js_literals(src):
        out += visible_from_literal(lit)
    return out


SQL_LITERAL = re.compile(r"'((?:[^']|'')*)'")
SQL_ALIAS = re.compile(r'\bAS\s+"([^"]+)"', re.I)


def sql_text(src: str) -> list[str]:
    no_comments = re.sub(r"--[^\n]*", " ", src)
    no_comments = re.sub(r"(?s)/\*.*?\*/", " ", no_comments)
    out = []
    for lit in SQL_LITERAL.findall(no_comments):
        out += visible_from_literal(lit.replace("''", "'"))
    out += [a for a in SQL_ALIAS.findall(no_comments) if not ID_TOKEN.match(a)]
    return out


def dashboard_strings(doc) -> list[tuple[str, str]]:
    """(json path, visible text) for one Grafana dashboard (classic or v2)."""
    out: list[tuple[str, str]] = []

    def walk(o, path: str) -> None:
        if isinstance(o, dict):
            for k, v in o.items():
                p = f"{path}.{k}"
                if isinstance(v, str):
                    if k in TEXT_KEYS:
                        out.extend((p, t) for t in [v] if not ID_TOKEN.match(v.strip()))
                    elif k in HTML_KEYS:
                        out.extend((p, t) for t in html_text(v))
                    elif k in JS_KEYS:
                        out.extend((p, t) for t in js_text(v))
                    elif k in SQL_KEYS:
                        out.extend((p, t) for t in sql_text(v))
                else:
                    walk(v, p)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                walk(v, f"{path}[{i}]")

    walk(doc, "$")
    return out


def baseline_doc(path: Path, ref: str):
    rel = path.relative_to(ROOT).as_posix()
    proc = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{rel}"], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def scan_dashboards(f: Findings, ref: str, extra: list[Path], only_extra: bool) -> None:
    files = [] if only_extra else sorted(DASH_DIR.rglob("*.json"))
    for path in files + extra:
        doc = json.loads(path.read_text(encoding="utf-8"))
        strings = dashboard_strings(doc)
        name = path.name
        if path.resolve() != REPORTS.resolve() and path not in extra:
            base = baseline_doc(path, ref)
            if base is not None:
                old = {t for _, t in dashboard_strings(base)}
                strings = [(p, t) for p, t in strings if t not in old]
                name += f" (new since {ref})"
        for p, t in strings:
            check_text(f, "dashboard", f"{name} {p}", t)
    if not only_extra and WIDGET.exists():
        for t in js_text(WIDGET.read_text(encoding="utf-8")):
            check_text(f, "widget", WIDGET.name, t)


# --------------------------------------------------------------------------- database


def psql_cmd() -> list[str]:
    raw = os.environ.get("PSQL")
    if not raw:
        raw = "psql" if shutil.which("psql") else "docker exec -i postgres psql -U h360tk_root"
    return shlex.split(raw)


def psql_json(sql: str):
    cmd = psql_cmd() + ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", DB_NAME]
    proc = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip().splitlines()[-1:] or ["psql failed"])
    out = proc.stdout.strip()  # -q: no command tags; json_agg of rows spans several lines
    return json.loads(out) if out else None


def month_list(last: dt.date, n: int) -> list[str]:
    out, y, m = [], last.year, last.month
    for _ in range(n):
        out.append(f"{y:04d}-{m:02d}-01")
        y, m = (y, m - 1) if m > 1 else (y - 1, 12)
    return out


def scan_reports(f: Findings, months: list[str]) -> None:
    month_array = "ARRAY[" + ",".join(f"DATE '{m}'" for m in months) + "]"
    for fn, extra, column, length in REPORT_TEXT:
        exists = psql_json(
            "SELECT to_json(count(*)) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
            f"WHERE n.nspname = 'heart360tk_schema' AND p.proname = '{fn}'")
        if not exists:
            print(f"  note: {fn} does not exist; skipped")
            continue
        started = time.perf_counter()
        rows = psql_json(f"""
SET search_path TO heart360tk_schema, public;
SELECT coalesce(json_agg(DISTINCT jsonb_build_object('t', r.{column}, 'm', m, 'o', o.id)), '[]')
FROM unnest({month_array}) AS m
CROSS JOIN (SELECT id FROM heart360tk_schema.org_units WHERE level <= 3 UNION ALL SELECT 0) AS o
CROSS JOIN LATERAL heart360tk_schema.{fn}(m, o.id{extra}) AS r
WHERE r.{column} IS NOT NULL AND btrim(r.{column}) <> '';
""")
        seen = set()
        for row in rows or []:
            if row["t"] in seen:
                continue
            seen.add(row["t"])
            check_text(f, "report", f"{fn}{extra or ''} {column} (org {row['o']}, {row['m']})", row["t"], length)
        print(f"  {fn}({months[-1]}..{months[0]}{extra}): {len(seen)} distinct {column} "
              f"in {time.perf_counter() - started:.1f}s")


# --------------------------------------------------------------------------- h360-api


class Api:
    def __init__(self, user: str, password: str) -> None:
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        body = json.dumps({"user": user, "password": password}).encode()
        req = urllib.request.Request(GRAFANA_URL + "/login", data=body,
                                     headers={"Content-Type": "application/json"})
        self.opener.open(req, timeout=10).read()

    def call(self, method: str, path: str, payload=None):
        headers = {"X-H360-Request": "1", "Origin": ORIGIN, "Accept": "application/json"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(API_URL + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read() or b"null")


def answer_texts(answer: dict) -> list[tuple[str, str]]:
    out = [("title", answer.get("title")), ("control_line", answer.get("control_line"))]
    for i, r in enumerate(answer.get("reasons") or []):
        out += [(f"reasons[{i}].text", r.get("text")), (f"reasons[{i}].what_to_do", r.get("what_to_do"))]
        if r.get("link"):
            out.append((f"reasons[{i}].link.label", r["link"].get("label")))
    out += [("also_check", answer.get("also_check")), ("stock_line", answer.get("stock_line"))]
    if answer.get("nudge"):
        out.append(("nudge.label", answer["nudge"].get("label")))
    if answer.get("plan"):
        out.append(("plan.text", answer["plan"].get("text")))
    for i, link in enumerate(answer.get("links") or []):
        out.append((f"links[{i}].label", link.get("label")))
    out.append(("honesty", answer.get("honesty")))
    return [(k, v) for k, v in out if isinstance(v, str) and v]


def scan_api(f: Findings, month: str) -> None:
    user = os.environ.get("GRAFANA_ADMIN_USER") or "admin"
    password = os.environ.get("GRAFANA_ADMIN_PASSWORD") or "admin"
    api = Api(user, password)
    nodes = psql_json("SELECT coalesce(json_agg(json_build_object('id', id, 'name', name) ORDER BY level, id), '[]') "
                      "FROM heart360tk_schema.org_units WHERE level IN (2, 3)")
    asked = 0
    for node in nodes:
        q = f"/chat/chips?org_unit_id={node['id']}&reporting_month={month}"
        status, chips = api.call("GET", q)
        if status != 200:
            raise RuntimeError(f"GET {q} -> {status} {chips}")
        for chip in chips["chips"]:
            check_text(f, "chat", f"chip {chip['id']} label", chip["label"], True)
            status, ans = api.call("POST", "/chat", {"chip_id": chip["id"], "org_unit_id": node["id"],
                                                     "reporting_month": month})
            if status != 200:
                f.add("chat", f"{node['name']} {chip['id']}", f"http {status}", json.dumps(ans))
                continue
            asked += 1
            for key, text in answer_texts(ans):
                check_text(f, "chat", f"{node['name']} {chip['id']} {key}", text, True)
    print(f"  asked {asked} chips at {len(nodes)} districts and facilities for {month}")


# --------------------------------------------------------------------------- main


def run(args) -> int:
    f = Findings()
    if not args.no_files:
        scan_dashboards(f, args.baseline, [Path(p) for p in args.plant], args.only_planted)
    if args.plant_text:
        for t in args.plant_text:
            check_text(f, "planted", "--plant-text", t, True)
    try:
        if not args.no_db:
            last = dt.date.fromisoformat(args.month)
            scan_reports(f, month_list(last, args.months))
        if not args.no_api:
            scan_api(f, args.month)
    except (RuntimeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"FAIL could not read the stack: {exc}", file=sys.stderr)
        return 2
    summary = ", ".join(f"{k} {v}" for k, v in sorted(f.counts.items()))
    if f.items:
        for item in f.items:
            print("FAIL " + item)
        print(f"FAIL {len(f.items)} problems ({summary} strings scanned)")
        return 1
    print(f"PASS no banned words, no sentence over {MAX_WORDS} words ({summary} strings scanned)")
    return 0


def self_test() -> int:
    ok = True

    def expect(label: str, cond: bool) -> None:
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + label)
        ok = ok and cond

    # Extraction rules.
    js = ("// this will not count\nconst willRender = 1; const k = 'fudging'; el.className = 'rpt-fudging';\n"
          "const msg = `Readings ${x} will be checked`; const h = '<b title=\"Guaranteed\">ok</b>';")
    lits = js_text(js)
    expect("JS comment and identifiers skipped", not any("this will" in t or "willRender" in t for t in lits))
    expect("JS id-like literal skipped", "fudging" not in lits and "rpt-fudging" not in lits)
    expect("JS template literal read", any(banned_in(t) == ["will"] for t in lits))
    expect("JS HTML attribute read", any(banned_in(t) == ["Guaranteed"] for t in lits))
    expect("SQL identifier skipped", sql_text("SELECT * FROM report_fudging($1) WHERE r = 'fudging'") == [])
    expect("SQL literal read", banned_in(" ".join(sql_text("SELECT 'We guarantee it' AS \"Note\""))) == ["guarantee"])
    expect("whole words only", banned_in("goodwill willing guaranteeing") == [])
    expect("fudg is a prefix", banned_in("Fudged and fudge") == ["Fudged", "fudge"])

    # A planted dashboard and a planted long flag reason make the script exit nonzero.
    with tempfile.TemporaryDirectory() as tmp:
        planted = Path(tmp) / "planted.json"
        planted.write_text(json.dumps({"title": "Planted", "panels": [
            {"title": "This will improve", "options": {"content": "<p>Fudged readings</p>"}}]}))
        clean = Path(tmp) / "clean.json"
        clean.write_text(json.dumps({"title": "Clean", "panels": [
            {"title": "BP readings check", "options": {"afterRender": "el.className = 'rpt-fudging';"}}]}))
        base = ["--no-db", "--no-api", "--only-planted"]
        rc_planted = run(parse([*base, "--plant", str(planted)]))
        expect("planted dashboard exits nonzero", rc_planted != 0)
        rc_clean = run(parse([*base, "--plant", str(clean)]))
        expect("clean dashboard exits zero", rc_clean == 0)
        long_reason = " ".join(["word"] * 21) + "."
        rc_long = run(parse([*base, "--plant", str(clean), "--plant-text", long_reason]))
        expect("21-word sentence exits nonzero", rc_long != 0)
        rc_ok = run(parse([*base, "--plant", str(clean), "--plant-text", " ".join(["word"] * 20) + "."]))
        expect("20-word sentence exits zero", rc_ok == 0)
    print("PASS self-test" if ok else "FAIL self-test")
    return 0 if ok else 1


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--month", default="2026-10-01", help="chat month and last report month (default %(default)s)")
    p.add_argument("--months", type=int, default=3, help="report months to scan, back from --month (default 3)")
    p.add_argument("--baseline", default=BASELINE_REF, help="git ref for 'new strings' (default %(default)s)")
    p.add_argument("--no-db", action="store_true", help="skip report function outputs")
    p.add_argument("--no-api", action="store_true", help="skip h360-api answers")
    p.add_argument("--no-files", action="store_true", help="skip dashboards and the widget")
    p.add_argument("--plant", action="append", default=[], help=argparse.SUPPRESS)
    p.add_argument("--plant-text", action="append", default=[], help=argparse.SUPPRESS)
    p.add_argument("--only-planted", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--self-test", action="store_true", help="plant violations and expect them caught")
    return p.parse_args(argv)


def main(argv) -> int:
    args = parse(argv)
    if args.self_test:
        return self_test()
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
