#!/usr/bin/env python3
"""Build the HEARTS360 Reports dashboard from one source file per tab (story 5.11, AD-28).

Inputs (dashboard_src/reports/):
  _shell.json        uid, title, variables, links, the Change location row and
                     one row whose layout is an empty TabsLayout (tabs: []).
  <n>-<slug>.json    one tab: {"title", "elements", "layout"}. Every element key
                     starts with panel-<slug>-; the title equals its TABS title.
                     0-start.json is the `Start here` overview tab (panel-start-*).

Output (generated, committed):
  grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.reports.json

The TABS list below is the tab order. Removing a line drops the tab (stub rule).

The build fails (exit 2) on: a missing source file, a duplicate JSON key in any
source file, a shell without spec, an element key
used twice, a tab element key without its panel-<slug>- prefix, a tab title
that differs from TABS, a layout reference to an undefined element, or a shell
without exactly one empty TabsLayout. Panel ids are renumbered 1..N in output
order. Keys starting with "_" in _shell.json are notes and are dropped.

Shared snippets (story 5.13; dashboard_src/reports/_shared/README.md):
  Any JSON string value in _shell.json or a tab file may contain
    {{shared:<file>}}  replaced by the text of dashboard_src/reports/_shared/<file>
                       (trailing newlines trimmed). Use it inside afterRender,
                       styles, getOption, content or rawSql. One level only: an
                       included file may not contain {{shared:...}} itself.
    {{tabs}}           replaced (after includes) by the TABS list as JSON:
                       [{"report": "<internal slug>", "title": ..., "slug": ...}]
  A missing file, a bad name or a leftover "{{shared:" fails the build.
  Handlebars {{...}} in Business Text content is left alone.

Tab deep link (AD-29, PD-4):
  /d/heart360_reports?var-org_unit=<id>&var-reporting_month=<YYYY-MM-DD>&-dtab=<Tab-slug>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "dashboard_src" / "reports"
SHELL = SRC / "_shell.json"
SHARED_DIR = "_shared"
OUT = ROOT / "grafana_provisioning" / "dashboards" / "HEARTS360 Dashboards" / "heart360.reports.json"
UID = "heart360_reports"

# (visible title, URL tab slug, source file). Order = tab order. Internal slug comes from the file name.
# Story 7.9 (UX-17, UX-14): `Start here` first, then the cause order low control -> missed visits -> statins.
# The file numbers are unchanged; only the list order sets the tab order.
TABS = [
    ("Start here", "Start-here", "0-start.json"),
    ("Stepping up", "Stepping-up", "2-titration.json"),
    ("Right medicines", "Right-medicines", "1-adherence.json"),
    ("BP readings check", "BP-readings-check", "3-fudging.json"),
    ("Overdue calls", "Overdue-calls", "5-calling.json"),
    ("Statins", "Statins", "4-statins.json"),
]
# "start" is the overview tab (panel-start-*); it has no report_flags.report of its own.
INTERNAL_SLUGS = ("start", "adherence", "titration", "fudging", "statins", "calling")


class BuildError(Exception):
    pass


INCLUDE_RE = re.compile(r"\{\{shared:([^{}]*)\}\}")
INCLUDE_NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
TABS_TOKEN = "{{tabs}}"


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def internal_slug(source: str) -> str:
    stem = Path(source).stem
    slug = stem.split("-", 1)[1] if "-" in stem else stem
    if slug not in INTERNAL_SLUGS:
        raise BuildError(f"{source}: internal slug {slug!r} is not one of {', '.join(INTERNAL_SLUGS)}")
    return slug


def url_slug(title: str) -> str:
    """Grafana's tab URL slug: the title with spaces turned into hyphens."""
    return "-".join(title.split())


def deep_link(org_unit: int | str, reporting_month: str, tab_slug: str) -> str:
    return f"/d/{UID}?var-org_unit={org_unit}&var-reporting_month={reporting_month}&-dtab={tab_slug}"


def load_strict(path: Path):
    def no_duplicates(pairs):
        seen = {}
        for key, value in pairs:
            if key in seen:
                raise BuildError(f"{rel(path)}: duplicate key {key!r}")
            seen[key] = value
        return seen

    if not path.is_file():
        raise BuildError(f"{rel(path)}: not found")
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)
    except json.JSONDecodeError as exc:
        raise BuildError(f"{rel(path)}: invalid JSON: {exc}") from exc


def tabs_json() -> str:
    """The TABS list as compact JSON, for the {{tabs}} token (report key, visible title, URL slug)."""
    return json.dumps(
        [{"report": internal_slug(source), "title": title, "slug": slug} for title, slug, source in TABS],
        ensure_ascii=False, separators=(",", ":"),
    )


def expand_shared(node, src: Path, where: str, cache: dict[str, str]):
    """Replace {{shared:<file>}} and {{tabs}} in every string of node (returns a new node)."""
    if isinstance(node, dict):
        return {key: expand_shared(value, src, where, cache) for key, value in node.items()}
    if isinstance(node, list):
        return [expand_shared(value, src, where, cache) for value in node]
    if not isinstance(node, str) or ("{{shared:" not in node and TABS_TOKEN not in node):
        return node

    def include(match: re.Match) -> str:
        name = match.group(1)
        if not INCLUDE_NAME_RE.fullmatch(name):
            raise BuildError(f"{where}: bad shared include name {name!r}")
        if name not in cache:
            path = src / SHARED_DIR / name
            if not path.is_file():
                raise BuildError(f"{where}: {{{{shared:{name}}}}} not found ({rel(path)})")
            text = path.read_text(encoding="utf-8").rstrip("\n")
            if "{{shared:" in text:
                raise BuildError(f"{rel(path)}: shared files may not include other shared files")
            cache[name] = text
        return cache[name]

    text = INCLUDE_RE.sub(include, node)
    if "{{shared:" in text:
        raise BuildError(f"{where}: malformed {{{{shared:...}}}} placeholder")
    return text.replace(TABS_TOKEN, tabs_json())


def element_refs(node) -> list[str]:
    found: list[str] = []
    if isinstance(node, dict):
        if node.get("kind") == "ElementReference" and node.get("name"):
            found.append(node["name"])
        for value in node.values():
            found.extend(element_refs(value))
    elif isinstance(node, list):
        for value in node:
            found.extend(element_refs(value))
    return found


def find_tabs_layouts(node, out: list[dict]) -> list[dict]:
    if isinstance(node, dict):
        if node.get("kind") == "TabsLayout":
            out.append(node)
        for value in node.values():
            find_tabs_layouts(value, out)
    elif isinstance(node, list):
        for value in node:
            find_tabs_layouts(value, out)
    return out


def build(src: Path = SRC) -> str:
    cache: dict[str, str] = {}
    shell = load_strict(src / "_shell.json")
    shell = {k: v for k, v in shell.items() if not k.startswith("_")}
    shell = expand_shared(shell, src, "_shell.json", cache)
    spec = shell.get("spec")
    if not isinstance(spec, dict) or not isinstance(spec.get("layout"), dict):
        raise BuildError("_shell.json: needs a spec with a layout")
    if shell.get("uid") != UID:
        raise BuildError(f"_shell.json: uid must be {UID!r}")

    tabs_layouts = find_tabs_layouts(spec["layout"], [])
    if len(tabs_layouts) != 1 or tabs_layouts[0].get("spec", {}).get("tabs"):
        raise BuildError("_shell.json: needs exactly one TabsLayout with an empty tabs list")
    tabs_slot = tabs_layouts[0]["spec"]["tabs"]

    elements: dict = dict(spec.get("elements") or {})
    for name in element_refs(spec["layout"]):
        if name not in elements:
            raise BuildError(f"_shell.json: layout references undefined element {name!r}")

    seen_titles: set[str] = set()
    for title, slug, source in TABS:
        if slug != url_slug(title):
            raise BuildError(f"TABS: slug {slug!r} does not match title {title!r} (expected {url_slug(title)!r})")
        if title in seen_titles:
            raise BuildError(f"TABS: title {title!r} listed twice")
        seen_titles.add(title)
        prefix = f"panel-{internal_slug(source)}-"
        tab = expand_shared(load_strict(src / source), src, source, cache)
        if set(tab) != {"title", "elements", "layout"}:
            raise BuildError(f"{source}: top-level keys must be exactly title, elements, layout (found {sorted(tab)})")
        if tab["title"] != title:
            raise BuildError(f"{source}: title {tab['title']!r} differs from TABS title {title!r}")
        for key in tab["elements"]:
            if not key.startswith(prefix):
                raise BuildError(f"{source}: element key {key!r} lacks the prefix {prefix!r}")
            if key in elements:
                raise BuildError(f"{source}: element key {key!r} is already defined")
            elements[key] = tab["elements"][key]
        for name in element_refs(tab["layout"]):
            if name not in tab["elements"]:
                raise BuildError(f"{source}: layout references undefined element {name!r}")
        tabs_slot.append({"kind": "TabsLayoutTab", "spec": {"title": title, "layout": tab["layout"]}})

    for number, element in enumerate(elements.values(), start=1):
        if isinstance(element, dict) and element.get("kind") == "Panel":
            element["spec"]["id"] = number
    spec["elements"] = elements
    return json.dumps(shell, indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n", 1)[0],
        epilog=(
            "Tabs (title / URL slug / source): "
            + "; ".join(f"{t} / {s} / {f}" for t, s, f in TABS)
            + ". Shared snippets: a JSON string may contain {{shared:<file>}}, replaced by "
            "dashboard_src/reports/_shared/<file> (one level, no nesting), and {{tabs}}, replaced by "
            "the TABS list as JSON [{report, title, slug}]. See dashboard_src/reports/_shared/README.md."
        ),
    )
    parser.add_argument("--check", action="store_true",
                        help="build in memory and exit 1 if the committed heart360.reports.json differs")
    parser.add_argument("--output", type=Path, default=OUT, help="output file (default: %(default)s)")
    args = parser.parse_args(argv)

    try:
        text = build()
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.check:
        current = args.output.read_text(encoding="utf-8") if args.output.exists() else None
        if current != text:
            print(f"stale: {rel(args.output)} differs from the sources; run scripts/build_reports_dashboard.py",
                  file=sys.stderr)
            return 1
        print(f"ok: {rel(args.output)} is up to date")
        return 0

    args.output.write_text(text, encoding="utf-8")
    print(f"wrote {rel(args.output)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
