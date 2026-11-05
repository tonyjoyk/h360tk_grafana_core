#!/usr/bin/env python3
"""Fail if the Hypertension or Diabetes tab differs from the reviewed baseline.

The baseline is a git ref (default 08a2894, the tip of simpledotorg demo/cascade-cohort) plus the
sections added on purpose since then, listed in REVIEWED_ADDITIONS. Each addition is one row of the
Hypertension tab (a title and the panel elements it references), pinned by a SHA-256 of its JSON.

The check:
  1. The Diabetes tab and the dashboard variables equal the ref exactly.
  2. Each reviewed row is in the Hypertension tab, directly before the row named in `before`, and its
     row JSON and elements hash to the pinned value. Any edit to the section fails until it is
     reviewed again and the hash updated (print it with --print-hashes).
  3. With the reviewed rows taken out, the Hypertension tab and every element it references equal
     the ref exactly. So nothing else on the tab can move, change or disappear.
"""
import copy
import hashlib
import json
import subprocess
import sys

DASHBOARD = "grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension-diabetes.program.json"
TABS = ("Hypertension", "Diabetes")
DEFAULT_REF = "08a2894"

# Story 5.18 (owner request 2026-11-05): overdue section above the facility comparison.
REVIEWED_ADDITIONS = {
    "Hypertension": [
        {
            "title": "Overdue patients",
            "before": "Sub Levels",
            "elements": ["panel-overdue"],
            "sha256": "9c685d29c3e21726e296e9c7667dc3e9d8cc6efc05b5713f82bd890075e0e375",
        },
    ],
}


def load(ref):
    if ref == "WORKTREE":
        with open(DASHBOARD) as f:
            return json.load(f)
    return json.loads(subprocess.check_output(["git", "show", f"{ref}:{DASHBOARD}"]))


def element_names(node):
    found = set()
    if isinstance(node, dict):
        if node.get("kind") == "ElementReference":
            found.add(node["name"])
        for value in node.values():
            found |= element_names(value)
    elif isinstance(node, list):
        for value in node:
            found |= element_names(value)
    return found


def find_tab(dashboard, title):
    for row in dashboard["spec"]["layout"]["spec"]["rows"]:
        for tab in row["spec"]["layout"]["spec"].get("tabs", []):
            if tab["spec"]["title"] == title:
                return tab
    raise SystemExit(f"tab {title!r} not found")


def tab_snapshot(dashboard, tab):
    names = sorted(element_names(tab))
    return {"layout": tab, "elements": {n: dashboard["spec"]["elements"][n] for n in names}}


def section_hash(row, elements):
    blob = json.dumps({"row": row, "elements": elements}, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode()).hexdigest()


def strip_additions(dashboard, title, problems, hashes):
    """Return a copy of the tab without its reviewed rows, checking each row's place and hash."""
    tab = copy.deepcopy(find_tab(dashboard, title))
    for add in REVIEWED_ADDITIONS.get(title, []):
        rows = tab["spec"]["layout"]["spec"]["rows"]
        titles = [r["spec"].get("title") for r in rows]
        if titles.count(add["title"]) != 1:
            problems.append(f"{title}: expected one row {add['title']!r}, found {titles.count(add['title'])}")
            continue
        i = titles.index(add["title"])
        if i + 1 >= len(rows) or titles[i + 1] != add["before"]:
            problems.append(f"{title}: row {add['title']!r} is not directly before {add['before']!r}")
        row = rows.pop(i)
        names = sorted(element_names(row))
        if names != sorted(add["elements"]):
            problems.append(f"{title}: row {add['title']!r} references {names}, reviewed {add['elements']}")
        got = section_hash(row, {n: dashboard["spec"]["elements"].get(n) for n in names})
        hashes.append((title, add["title"], got))
        if got != add["sha256"]:
            problems.append(f"{title}: row {add['title']!r} differs from the reviewed version (sha256 {got})")
    return tab


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ref = args[0] if args else DEFAULT_REF
    base, head = load(ref), load("WORKTREE")
    failed = False
    hashes = []
    for title in TABS:
        problems = []
        head_tab = strip_additions(head, title, problems, hashes)
        same = tab_snapshot(base, find_tab(base, title)) == tab_snapshot(head, head_tab)
        extra = [a["title"] for a in REVIEWED_ADDITIONS.get(title, [])]
        label = f" + reviewed {', '.join(repr(t) for t in extra)}" if extra else ""
        print(f"{title}: {'unchanged' if same and not problems else 'CHANGED'} vs {ref}{label}")
        for p in problems:
            print(f"  {p}")
        failed |= not same or bool(problems)
    same_vars = base["spec"]["variables"] == head["spec"]["variables"]
    print(f"Dashboard variables: {'unchanged' if same_vars else 'CHANGED'} vs {ref}")
    failed |= not same_vars
    if "--print-hashes" in sys.argv:
        for tab, row, digest in hashes:
            print(f"sha256 {tab} / {row}: {digest}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
