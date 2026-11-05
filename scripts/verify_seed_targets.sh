#!/usr/bin/env bash
# Print the planted demo numbers and check them (story 7.2, AD-34, PD-17,
# CLINICAL-RULES section 7). Read-only.
#
#   ./scripts/verify_seed_targets.sh
#
# For month 2026-10-01 it prints each PHC's control, BP readings ratio, titration,
# new-patient loss, usable phone, called, early, on-statin and CCB Patient-Days,
# and fails when a value is outside the section 7 range. A report whose function
# returns no rows (a cut report, PD decision 2) is shown as "cut" and not checked.
# It also checks that exactly one facility, PHC-E, carries the "Looks fine" pill
# (looks_fine_check) on both BP readings check and Stepping up.
#
# BP Fudging PRD check (UX-25, seed 50): for the last 4 completed quarters before
# the end of MONTH, ratio = visits with systolic 130-139 / visits with systolic
# 140-149, over all visits of the PHC's patients (SHCs included). PHC-E must be
# at 2.0 or more in the last two quarters and rising; every other PHC must be at
# or below 1.8 in all 4. Worked out here with its own SQL, not report_fudging_*.
# Since 0.6.16_to_0.6.17, report_fudging's score is this PRD ratio for the newest
# completed quarter (2026-Q3 for October), so the "Readings" column must equal the
# last quarter worked out here, and its targets are the quarterly ones: PHC-E 2.0
# to 2.6 (flagged), the others 0.9 to 1.79 (not flagged, under the 1.8 warning
# line). The CR-4 3-month 135-139 / 140-144 score (PHC-E 5.2-5.6, others 0.9-1.5,
# CLINICAL-RULES section 7) is no longer shown by any report and is not checked.
#
# The demo data comes from one upload file (test_data/demo/demo_generated.xlsx,
# medicines included) plus the call and drug stock seeds. The section 7 targets
# are unchanged; build_demo_data.py prints the numbers it planted.
#
#   PSQL   command that reads SQL on stdin
#          (default: docker exec -i postgres psql -U h360tk_root -d heart360tk_database)
#   MONTH  reporting month (default 2026-10-01)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/h360_env.sh"

PSQL="${PSQL:-docker exec -i ${H360_PG_CONTAINER:-postgres} psql -U h360tk_root -d heart360tk_database}"
MONTH="${MONTH:-2026-10-01}"

if [[ ! "$MONTH" =~ ^[0-9]{4}-[0-9]{2}-01$ ]]; then
  echo "verify_seed_targets: MONTH must look like 2026-10-01" >&2
  exit 2
fi

sql=$(cat <<SQL
SET search_path TO heart360tk_schema, public;
WITH f AS (
    SELECT DISTINCT ON (name) id, name
    FROM org_units
    WHERE level = 3 AND name IN ('PHC-A','PHC-B','PHC-C','PHC-D','PHC-E','PHC-F')
    ORDER BY name, id
)
SELECT concat_ws(E'\t',
    f.name,
    (SELECT controlled_pct FROM h360_control_summary(DATE '$MONTH', f.id) WHERE ref_month = DATE '$MONTH'),
    (SELECT controlled_pct FROM chat_control_summary(DATE '$MONTH', f.id) WHERE is_selected),
    COALESCE((SELECT score::text FROM report_fudging(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT looks_fine_check::text FROM report_fudging(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT titration_pct::text FROM report_titration(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT looks_fine_check::text FROM report_titration(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT new_loss_pct::text FROM report_new_patients(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT new_usable_phone_pct::text FROM report_new_patients(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT called_pct::text FROM report_calling(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT early_pct::text FROM report_calling(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT on_statin_pct::text FROM report_statins(DATE '$MONTH', f.id) WHERE is_selected), 'CUT'),
    COALESCE((SELECT round(category_patient_days, 1)::text
              FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '$MONTH', f.id)
              WHERE drug_category = 'CCB'), 'NONE'),
    COALESCE((SELECT round(category_patient_days, 1)::text
              FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '$MONTH', f.id)
              WHERE drug_category = 'Diuretic'), 'NONE'),
    h360_threshold('common', 'high_control_pct')
)
FROM f
ORDER BY f.name;
SQL
)

if ! out="$(printf '%s\n' "$sql" | $PSQL -X -v ON_ERROR_STOP=1 -qtA 2>&1)"; then
  echo "FAIL verify_seed_targets: query failed" >&2
  echo "$out" >&2
  echo "Next step: start the stack (./scripts/demo_up.sh) and re-run." >&2
  exit 1
fi

qsql=$(cat <<SQL
SET search_path TO heart360tk_schema, public;
WITH f AS (
    SELECT DISTINCT ON (name) id, name
    FROM org_units
    WHERE level = 3 AND name IN ('PHC-A','PHC-B','PHC-C','PHC-D','PHC-E','PHC-F')
    ORDER BY name, id
),
q AS (
    SELECT gs::date AS q_start
    FROM generate_series(
        date_trunc('quarter', DATE '$MONTH' + INTERVAL '1 month') - INTERVAL '12 months',
        date_trunc('quarter', DATE '$MONTH' + INTERVAL '1 month') - INTERVAL '3 months',
        INTERVAL '3 months') AS gs
)
SELECT concat_ws(E'\t', f.name, to_char(q.q_start, 'YYYY-"Q"Q'),
    count(bp.encounter_id) FILTER (WHERE bp.systolic_bp >= 130 AND bp.systolic_bp < 140),
    count(bp.encounter_id) FILTER (WHERE bp.systolic_bp >= 140 AND bp.systolic_bp < 150))
FROM f
CROSS JOIN q
LEFT JOIN patients p ON p.org_unit_id IN (SELECT id FROM get_descendant_ids(f.id))
LEFT JOIN encounters e ON e.patient_id = p.patient_id
                      AND e.encounter_date >= q.q_start
                      AND e.encounter_date <  q.q_start + INTERVAL '3 months'
LEFT JOIN blood_pressures bp ON bp.encounter_id = e.id
GROUP BY f.name, q.q_start
ORDER BY f.name, q.q_start;
SQL
)

if ! qout="$(printf '%s\n' "$qsql" | $PSQL -X -v ON_ERROR_STOP=1 -qtA 2>&1)"; then
  echo "FAIL verify_seed_targets: quarterly query failed" >&2
  echo "$qout" >&2
  exit 1
fi

MONTH="$MONTH" python3 - "$out" "$qout" <<'PY'
import os
import sys
from decimal import ROUND_HALF_UP, Decimal

rows = [line.split("\t") for line in sys.argv[1].splitlines() if line.strip()]
qrows = [line.split("\t") for line in sys.argv[2].splitlines() if line.strip()]
month = os.environ["MONTH"]

# CLINICAL-RULES section 7, targets for October 2026. (lo, hi) inclusive;
# None means no bound. "lt" means strictly below.
DEFAULT = {
    "fudging": (0.9, 1.79), "titration": (42, 50), "loss": (24, 30), "phone": (95, None),
    "called": None, "early": (30, 45), "statin": (28, 35), "ccb": (60, 120),
}
TARGETS = {
    "PHC-A": {"called": (10, 12), "early": (55, 65)},
    "PHC-B": {"called": (6, 9), "ccb": ("lt", 30)},
    "PHC-C": {"called": (4, 8), "phone": (40, 48)},
    "PHC-D": {"called": (4, 8), "loss": (36, 40)},
    "PHC-E": {"called": (3, 5), "control": (72, 78), "fudging": (2.0, 2.6), "titration": (26, 30)},
    "PHC-F": {"called": (8, 10), "early": (40, 50), "statin": (20, 23)},
}
COLS = [
    ("control", "Control"), ("fudging", "Readings"), ("titration", "Titration"),
    ("loss", "NP loss"), ("phone", "Phone"), ("called", "Called"), ("early", "Early"),
    ("statin", "Statin"), ("ccb", "CCB PD"),
]

failures = []


def rng_text(r):
    if r is None:
        return "-"
    lo, hi = r
    if lo == "lt":
        return f"< {hi:g}"
    if hi is None:
        return f">= {lo:g}"
    return f"{lo:g}-{hi:g}"


def check(name, key, raw, r):
    if raw == "CUT":
        return "cut"
    if r is None:
        return raw
    if raw in ("", "NONE"):
        failures.append(f"{name} {key}: no value (target {rng_text(r)})")
        return f"{raw or 'null'} !"
    value = float(raw)
    lo, hi = r
    ok = value < hi if lo == "lt" else (value >= lo and (hi is None or value <= hi))
    if not ok:
        failures.append(f"{name} {key}: {raw} outside {rng_text(r)}")
    return raw if ok else f"{raw} !"


if len(rows) != 6:
    print(f"FAIL expected six PHCs, found {len(rows)}: {[r[0] for r in rows]}")
    sys.exit(1)

print(f"Seed targets for {month} (CLINICAL-RULES section 7). '!' marks a miss.")
header = f"{'Facility':<8}" + "".join(f"{label:>11}" for _, label in COLS) + "  Pill (BP / Steps)"
print(header)
print("-" * len(header))

pill_bp, pill_steps = [], []
for row in rows:
    (name, ctl_h360, ctl_chat, fud, fud_pill, tit, tit_pill, loss, phone,
     called, early, statin, ccb, thiazide, high_ctl) = row
    targets = dict(DEFAULT)
    targets["control"] = None
    targets.update(TARGETS.get(name, {}))
    values = {
        "control": ctl_h360, "fudging": fud, "titration": tit, "loss": loss, "phone": phone,
        "called": called, "early": early, "statin": statin, "ccb": ccb,
    }
    cells = [check(name, key, values[key], targets[key]) for key, _ in COLS]

    if ctl_h360 != ctl_chat:
        failures.append(f"{name} control: h360_control_summary {ctl_h360} != chat_control_summary {ctl_chat}")
    if name != "PHC-E" and ctl_h360 and float(ctl_h360) >= float(high_ctl):
        failures.append(f"{name} control {ctl_h360} reaches high_control_pct {high_ctl}; it would flip to 'Looks fine'")
    if name == "PHC-F" and thiazide not in ("", "NONE"):
        failures.append(f"PHC-F thiazide (Diuretic) Patient-Days should be unknown, got {thiazide}")
    if fud_pill == "true":
        pill_bp.append(name)
    if tit_pill == "true":
        pill_steps.append(name)
    print(f"{name:<8}" + "".join(f"{c:>11}" for c in cells) + f"  {fud_pill} / {tit_pill}")

print("Targets:  " + "; ".join(
    f"{name}: " + ", ".join(f"{k} {rng_text(v)}" for k, v in TARGETS[name].items()) for name in TARGETS))
print("Others:   " + ", ".join(f"{k} {rng_text(v)}" for k, v in DEFAULT.items() if v) +
      f"; control as source and below high_control_pct; PHC-F thiazide unknown")
print(f"Control from h360_control_summary; chat_control_summary must match.")

if "CUT" not in (rows[0][4], rows[0][6]):
    if pill_bp != ["PHC-E"]:
        failures.append(f"'Looks fine' pill on BP readings check: {pill_bp or 'none'}, expected exactly PHC-E")
    if pill_steps != ["PHC-E"]:
        failures.append(f"'Looks fine' pill on Stepping up: {pill_steps or 'none'}, expected exactly PHC-E")
print(f"Pill: BP readings check {pill_bp or 'none'}; Stepping up {pill_steps or 'none'}")

# BP Fudging PRD (UX-25): green < 1.8, yellow >= 1.8, flag >= 2.0.
PRD_FLAG, PRD_WARN = 2.0, 1.8
quarters = sorted({q for _, q, _, _ in qrows})
ratios = {}
for name, q, a, b in qrows:
    a, b = int(a), int(b)
    # numeric round() in SQL rounds half away from zero
    ratios[(name, q)] = (a, b, float((Decimal(a) / Decimal(b)).quantize(Decimal('0.01'), ROUND_HALF_UP)) if b else None)
print("")
print("BP Fudging PRD ratio, 130-139 / 140-149, all visits (flag >= 2.0, warn >= 1.8, others must be <= 1.8)")
print(f"{'Facility':<8}" + "".join(f"{q:>20}" for q in quarters))
for name in sorted({n for n, _, _, _ in qrows}):
    cells = []
    for q in quarters:
        a, b, r = ratios[(name, q)]
        mark = ""
        if name == "PHC-E":
            if q in quarters[-2:] and (r is None or r < PRD_FLAG):
                failures.append(f"PHC-E PRD ratio {q}: {r} below {PRD_FLAG:g}")
                mark = " !"
        elif r is None or r > PRD_WARN:
            failures.append(f"{name} PRD ratio {q}: {r} above {PRD_WARN:g}")
            mark = " !"
        cells.append(f"{a}/{b}=" + ("-" if r is None else f"{r:.2f}") + mark)
    print(f"{name:<8}" + "".join(f"{c:>20}" for c in cells))
# report_fudging (flags, Start here, chat) reads the same rule: newest completed quarter.
for row in rows:
    name, fud = row[0], row[3]
    if fud == "CUT" or not quarters:
        continue
    own = ratios.get((name, quarters[-1]), (0, 0, None))[2]
    got = None if fud == "" else round(float(fud), 2)
    if got != own:
        failures.append(f"{name} report_fudging score {fud or 'null'} != PRD ratio {own} for {quarters[-1]}")
if len(quarters) == 4:
    e_last = [ratios[("PHC-E", q)][2] for q in quarters[-2:]]
    if None not in e_last and not e_last[1] > e_last[0]:
        failures.append(f"PHC-E PRD ratio not rising: {quarters[-2]} {e_last[0]}, {quarters[-1]} {e_last[1]}")
else:
    failures.append(f"expected 4 completed quarters, found {quarters}")

if failures:
    print("")
    for line in failures:
        print(f"FAIL {line}")
    sys.exit(1)
print("PASS seed targets")
PY
