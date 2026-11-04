#!/usr/bin/env python3
"""Run every provisioned dashboard query as its datasource role (story 2.6, AD-35).

Parses Grafana dashboard JSON under grafana_provisioning/dashboards. v2 boards
(apiVersion dashboard.grafana.app/v2) contribute spec.elements panel queries and
spec.variables QueryVariable queries. Classic boards contribute panel targets
and templating query variables. Business Table update payloads are writes, not
load queries, so they are listed and skipped; verify_security.sh covers writes.

  python3 scripts/verify_dashboard_queries.py --list
  python3 scripts/verify_dashboard_queries.py --max-ms 2000
  python3 scripts/test_verify_dashboard_queries.py

Connection: DATABASE_URL, otherwise PGHOST/PGUSER/PGPASSWORD/PGDATABASE/PGPORT
when any of those is set, otherwise
postgres://h360tk_root:NGE5ZjljYjM1ZWEyNDI5N2I0YmZiZGM0@localhost:5432/heart360tk_database
The session then SET ROLE to the datasource user from grafana_provisioning/datasources
(h360tk_root is superuser and can SET ROLE). search_path is the datasource
jsonData.searchPath, because SET ROLE does not apply ALTER ROLE ... SET.

Sample variable map (anything else ${name} becomes 0):

  org_unit                    0
  isAllowed                   1
  isAdmin                     1
  reference_month             1790812800000   # 2026-10-01 00:00:00 UTC, unix ms
  reference_month:date:*      October 2026 (Moment-style MMMM/YYYY/MM/DD)
  estimated_htn_population    1000
  selected_level              2
  reporting_month             2026-10-01
  requiredGroups              none
  child_level_name            Facility
  __user.id                   1
  __user.login                admin
  __user.email                admin@localhost
  UserIsGlobal                1
  UserOrgUnitId               0
  UserDrillUrl                (empty)
  payload.patient_id          0
  payload.removed_reason      Pending to call
  $__timeFrom()               '2025-11-01T00:00:00Z'
  $__timeTo()                 '2026-11-01T00:00:00Z'
  $__timeFilter(col)          col BETWEEN those two timestamps

Braced (${name}, ${name:format}) and bare ($name) forms are both replaced.
Unknown names use 0 and are printed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DASHBOARDS = ROOT / "grafana_provisioning" / "dashboards"
DATASOURCES = ROOT / "grafana_provisioning" / "datasources"

TIME_FROM = "2025-11-01T00:00:00Z"
TIME_TO = "2026-11-01T00:00:00Z"
REFERENCE_MONTH = datetime(2026, 10, 1, tzinfo=timezone.utc)
REFERENCE_MONTH_MS = str(int(REFERENCE_MONTH.timestamp() * 1000))

# Documented sample map. Values are inserted raw; SQL that quotes them keeps the quotes.
SAMPLE_VARS = {
    "org_unit": "0",
    "isAllowed": "1",
    "isAdmin": "1",
    "reference_month": REFERENCE_MONTH_MS,
    "estimated_htn_population": "1000",
    "selected_level": "2",
    "reporting_month": "2026-10-01",
    "requiredGroups": "none",
    "child_level_name": "Facility",
    "__user.id": "1",
    "__user.login": "admin",
    "__user.email": "admin@localhost",
    "UserIsGlobal": "1",
    "UserOrgUnitId": "0",
    "UserDrillUrl": "",
    "payload.patient_id": "0",
    "payload.removed_reason": "Pending to call",
}
UNKNOWN_DEFAULT = "0"

DEFAULT_DSN = (
    "postgres://h360tk_root:NGE5ZjljYjM1ZWEyNDI5N2I0YmZiZGM0"
    "@localhost:5432/heart360tk_database"
)

TAB_AREA = {
    "hypertension": "htn",
    "diabetes": "dm",
    "overdue list": "overdue",
}

BRACED_VAR = re.compile(r"\$\{([A-Za-z_][\w.]*)(?::([^}]+))?\}")
BARE_VAR = re.compile(r"(?<!\$)\$([A-Za-z_][\w]*)(?!\$)")
TIME_FILTER_RE = re.compile(r"\$__timeFilter\(([^()]*)\)")
TIME_FROM_RE = re.compile(r"\$__timeFrom\(\)")
TIME_TO_RE = re.compile(r"\$__timeTo\(\)")
SQL_WORD = re.compile(r"\b(SELECT|WITH|SHOW|VALUES)\b", re.IGNORECASE)


@dataclass
class Query:
    dashboard_uid: str
    dashboard_title: str
    kind: str
    name: str
    title: str
    datasource: str
    role: str
    search_path: str
    area: str
    sql: str

    @property
    def label(self) -> str:
        title = f" {self.title}" if self.title else ""
        return (
            f"{self.dashboard_uid} {self.area} {self.kind} {self.name}{title} "
            f"ds={self.datasource or '-'} role={self.role or '-'}"
        )


@dataclass
class Datasource:
    uid: str
    name: str
    user: str
    search_path: str


def load_datasources(directory: Path) -> dict[str, Datasource]:
    found: dict[str, Datasource] = {}
    for path in sorted(directory.glob("*.yml")) + sorted(directory.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text()) or {}
        for raw in doc.get("datasources") or []:
            if not isinstance(raw, dict) or raw.get("type") != "postgres":
                continue
            json_data = raw.get("jsonData") or {}
            ds = Datasource(
                uid=str(raw.get("uid") or ""),
                name=str(raw.get("name") or ""),
                user=str(raw.get("user") or ""),
                search_path=str(json_data.get("searchPath") or "public"),
            )
            for key in (ds.uid, ds.name):
                if key:
                    found[key] = ds
    return found


def datasource_of(node) -> str:
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        return str(node.get("uid") or node.get("name") or "")
    return ""


def format_sample(name: str, fmt: str | None, unknown: set[str]) -> str:
    raw = SAMPLE_VARS.get(name)
    if raw is None:
        unknown.add(name if not fmt else f"{name}:{fmt}")
        raw = UNKNOWN_DEFAULT
    if not fmt or fmt in ("raw", "text", "csv", "glob", "pipe", "percentencode", "queryparam", "json"):
        return raw
    if fmt in ("singlequote", "sqlstring"):
        return "'" + raw.replace("'", "''") + "'"
    if fmt == "doublequote":
        return '"' + raw.replace('"', '""') + '"'
    if fmt.startswith("date:"):
        pattern = fmt[5:]
        moment = (
            pattern.replace("YYYY", REFERENCE_MONTH.strftime("%Y"))
            .replace("MMMM", REFERENCE_MONTH.strftime("%B"))
            .replace("MMM", REFERENCE_MONTH.strftime("%b"))
            .replace("MM", REFERENCE_MONTH.strftime("%m"))
            .replace("DD", REFERENCE_MONTH.strftime("%d"))
        )
        return moment
    unknown.add(f"{name}:{fmt}")
    return raw


def substitute(sql: str, unknown: set[str] | None = None) -> str:
    """Replace Grafana macros and variables. `unknown` collects names that used the default."""
    found = unknown if unknown is not None else set()

    def time_filter(match: re.Match) -> str:
        column = match.group(1).strip()
        return f"{column} BETWEEN '{TIME_FROM}' AND '{TIME_TO}'"

    sql = TIME_FILTER_RE.sub(time_filter, sql)
    sql = TIME_FROM_RE.sub(f"'{TIME_FROM}'", sql)
    sql = TIME_TO_RE.sub(f"'{TIME_TO}'", sql)

    def braced(match: re.Match) -> str:
        return format_sample(match.group(1), match.group(2), found)

    sql = BRACED_VAR.sub(braced, sql)

    def bare(match: re.Match) -> str:
        name = match.group(1)
        if name.startswith("__"):
            return match.group(0)
        return format_sample(name, None, found)

    return BARE_VAR.sub(bare, sql)


def tab_area(title: str) -> str | None:
    return TAB_AREA.get(title.strip().lower())


def element_areas(layout) -> dict[str, str]:
    areas: dict[str, str] = {}

    def walk(node, area: str) -> None:
        if isinstance(node, dict):
            current = area
            if node.get("kind") == "TabsLayoutTab":
                current = tab_area((node.get("spec") or {}).get("title") or "") or area
            if node.get("kind") == "ElementReference" and node.get("name"):
                areas.setdefault(node["name"], current)
            for value in node.values():
                walk(value, current)
        elif isinstance(node, list):
            for value in node:
                walk(value, area)

    walk(layout, "other")
    return areas


def file_area(uid: str, title: str) -> str | None:
    blob = f"{uid} {title}".lower()
    if "drug" in blob and "stock" in blob:
        return "drug_stock"
    if uid == "heart360-home" or title.strip().lower() == "home":
        return "home"
    return None


def add_query(out: list[Query], **kwargs) -> None:
    sql = kwargs.get("sql") or ""
    if not str(sql).strip():
        return
    out.append(Query(**kwargs))


def collect_v2(dashboard: dict, area_default: str | None, datasources: dict[str, Datasource]) -> list[Query]:
    spec = dashboard.get("spec") or {}
    uid = str(dashboard.get("uid") or (dashboard.get("metadata") or {}).get("name") or "")
    title = str(spec.get("title") or "")
    areas = element_areas(spec.get("layout"))
    out: list[Query] = []
    elements = spec.get("elements") or {}
    if isinstance(elements, dict):
        for name, element in elements.items():
            if not isinstance(element, dict) or element.get("kind") != "Panel":
                continue
            data = (element.get("spec") or {}).get("data") or {}
            queries = (data.get("spec") or {}).get("queries") or []
            panel_title = str((element.get("spec") or {}).get("title") or "")
            for query in queries:
                qspec = (query or {}).get("spec") or {}
                body = (qspec.get("query") or {}).get("spec") or {}
                raw = body.get("rawSql")
                if not isinstance(raw, str):
                    continue
                ds_key = datasource_of((qspec.get("query") or {}).get("datasource"))
                ds = datasources.get(ds_key)
                ref = qspec.get("refId") or "A"
                add_query(
                    out,
                    dashboard_uid=uid,
                    dashboard_title=title,
                    kind="panel",
                    name=f"{name}#{ref}",
                    title=panel_title,
                    datasource=ds_key,
                    role=ds.user if ds else "",
                    search_path=ds.search_path if ds else "public",
                    area=area_default or areas.get(name, "other"),
                    sql=raw,
                )
    for variable in spec.get("variables") or []:
        if not isinstance(variable, dict) or variable.get("kind") != "QueryVariable":
            continue
        vspec = variable.get("spec") or {}
        body = (vspec.get("query") or {}).get("spec") or {}
        raw = body.get("rawSql")
        if not isinstance(raw, str):
            continue
        ds_key = datasource_of((vspec.get("query") or {}).get("datasource"))
        ds = datasources.get(ds_key)
        add_query(
            out,
            dashboard_uid=uid,
            dashboard_title=title,
            kind="variable",
            name=str(vspec.get("name") or "variable"),
            title="",
            datasource=ds_key,
            role=ds.user if ds else "",
            search_path=ds.search_path if ds else "public",
            area=area_default or "shared",
            sql=raw,
        )
    return out


def walk_classic_panels(panels, uid, title, area, datasources, out: list[Query]) -> None:
    for panel in panels or []:
        if not isinstance(panel, dict):
            continue
        walk_classic_panels(panel.get("panels"), uid, title, area, datasources, out)
        panel_title = str(panel.get("title") or "")
        for target in panel.get("targets") or []:
            if not isinstance(target, dict):
                continue
            raw = target.get("rawSql")
            if not isinstance(raw, str):
                continue
            ds_key = datasource_of(target.get("datasource") or panel.get("datasource"))
            ds = datasources.get(ds_key)
            ref = target.get("refId") or "A"
            panel_id = panel.get("id", "?")
            add_query(
                out,
                dashboard_uid=uid,
                dashboard_title=title,
                kind="panel",
                name=f"panel-{panel_id}#{ref}",
                title=panel_title,
                datasource=ds_key,
                role=ds.user if ds else "",
                search_path=ds.search_path if ds else "public",
                area=area or "other",
                sql=raw,
            )


def collect_classic(dashboard: dict, area_default: str | None, datasources: dict[str, Datasource]) -> list[Query]:
    uid = str(dashboard.get("uid") or "")
    title = str(dashboard.get("title") or "")
    out: list[Query] = []
    walk_classic_panels(dashboard.get("panels"), uid, title, area_default, datasources, out)
    for variable in (dashboard.get("templating") or {}).get("list") or []:
        if not isinstance(variable, dict) or variable.get("type") != "query":
            continue
        raw = variable.get("query")
        if isinstance(raw, dict):
            raw = raw.get("rawSql") or raw.get("query")
        if not isinstance(raw, str) or not SQL_WORD.search(raw):
            continue
        ds_key = datasource_of(variable.get("datasource"))
        ds = datasources.get(ds_key)
        add_query(
            out,
            dashboard_uid=uid,
            dashboard_title=title,
            kind="variable",
            name=str(variable.get("name") or "variable"),
            title="",
            datasource=ds_key,
            role=ds.user if ds else "",
            search_path=ds.search_path if ds else "public",
            area=area_default or "shared",
            sql=raw,
        )
    return out


def iter_rawsql(node, path: str = ""):
    if isinstance(node, dict):
        for key, value in node.items():
            child = f"{path}.{key}" if path else key
            if key == "rawSql" and isinstance(value, str) and value.strip():
                yield child, value
            else:
                yield from iter_rawsql(value, child)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from iter_rawsql(value, f"{path}[{index}]")


def collect_queries(dashboard_dir: Path, datasource_dir: Path) -> tuple[list[Query], list[str]]:
    datasources = load_datasources(datasource_dir)
    queries: list[Query] = []
    skipped: list[str] = []
    for path in sorted(dashboard_dir.rglob("*.json")):
        dashboard = json.loads(path.read_text())
        uid = str(dashboard.get("uid") or (dashboard.get("metadata") or {}).get("name") or path.stem)
        title = str((dashboard.get("spec") or {}).get("title") or dashboard.get("title") or "")
        area = file_area(uid, title)
        if dashboard.get("apiVersion") == "dashboard.grafana.app/v2" or dashboard.get("kind") == "Dashboard":
            found = collect_v2(dashboard, area, datasources)
        else:
            found = collect_classic(dashboard, area, datasources)
        kept = {q.sql for q in found}
        for pointer, raw in iter_rawsql(dashboard):
            if raw not in kept:
                skipped.append(f"{path.name}:{pointer}")
        for query in found:
            refine_area(query)
        queries.extend(found)
    return queries, skipped


def refine_area(query: Query) -> None:
    if query.area != "other":
        return
    title = query.title.lower()
    if "diabet" in title or re.search(r"\bdm\b", title):
        query.area = "dm"
    elif "hypertension" in title or re.search(r"\bhtn\b", title):
        query.area = "htn"


def counts(queries: list[Query]) -> dict[str, int]:
    tally = {
        "total": len(queries),
        "htn": 0,
        "dm": 0,
        "drug_stock": 0,
        "overdue": 0,
        "home": 0,
        "shared": 0,
        "other": 0,
        "variable": 0,
    }
    for query in queries:
        if query.area in tally:
            tally[query.area] += 1
        if query.kind == "variable":
            tally["variable"] += 1
    return tally


def print_list(queries: list[Query], skipped: list[str], unknown: set[str]) -> None:
    print("sample variables:")
    for name in sorted(SAMPLE_VARS):
        shown = SAMPLE_VARS[name] if SAMPLE_VARS[name] != "" else "(empty)"
        print(f"  {name} = {shown}")
    print(f"  $__timeFrom() = '{TIME_FROM}'")
    print(f"  $__timeTo() = '{TIME_TO}'")
    print(f"  $__timeFilter(column) = column BETWEEN '{TIME_FROM}' AND '{TIME_TO}'")
    print(f"  <other ${{name}}> = {UNKNOWN_DEFAULT}")
    if unknown:
        print("defaults used for: " + ", ".join(sorted(unknown)))
    print()
    for query in queries:
        print(f"--- {query.label}")
        print(substitute(query.sql))
        print()
    if skipped:
        print(f"skipped write or non-load rawSql ({len(skipped)}):")
        for item in skipped:
            print(f"  {item}")
        print()
    tally = counts(queries)
    keys = ("total", "htn", "dm", "drug_stock", "overdue", "home", "shared", "other", "variable")
    print("COUNTS " + " ".join(f"{key}={tally[key]}" for key in keys))


def quote_ident(name: str) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ValueError(f"unsafe SQL identifier {name!r}")
    return name


def quote_search_path(search_path: str) -> str:
    parts = [quote_ident(part.strip()) for part in search_path.split(",") if part.strip()]
    if not parts:
        parts = ["public"]
    return ", ".join(parts)


def resolve_dsn() -> str | None:
    """None means libpq should use PGHOST and the other PG* variables."""
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    if any(os.environ.get(key) for key in ("PGHOST", "PGUSER", "PGPASSWORD", "PGDATABASE", "PGPORT")):
        return None
    return DEFAULT_DSN


def connect():
    import psycopg2

    dsn = resolve_dsn()
    if dsn is None:
        return psycopg2.connect(connect_timeout=5)
    return psycopg2.connect(dsn, connect_timeout=5)


def psql_command(script: str) -> list[str]:
    command = ["psql", "-X", "--no-psqlrc", "-v", "ON_ERROR_STOP=1", "-q"]
    dsn = resolve_dsn()
    if dsn:
        command.append(dsn)
    command.extend(["-c", script])
    return command


def execute_psql(query: Query, max_ms: int) -> tuple[float, str | None]:
    role = quote_ident(query.role)
    search_path = quote_search_path(query.search_path)
    sql = substitute(query.sql).strip().rstrip(";")
    script = (
        "BEGIN;\n"
        f"SET LOCAL ROLE {role};\n"
        f"SET LOCAL search_path TO {search_path};\n"
        f"SET LOCAL statement_timeout = '{int(max_ms)}ms';\n"
        f"{sql};\n"
        "ROLLBACK;\n"
    )
    env = os.environ.copy()
    env["PGCONNECT_TIMEOUT"] = "5"
    started = time.perf_counter()
    try:
        proc = subprocess.run(
            psql_command(script),
            capture_output=True,
            text=True,
            env=env,
            timeout=max(max_ms / 1000 + 10, 15),
        )
    except subprocess.TimeoutExpired:
        return (time.perf_counter() - started) * 1000, "psql timed out"
    elapsed = (time.perf_counter() - started) * 1000
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"psql exit {proc.returncode}").strip().splitlines()
        return elapsed, detail[-1]
    return elapsed, None


def execute_one(conn, query: Query, max_ms: int) -> tuple[float, str | None]:
    role = quote_ident(query.role)
    search_path = quote_search_path(query.search_path)
    sql = substitute(query.sql).strip().rstrip(";")
    try:
        with conn.cursor() as cur:
            cur.execute(f"SET LOCAL ROLE {role}")
            cur.execute(f"SET LOCAL search_path TO {search_path}")
            cur.execute("SET LOCAL statement_timeout = %s", (f"{max_ms}ms",))
            started = time.perf_counter()
            cur.execute(sql)
            if cur.description:
                cur.fetchall()
            elapsed = (time.perf_counter() - started) * 1000
        return elapsed, None
    except Exception as exc:
        elapsed = (time.perf_counter() - started) * 1000 if "started" in locals() else 0.0
        return elapsed, str(exc).strip().splitlines()[0]
    finally:
        conn.rollback()


def report(queries: list[Query], results: list[tuple[Query, float, str | None]], max_ms: int) -> int:
    failures = 0
    slowest = 0.0
    for query, elapsed, error in results:
        slowest = max(slowest, elapsed)
        if error:
            failures += 1
            print(f"FAIL {query.label} {elapsed:.0f}ms {error}")
        elif elapsed > max_ms:
            failures += 1
            print(f"FAIL {query.label} {elapsed:.0f}ms exceeds {max_ms}ms")
        else:
            print(f"ok   {query.label} {elapsed:.0f}ms")
    if failures:
        print(f"FAIL {failures} of {len(queries)} queries")
        return 1
    print(f"PASS {len(queries)} queries, slowest {slowest:.0f}ms, limit {max_ms}ms")
    return 0


def run_psql(queries: list[Query], max_ms: int) -> int:
    results = []
    for query in queries:
        if not query.role:
            results.append((query, 0.0, f"no datasource role for {query.datasource or '(none)'}"))
            continue
        try:
            elapsed, error = execute_psql(query, max_ms)
        except ValueError as exc:
            elapsed, error = 0.0, str(exc)
        results.append((query, elapsed, error))
    return report(queries, results, max_ms)


def run(queries: list[Query], max_ms: int) -> int:
    try:
        conn = connect()
    except ImportError:
        print("psycopg2 is not installed; running each query with psql", file=sys.stderr)
        return run_psql(queries, max_ms)
    except Exception as exc:
        where = os.environ.get("DATABASE_URL") or os.environ.get("PGHOST") or "localhost:5432"
        print(f"FAIL postgres is not reachable ({where}): {exc}", file=sys.stderr)
        print("Start the stack with ./scripts/demo_up.sh --fresh and re-run. Not hanging.", file=sys.stderr)
        return 1
    failures = 0
    slowest = 0.0
    try:
        conn.autocommit = False
        for query in queries:
            if not query.role:
                failures += 1
                print(f"FAIL {query.label} no datasource role for {query.datasource or '(none)'}")
                continue
            elapsed, error = execute_one(conn, query, max_ms)
            slowest = max(slowest, elapsed)
            if error:
                failures += 1
                print(f"FAIL {query.label} {elapsed:.0f}ms {error}")
            elif elapsed > max_ms:
                failures += 1
                print(f"FAIL {query.label} {elapsed:.0f}ms exceeds {max_ms}ms")
            else:
                print(f"ok   {query.label} {elapsed:.0f}ms")
    finally:
        conn.close()
    tally = counts(queries)
    if failures:
        print(f"FAIL {failures} of {tally['total']} queries")
        return 1
    print(f"PASS {tally['total']} queries, slowest {slowest:.0f}ms, limit {max_ms}ms")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--list", action="store_true", help="print queries and exit without connecting")
    parser.add_argument("--max-ms", type=int, default=2000, help="fail a query slower than this (default 2000)")
    parser.add_argument("--dashboards", type=Path, default=DASHBOARDS)
    parser.add_argument("--datasources", type=Path, default=DATASOURCES)
    args = parser.parse_args(argv)
    queries, skipped = collect_queries(args.dashboards, args.datasources)
    unknown: set[str] = set()
    for query in queries:
        substitute(query.sql, unknown)
    if args.list:
        print_list(queries, skipped, unknown)
        return 0
    if not queries:
        print(f"FAIL no queries under {args.dashboards}", file=sys.stderr)
        return 1
    return run(queries, args.max_ms)


if __name__ == "__main__":
    sys.exit(main())
