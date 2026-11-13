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
  4. Elements in REVIEWED_EDITS may differ from the ref, but only to the reviewed version: each is
     pinned by a SHA-256 of its JSON, the same way.
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
# Re-reviewed 2026-11-13: the section stacks on phones (drawing code only, no SQL).
REVIEWED_ADDITIONS = {
    "Hypertension": [
        {
            "title": "Overdue patients",
            "before": "Sub Levels",
            "elements": ["panel-overdue"],
            "sha256": "d002c3e45e0bb04e1771ec3ad4dfed8109bdd35a7790a8bcaa773416df5cb692",
        },
    ],
}


# Owner request 2026-11-13: the hearts360 charts work on phones and tablets (drawing code and CSS
# only, no SQL). Same change as simpledotorg H360-321 c5f6e4d.
REVIEWED_EDITS = {
    "panel-stc": "7e1cdcba6a700812064c4e588a66ab02226af6a3724d15a26fff991844ba02f3",
    "panel-outcomes": "e1572c327a784463b92c50ecd35f4a44d3b8c23f8ba4a6c679ad0898ce1fc6f7",
    "panel-7": "1e81f98c68630066a95df33f50a8f38c4438070c07de50d87c5d53ee2da03a51",
    "panel-8": "a12d8757a7adf5e94bd9947b5f5183cf1fa429a235c17e071dde41182da73c0d",
    "panel-dm-outcomes": "fcb554ac762c3b5bf0d56a5d8b2ce699e162938453e6234bd05871294bfd51be",
    "panel-dm-14": "672fbb39a08157d75bebd6ae0f7b47e72403890bb04c20d954403327b804d7a8",
    "panel-dm-15": "c4e651db85242b092c8c71c260b4d859e3321a8c2cfdbb657a254e3c41b45c72",
}


def element_hash(element):
    return hashlib.sha256(json.dumps(element, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def pin_edits(base_snap, head_snap, title, problems, hashes):
    """Swap each reviewed element for its pinned hash on both sides, so only an unreviewed edit fails."""
    for name, pinned in REVIEWED_EDITS.items():
        if name not in head_snap["elements"]:
            continue
        got = element_hash(head_snap["elements"][name])
        hashes.append((title, name, got))
        if got != pinned:
            problems.append(f"{title}: element {name!r} differs from the reviewed version (sha256 {got})")
        base_snap["elements"][name] = head_snap["elements"][name] = f"reviewed {pinned}"


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
        base_snap, head_snap = tab_snapshot(base, find_tab(base, title)), tab_snapshot(head, head_tab)
        pin_edits(base_snap, head_snap, title, problems, hashes)
        same = base_snap == head_snap
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
