#!/usr/bin/env python3
"""Fail if the Hypertension or Diabetes tab differs from the cascade-cohort baseline.

Compares each tab's layout and every panel element it references, plus the
dashboard variables those panels read, against a git ref (default 08a2894,
the tip of simpledotorg demo/cascade-cohort).
"""
import json
import subprocess
import sys

DASHBOARD = "grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension-diabetes.program.json"
TABS = ("Hypertension", "Diabetes")


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


def tab_snapshot(dashboard, title):
    for row in dashboard["spec"]["layout"]["spec"]["rows"]:
        for tab in row["spec"]["layout"]["spec"].get("tabs", []):
            if tab["spec"]["title"] == title:
                names = sorted(element_names(tab))
                return {
                    "layout": tab,
                    "elements": {n: dashboard["spec"]["elements"][n] for n in names},
                }
    raise SystemExit(f"tab {title!r} not found")


def main():
    ref = sys.argv[1] if len(sys.argv) > 1 else "08a2894"
    base, head = load(ref), load("WORKTREE")
    failed = False
    for title in TABS:
        same = tab_snapshot(base, title) == tab_snapshot(head, title)
        print(f"{title}: {'unchanged' if same else 'CHANGED'} vs {ref}")
        failed |= not same
    same_vars = base["spec"]["variables"] == head["spec"]["variables"]
    print(f"Dashboard variables: {'unchanged' if same_vars else 'CHANGED'} vs {ref}")
    failed |= not same_vars
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
