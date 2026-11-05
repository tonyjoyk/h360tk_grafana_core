#!/usr/bin/env bash
# Fail if a demo seed can change or remove existing rows, or roll dice (story 4.8).
# Scans test_data/demo/seeds/*.sql. Comments are ignored. A planted UPDATE,
# DELETE or TRUNCATE, a DROP of a patient table, or random() exits nonzero
# and names the file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEEDS="${1:-$ROOT/test_data/demo/seeds}"

if [[ ! -d "$SEEDS" ]]; then
    echo "verify_seeds_insert_only: missing folder $SEEDS" >&2
    exit 1
fi

shopt -s nullglob
files=("$SEEDS"/*.sql)
if (( ${#files[@]} == 0 )); then
    echo "verify_seeds_insert_only: no seed files in $SEEDS" >&2
    exit 1
fi

python3 - "$SEEDS" "${files[@]}" <<'PY'
import re
import sys

folder = sys.argv[1]
paths = sys.argv[2:]
patient_tables = (
    "patients",
    "patient_diagnoses",
    "encounters",
    "blood_pressures",
    "blood_sugars",
    "prescriptions",
    "prescription_lines",
    "patient_cvd_history",
    "call_results",
    "call_results_audit",
    "scheduled_visits",
)
drop_re = re.compile(
    r"\bDROP\b(?:\s+\w+){0,6}\s+(?:IF\s+EXISTS\s+)?(?:[\w.]+\.)?("
    + "|".join(patient_tables)
    + r")\b",
    re.IGNORECASE,
)
keyword_re = re.compile(r"\b(UPDATE|DELETE|TRUNCATE)\b", re.IGNORECASE)
random_re = re.compile(r"\brandom\s*\(", re.IGNORECASE)

def strip_comments(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                break
            i = end + 2
            continue
        if text.startswith("--", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text[i] == "'":
            out.append(text[i])
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        out.append(text[i + 1])
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        out.append(text[i])
        i += 1
    return "".join(out)

failed = False
for path in paths:
    raw = open(path, encoding="utf-8").read()
    code = strip_comments(raw)
    name = path.rsplit("/", 1)[-1]
    problems = []
    for match in keyword_re.finditer(code):
        problems.append(match.group(1).upper())
    for match in random_re.finditer(code):
        problems.append("random()")
    for match in drop_re.finditer(code):
        problems.append(f"DROP {match.group(1)}")
    if problems:
        failed = True
        uniq = []
        for item in problems:
            if item not in uniq:
                uniq.append(item)
        print(
            f"verify_seeds_insert_only: {name} contains {', '.join(uniq)}",
            file=sys.stderr,
        )

if failed:
    sys.exit(1)
print(f"verify_seeds_insert_only: ok ({len(paths)} files)")
PY
