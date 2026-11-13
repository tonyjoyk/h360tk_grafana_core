#!/bin/bash
# Verifies the chat levers of 0.6.13_to_0.6.14 (stories 6.1 and 6.2, AD-30, AD-31, CR-6, EP-3, EP-10):
#   chat_control_summary         equals h360_control_summary and control_pct of report_fudging and
#                                report_titration for the same place and month;
#   chat_drug_stock_gate         Patient-Days per category from the stock board's All row, `low` under
#                                chat.stock_days_below (CLINICAL-RULES Patient-Days F1/F2 cases);
#   chat_call_plan               86 overdue with a phone gives 22, 22, 22, 20; weeks sum to
#                                overdue_with_phone_n of report_calling;
#   chat_facility_rank_district  Chattogram breaches at and over each line, also_check, rank, and
#                                tolerance of a stub report;
# thresholds read from report_flag_thresholds, grants (h360_api only) and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_chat_levers.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATIONS="$ROOT/pg_init_scripts/migrations"
# The 01_heart360_tables.sql chain without 0.6.5_to_0.6.6 (roles and grants; the roles are made
# below): drug stock, medicine model, report common, the five reports and this migration.
CHAIN=(0.6.0_to_0.6.1 0.6.1_to_0.6.2 0.6.2_to_0.6.3 0.6.3_to_0.6.4 0.6.4_to_0.6.5 0.6.6_to_0.6.7
       0.6.7_to_0.6.8 0.6.8_to_0.6.9 0.6.9_to_0.6.10 0.6.10_to_0.6.11 0.6.11_to_0.6.12
       0.6.12_to_0.6.13 0.6.13_to_0.6.14)
MIGRATION="$MIGRATIONS/0.6.13_to_0.6.14.sql"
DB_NAME="${CHAT_LEVERS_VERIFY_DB:-chat_levers_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for m in "${CHAIN[@]}"; do
    if [[ ! -f "$MIGRATIONS/$m.sql" ]]; then
        echo "missing file: $MIGRATIONS/$m.sql" >&2
        exit 1
    fi
done
if [[ ! -f "$TABLES" ]]; then
    echo "missing file: $TABLES" >&2
    exit 1
fi

if ! grep -q '\\ir migrations/0.6.13_to_0.6.14.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.13_to_0.6.14.sql" >&2
    exit 1
fi

if ! "${PSQL_CMD[@]}" -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
    echo "verifier-blocked: '$PSQL' cannot connect" >&2
    exit 1
fi

psql_admin() { "${PSQL_CMD[@]}" -d postgres -X -v ON_ERROR_STOP=1 -q "$@"; }
psql_db()    { "${PSQL_CMD[@]}" -d "$DB_NAME" -X -v ON_ERROR_STOP=1 -q "$@"; }

drop_db() {
    psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null
    psql_admin -c "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
}

cleanup() {
    drop_db || true
}
trap cleanup EXIT

# Roles are cluster-wide and may belong to a live stack: create if missing, never drop.
drop_db
psql_admin <<SQL
DO \$\$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['heart360tk', 'heart360tk_cached', 'heart360tk_reader', 'h360_api'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END \$\$;
CREATE DATABASE ${DB_NAME} OWNER heart360tk;
SQL

psql_db <<SQL
CREATE SCHEMA heart360tk_schema AUTHORIZATION heart360tk;
CREATE SCHEMA heart360tk_reporting AUTHORIZATION heart360tk;
-- What 0.6.5_to_0.6.6 gives the login roles on these schemas.
GRANT USAGE ON SCHEMA heart360tk_schema, heart360tk_reporting TO heart360tk_reader;
GRANT USAGE ON SCHEMA heart360tk_schema TO h360_api;
SQL

echo "apply core tables (01_heart360_tables.sql up to the reporting tables)"
if ! core_out="$(sed -n '1,/^CREATE INDEX IF NOT EXISTS idx_import_facility_mapping_leaf_node_key/p' "$TABLES" | psql_db 2>&1)"; then
    echo "$core_out" >&2
    exit 1
fi
for m in "${CHAIN[@]}"; do
    echo "apply $m"
    psql_db < "$MIGRATIONS/$m.sql" >/dev/null
done

# ---------------------------------------------------------------------------
# Fixture. Month 2026-09: window 2026-07-03..2026-09-30; overdue cut-off 07-18.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B, 303 Fac C, 304 Fac D
#              > 210 Other District > 305 Fac E
# HTN tab (heart360_patients_category 2026-09; under care = total - new - LTFU):
#   Fac A   total 80 (+ Sub A1 20), controlled 70, uncontrolled 10, no visit 20 of 100
#           -> 70.0 / 10.0 / 20.0 / LTFU 0.0: no breach, control >= 60
#   Fac B   total 200, new 20, LTFU 50 -> 130 under care; controlled 52 (40.0), uncontrolled 39 (30.0),
#           no visit 39 (30.0), LTFU 25.0 -> all four lines breached
#   Fac C   total 125, LTFU 25 -> 100 under care; controlled 50, uncontrolled 20, no visit 25,
#           LTFU 20.0 -> every value on its line, no breach
#   Fac D   total 100: controlled 65, uncontrolled 35 -> uncontrolled_above_pct only, control >= 60
#   Fac E   (other district) total 100: controlled 10, uncontrolled 90
# BP readings: Fac A 137 x30 and 142 x5 on 09-01 -> fudging flag -> Fac A also_check.
# Overdue with a phone (last visit 06-01, 10 digits): Fac B 1, Fac C 86, Fac D 5; Fac C also has
#   3 overdue without a usable phone. District 92.
# Drug stock 2026-09 (cohort Fac A, B, C; CCB coeff 1.4, ARB 0.37, load 1.0; registered N A 100,
#   B 200, C 10):
#   Fac A  Amlodipine 5 mg 1400, 10 mg 0              -> CCB 1400 / (100 x 1.4) = 10.0, low
#          Telmisartan 40 mg 3700 x dose factor, 80 mg 0 -> ARB 100.0 x dose factor 40 mg, not low
#          Diuretic not reported                       -> NULL, not low
#   Fac B  Amlodipine 5 mg 2800, 10 mg 1400 (factor 2) -> CCB 5600 / (200 x 1.4) = 20.0, low
#   Fac C  Amlodipine 5 mg 1400, 10 mg 0              -> CCB 1400 / (10 x 1.4) = 100.0, not low
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100), (210, 'Other District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200), (304, 'Fac D', 3, 200),
    (305, 'Fac E', 3, 210),
    (401, 'Sub A1', 4, 301);

INSERT INTO heart360tk_reporting.heart360_patients_category
    (ref_month, org_unit_id, total_number_of_patients, nb_patients_newly_registered,
     nb_patients_lost_to_follow_up, nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit)
VALUES
    ('2026-09-01', 301,  80,  0,  0, 56,  8, 16), ('2026-09-01', 401, 20, 0, 0, 14, 2, 4),
    ('2026-09-01', 302, 200, 20, 50, 52, 39, 39),
    ('2026-09-01', 303, 125,  0, 25, 50, 20, 25),
    ('2026-09-01', 304, 100,  0,  0, 65, 35,  0),
    ('2026-09-01', 305, 100,  0,  0, 10, 90,  0);

-- Fac A readings (encounters 09-01: not overdue)
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT i, 'Fixture ' || i, 'ALIVE', '2026-01-01', '1960-01-01', 301 FROM generate_series(1, 35) i;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT i, i, '2026-09-01 10:00', 301 FROM generate_series(1, 35) i;
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
SELECT i, CASE WHEN i <= 30 THEN 137 ELSE 142 END, 85 FROM generate_series(1, 35) i;

-- Overdue: Fac B 1, Fac C 86 (+3 without a usable phone), Fac D 5
CREATE TEMP TABLE od (pid BIGINT, org INT, phone TEXT);
INSERT INTO od VALUES (1001, 302, '0812000001');
INSERT INTO od SELECT 2000 + i, 303, '0813' || lpad(i::text, 6, '0') FROM generate_series(1, 86) i;
INSERT INTO od VALUES (2087, 303, NULL), (2088, 303, '081-2345'), (2089, 303, '');
INSERT INTO od SELECT 3000 + i, 304, '0814' || lpad(i::text, 6, '0') FROM generate_series(1, 5) i;
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, phone_number, org_unit_id)
SELECT pid, 'Fixture ' || pid, 'ALIVE', '2026-01-01', '1960-01-01', phone, org FROM od;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT pid, pid, '2026-06-01 09:00', org FROM od;
-- the newest encounter in the database
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
VALUES (9001, 'Fixture 9001', 'ALIVE', '2026-01-01', '1960-01-01', 305);
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES (9001, 9001, '2026-10-31 10:00', 305);

-- Drug stock
INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (301), (302), (303);
INSERT INTO heart360tk_reporting.heart360_patients_registered (ref_month, org_unit_id, cumulative_number_of_patients)
VALUES ('2026-09-01', 301, 80), ('2026-09-01', 401, 20), ('2026-09-01', 302, 200), ('2026-09-01', 303, 10);
SELECT * FROM drug_stock_pull_apply('[
  {"org_unit_id":"301","reporting_month":"2026-09","drug_code":"329528","in_stock":"1400"},
  {"org_unit_id":"301","reporting_month":"2026-09","drug_code":"329526","in_stock":"0"},
  {"org_unit_id":"301","reporting_month":"2026-09","drug_code":"316764","in_stock":"3700"},
  {"org_unit_id":"301","reporting_month":"2026-09","drug_code":"316765","in_stock":"0"},
  {"org_unit_id":"302","reporting_month":"2026-09","drug_code":"329528","in_stock":"2800"},
  {"org_unit_id":"302","reporting_month":"2026-09","drug_code":"329526","in_stock":"1400"},
  {"org_unit_id":"303","reporting_month":"2026-09","drug_code":"329528","in_stock":"1400"},
  {"org_unit_id":"303","reporting_month":"2026-09","drug_code":"329526","in_stock":"0"}
]'::jsonb);
SQL
echo "fixture loaded"

psql_db -tA <<'SQL' | grep -qx '1|2|1.4|1.0' || { echo "FAIL fixture assumption: Amlodipine dose factors 1 and 2, CCB coeff 1.4, load 1.0" >&2; exit 1; }
SELECT string_agg(p.dose_factor::text, '|' ORDER BY p.rxnorm_code DESC) || '|' || c.category_coeff || '|' || c.load_factor
FROM heart360tk_schema.protocol_drugs p
JOIN heart360tk_schema.coeff_config c ON c.drug_category = p.drug_category AND c.country_code = p.country_code
WHERE p.rxnorm_code IN ('329528', '329526') AND p.country_code = 'India'
GROUP BY c.category_coeff, c.load_factor;
SQL

run_checks() {
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_diff TEXT;
    v_got  TEXT;
    v_arb  NUMERIC;
BEGIN
    -- -----------------------------------------------------------------------
    -- chat_control_summary = h360_control_summary = control_pct of report_fudging / report_titration
    -- -----------------------------------------------------------------------
    SELECT string_agg(format('%s/%s', m, c.org_unit_id), ', ') INTO v_diff
    FROM unnest(ARRAY[0, 200, 301, 401, 302, 210, 999]) m
    CROSS JOIN LATERAL chat_control_summary('2026-09-01', NULLIF(m, 0)) c
    CROSS JOIN LATERAL h360_control_summary('2026-09-01', c.org_unit_id) h
    WHERE (c.under_care_n, c.controlled_n, c.controlled_pct, c.uncontrolled_n, c.uncontrolled_pct,
           c.missed_visit_pct, c.ltfu_pct, c.too_few)
          IS DISTINCT FROM
          (h.under_care_n, h.controlled_n, h.controlled_pct, h.uncontrolled_n, h.uncontrolled_pct,
           h.missed_visit_pct, h.ltfu_pct, h.under_care_n = 0);
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION 'chat_control_summary differs from h360_control_summary at %', v_diff;
    END IF;

    SELECT string_agg(format('%s/%s', m, d.org_unit_id), ', ') INTO v_diff
    FROM unnest(ARRAY[0, 200, 301, 401, 302]) m
    CROSS JOIN LATERAL (
        (SELECT c.org_unit_id, c.controlled_pct FROM chat_control_summary('2026-09-01', m) c
         EXCEPT ALL SELECT f.org_unit_id, f.control_pct FROM report_fudging('2026-09-01', m) f)
        UNION ALL
        (SELECT f.org_unit_id, f.control_pct FROM report_fudging('2026-09-01', m) f
         EXCEPT ALL SELECT c.org_unit_id, c.controlled_pct FROM chat_control_summary('2026-09-01', m) c)
        UNION ALL
        (SELECT c.org_unit_id, c.controlled_pct FROM chat_control_summary('2026-09-01', m) c
         EXCEPT ALL SELECT t.org_unit_id, t.control_pct FROM report_titration('2026-09-01', m) t)
        UNION ALL
        (SELECT t.org_unit_id, t.control_pct FROM report_titration('2026-09-01', m) t
         EXCEPT ALL SELECT c.org_unit_id, c.controlled_pct FROM chat_control_summary('2026-09-01', m) c)
    ) d;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION 'chat_control_summary rows or controlled_pct differ from report_fudging/report_titration at %', v_diff;
    END IF;

    SELECT string_agg(concat_ws(':', org_unit_id, org_unit_name, level, is_selected, too_few, under_care_n,
                                controlled_n, controlled_pct, uncontrolled_n, uncontrolled_pct,
                                missed_visit_pct, ltfu_pct), ' | ')
    INTO v_got FROM chat_control_summary('2026-09-01', 200);
    IF v_got IS DISTINCT FROM
       '200:Fixture District:2:t:f:430:237:55.1:104:24.2:19.5:14.3'
       || ' | 301:Fac A:3:f:f:100:70:70.0:10:10.0:20.0:0.0'
       || ' | 302:Fac B:3:f:f:130:52:40.0:39:30.0:30.0:25.0'
       || ' | 303:Fac C:3:f:f:100:50:50.0:20:20.0:25.0:20.0'
       || ' | 304:Fac D:3:f:f:100:65:65.0:35:35.0:0.0:0.0' THEN
        RAISE EXCEPTION 'chat_control_summary(200) differs: %', v_got;
    END IF;
    IF (SELECT string_agg(org_unit_id || ':' || is_selected || ':' || too_few || ':' || under_care_n, ',')
        FROM chat_control_summary('2026-08-01', 301)) IS DISTINCT FROM '301:true:true:0' THEN
        RAISE EXCEPTION 'chat_control_summary with no data is not too_few with 0 under care';
    END IF;
    IF EXISTS (SELECT 1 FROM chat_control_summary('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'chat_control_summary: unknown org unit gave rows';
    END IF;

    -- -----------------------------------------------------------------------
    -- chat_drug_stock_gate
    -- -----------------------------------------------------------------------
    SELECT patient_days INTO v_arb FROM chat_drug_stock_gate('2026-09-01', 301) WHERE category = 'ARB';
    SELECT string_agg(concat_ws(':', g.org_unit_id, g.category, COALESCE(g.patient_days::text, 'NULL'), g.low), ' | ')
    INTO v_got FROM chat_drug_stock_gate('2026-09-01', 301) g;
    IF v_got IS DISTINCT FROM '301:CCB:10.0:t | 301:ARB:' || v_arb || ':f | 301:Diuretic:NULL:f'
       OR v_arb IS NULL OR v_arb < 30 THEN
        RAISE EXCEPTION 'chat_drug_stock_gate(301) differs: %', v_got;
    END IF;
    SELECT string_agg(concat_ws(':', g.org_unit_id, g.category, COALESCE(g.patient_days::text, 'NULL'), g.low), ' | ')
    INTO v_got FROM chat_drug_stock_gate('2026-09-01', 302) g;
    IF v_got IS DISTINCT FROM '302:CCB:20.0:t | 302:ARB:NULL:f | 302:Diuretic:NULL:f' THEN
        RAISE EXCEPTION 'chat_drug_stock_gate(302) differs: %', v_got;
    END IF;
    SELECT string_agg(concat_ws(':', g.org_unit_id, g.category, COALESCE(g.patient_days::text, 'NULL'), g.low), ' | ')
    INTO v_got FROM chat_drug_stock_gate('2026-09-01', 303) g;
    IF v_got IS DISTINCT FROM '303:CCB:100.0:f | 303:ARB:NULL:f | 303:Diuretic:NULL:f' THEN
        RAISE EXCEPTION 'chat_drug_stock_gate(303) differs: %', v_got;
    END IF;
    -- a sub-facility answers for its facility (AD-30 scope)
    IF (SELECT string_agg(org_unit_id || ':' || category || ':' || patient_days || ':' || low, ',')
        FROM chat_drug_stock_gate('2026-09-01', 401) WHERE category = 'CCB') IS DISTINCT FROM '301:CCB:10.0:true' THEN
        RAISE EXCEPTION 'chat_drug_stock_gate(401) does not answer for Fac A';
    END IF;
    -- district: sum over the facilities that reported (8400 / (310 x 1.4) = 19.4)
    IF (SELECT string_agg(org_unit_id || ':' || category || ':' || patient_days || ':' || low, ',')
        FROM chat_drug_stock_gate('2026-09-01', 200) WHERE category = 'CCB') IS DISTINCT FROM '200:CCB:19.4:true' THEN
        RAISE EXCEPTION 'chat_drug_stock_gate(200) CCB differs';
    END IF;
    IF (SELECT count(*) FROM chat_drug_stock_gate('2026-09-01', 0)) <> 3
       OR (SELECT count(*) FROM chat_drug_stock_gate('2026-09-01', NULL)) <> 3
       OR EXISTS (SELECT 1 FROM chat_drug_stock_gate('2026-10-01', 301))
       OR EXISTS (SELECT 1 FROM chat_drug_stock_gate('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'chat_drug_stock_gate scope, month or unknown-id rows are wrong';
    END IF;

    -- -----------------------------------------------------------------------
    -- chat_call_plan (EP-10)
    -- -----------------------------------------------------------------------
    SELECT string_agg(concat_ws(':', org_unit_id, overdue_with_phone_n, week_1, week_2, week_3, week_4), ',')
    INTO v_got FROM chat_call_plan('2026-09-01', 303);
    IF v_got IS DISTINCT FROM '303:86:22:22:22:20' THEN
        RAISE EXCEPTION 'chat_call_plan(303) for 86 is not 22, 22, 22, 20: %', v_got;
    END IF;
    SELECT string_agg(concat_ws(':', m, p.overdue_with_phone_n, p.week_1, p.week_2, p.week_3, p.week_4), ' | ' ORDER BY m)
    INTO v_got
    FROM unnest(ARRAY[0, 200, 301, 302, 304, 401]) m
    CROSS JOIN LATERAL chat_call_plan('2026-09-01', m) p;
    IF v_got IS DISTINCT FROM
       '0:92:23:23:23:23 | 200:92:23:23:23:23 | 301:0:0:0:0:0 | 302:1:1:0:0:0 | 304:5:2:2:1:0 | 401:0:0:0:0:0' THEN
        RAISE EXCEPTION 'chat_call_plan rows differ: %', v_got;
    END IF;
    -- every selection: one row, the weeks sum to report_calling.overdue_with_phone_n, none above calls_per_week
    SELECT string_agg(m::text, ', ') INTO v_diff
    FROM unnest(ARRAY[0, 100, 200, 210, 301, 302, 303, 304, 305, 401]) m
    CROSS JOIN LATERAL (SELECT * FROM report_calling('2026-09-01', m) WHERE is_selected) r
    LEFT JOIN LATERAL chat_call_plan('2026-09-01', m) p ON TRUE
    WHERE p.org_unit_id IS DISTINCT FROM r.org_unit_id
       OR p.overdue_with_phone_n IS DISTINCT FROM r.overdue_with_phone_n
       OR p.week_1 + p.week_2 + p.week_3 + p.week_4 IS DISTINCT FROM r.overdue_with_phone_n
       OR p.week_1 IS DISTINCT FROM r.calls_per_week AND r.overdue_with_phone_n > 0
       OR GREATEST(p.week_1, p.week_2, p.week_3, p.week_4) > r.calls_per_week
       OR (SELECT count(*) FROM chat_call_plan('2026-09-01', m)) <> 1;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION 'chat_call_plan does not match report_calling at %', v_diff;
    END IF;
    IF EXISTS (SELECT 1 FROM chat_call_plan('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'chat_call_plan: unknown org unit gave rows';
    END IF;

    -- -----------------------------------------------------------------------
    -- chat_facility_rank_district
    -- -----------------------------------------------------------------------
    SELECT string_agg(concat_ws(':', rank, org_unit_id, org_unit_name, uncontrolled_n, breaches::text, also_check), ' | ' ORDER BY rank)
    INTO v_got FROM chat_facility_rank_district('2026-09-01', 200);
    IF v_got IS DISTINCT FROM
       '1:302:Fac B:39:{control_below_pct,uncontrolled_above_pct,missed_visit_above_pct,ltfu_above_pct}:f'
       || ' | 2:304:Fac D:35:{uncontrolled_above_pct}:f'
       || ' | 3:303:Fac C:20:{}:f'
       || ' | 4:301:Fac A:10:{}:t' THEN
        RAISE EXCEPTION 'chat_facility_rank_district(200) differs: %', v_got;
    END IF;
    IF (SELECT string_agg(org_unit_id::text, ',' ORDER BY rank) FROM chat_facility_rank_district('2026-09-01', 0))
       IS DISTINCT FROM '305,302,304,303,301' THEN
        RAISE EXCEPTION 'chat_facility_rank_district(0) order differs';
    END IF;
    IF (SELECT string_agg(org_unit_id || ':' || rank || ':' || also_check, ',') FROM chat_facility_rank_district('2026-09-01', 301))
       IS DISTINCT FROM '301:1:true' THEN
        RAISE EXCEPTION 'chat_facility_rank_district(301) differs';
    END IF;
    IF EXISTS (SELECT 1 FROM chat_facility_rank_district('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'chat_facility_rank_district: unknown org unit gave rows';
    END IF;
END $$;
SQL
}
run_checks
echo "PASS chat_control_summary = h360_control_summary = report_fudging/report_titration control_pct (every row)"
echo "PASS chat_drug_stock_gate: Fac A CCB 10.0 low, Fac B CCB 20.0 low, Fac C 100.0 not low, unknown NULL not low"
echo "PASS chat_call_plan: 86 -> 22, 22, 22, 20; weeks sum to report_calling.overdue_with_phone_n"
echo "PASS chat_facility_rank_district: rank by uncontrolled_n, breaches on and over each line, also_check Fac A"

# ---------------------------------------------------------------------------
# also_check through a titration flag, and stub tolerance (rolled back)
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
BEGIN;
SET LOCAL ROLE heart360tk;
-- Fac D (65.0% controlled) flagged on titration; report_fudging cut to a stub
CREATE OR REPLACE FUNCTION report_titration(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, flag boolean,
               flag_reason text, uncontrolled_visits_n bigint, stepped_up_n bigint, titration_pct numeric,
               excluded_too_recent_n bigint, excluded_no_baseline_n bigint, control_pct numeric, looks_fine_check boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = heart360tk_schema, pg_temp SET jit = off AS $f$
    VALUES (304, 'Fac D'::text, 3, FALSE, FALSE, TRUE, 'tit D'::text, 0::bigint, 0::bigint, NULL::numeric, 0::bigint, 0::bigint, 65.0, TRUE),
           (302, 'Fac B'::text, 3, FALSE, FALSE, TRUE, 'tit B'::text, 0::bigint, 0::bigint, NULL::numeric, 0::bigint, 0::bigint, 40.0, FALSE);
$f$;
CREATE OR REPLACE FUNCTION report_fudging(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, flag boolean,
               flag_reason text, readings_n bigint, band_135_139_n bigint, band_140_144_n bigint, score numeric,
               control_pct numeric, looks_fine_check boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = heart360tk_schema, pg_temp SET jit = off AS $f$
    SELECT NULL::integer, NULL::text, NULL::integer, NULL::boolean, NULL::boolean, NULL::boolean, NULL::text,
           NULL::bigint, NULL::bigint, NULL::bigint, NULL::numeric, NULL::numeric, NULL::boolean
    WHERE FALSE;
$f$;
COMMENT ON FUNCTION report_fudging(date, integer) IS 'h360:stub';
DO $$
DECLARE
    v_got TEXT;
BEGIN
    SELECT string_agg(org_unit_id || ':' || also_check, ',' ORDER BY rank) INTO v_got
    FROM chat_facility_rank_district('2026-09-01', 200);
    -- Fac B is flagged but under 60% control: no also_check
    IF v_got IS DISTINCT FROM '302:false,304:true,303:false,301:false' THEN
        RAISE EXCEPTION 'also_check via titration / fudging stub differs: %', v_got;
    END IF;
END $$;
ROLLBACK;
SQL
echo "PASS also_check from a titration flag at >= 60% control (not under 60%); fudging stub tolerated"

# ---------------------------------------------------------------------------
# Thresholds come from report_flag_thresholds, not literals (rolled back)
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_got TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'heart360tk_schema' AND p.proname LIKE 'chat\_%'
          AND p.prosrc ~ '\m(20|25|30|50|60)(\.0+)?\M'
    ) THEN
        RAISE EXCEPTION 'a chat function holds a threshold literal (20, 25, 30, 50 or 60)';
    END IF;

    UPDATE report_flag_thresholds SET value = 10 WHERE report = 'chat' AND key = 'stock_days_below';
    IF (SELECT low FROM chat_drug_stock_gate('2026-09-01', 301) WHERE category = 'CCB') THEN
        RAISE EXCEPTION 'stock_days_below change not picked up (10.0 is not below 10)';
    END IF;
    UPDATE report_flag_thresholds SET value = 40.1 WHERE report = 'chattogram' AND key = 'control_below_pct';
    UPDATE report_flag_thresholds SET value = 35   WHERE report = 'chattogram' AND key = 'uncontrolled_above_pct';
    UPDATE report_flag_thresholds SET value = 19.9 WHERE report = 'chattogram' AND key = 'missed_visit_above_pct';
    UPDATE report_flag_thresholds SET value = 25   WHERE report = 'chattogram' AND key = 'ltfu_above_pct';
    UPDATE report_flag_thresholds SET value = 71   WHERE report = 'common'     AND key = 'high_control_pct';
    SELECT string_agg(org_unit_id || ':' || breaches::text || ':' || also_check, ' | ' ORDER BY rank) INTO v_got
    FROM chat_facility_rank_district('2026-09-01', 200);
    IF v_got IS DISTINCT FROM
       '302:{control_below_pct,missed_visit_above_pct}:false | 304:{}:false | 303:{missed_visit_above_pct}:false'
       || ' | 301:{missed_visit_above_pct}:false' THEN
        RAISE EXCEPTION 'chattogram threshold change not picked up: %', v_got;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(report || '.' || key || '=' || value, ',' ORDER BY report, key) FROM heart360tk_schema.report_flag_thresholds WHERE report IN ('chattogram', 'common') OR (report, key) = ('chat', 'stock_days_below')")" \
      != "chat.stock_days_below=30,chattogram.control_below_pct=50,chattogram.ltfu_above_pct=20,chattogram.missed_visit_above_pct=25,chattogram.uncontrolled_above_pct=20,common.high_control_pct=60" ]]; then
    echo "FAIL threshold probe was not rolled back" >&2
    exit 1
fi
echo "PASS thresholds read from report_flag_thresholds (chat.stock_days_below, chattogram.*, common.high_control_pct)"

# ---------------------------------------------------------------------------
# Privileges: chat_* to h360_api only
# ---------------------------------------------------------------------------
psql_db <<'SQL' >/dev/null
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema'
      AND p.proname IN ('chat_control_summary', 'chat_drug_stock_gate', 'chat_call_plan', 'chat_facility_rank_district')
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR obj_description(p.oid, 'pg_proc') = 'h360:stub'
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL
       OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'heart360tk_schema' AND p.proname LIKE 'chat\_%') <> 4 THEN
        RAISE EXCEPTION 'chat function contract broken for: %', v_bad;
    END IF;
    IF (SELECT string_agg(p.proname || '=' || pg_get_function_result(p.oid), E'\n' ORDER BY p.proname)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'heart360tk_schema' AND p.proname LIKE 'chat\_%') IS DISTINCT FROM
       'chat_call_plan=TABLE(org_unit_id integer, overdue_with_phone_n bigint, week_1 bigint, week_2 bigint, week_3 bigint, week_4 bigint)' || E'\n' ||
       'chat_control_summary=TABLE(org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, under_care_n bigint, controlled_n bigint, controlled_pct numeric, uncontrolled_n bigint, uncontrolled_pct numeric, missed_visit_pct numeric, ltfu_pct numeric)' || E'\n' ||
       'chat_drug_stock_gate=TABLE(org_unit_id integer, category text, patient_days numeric, low boolean)' || E'\n' ||
       'chat_facility_rank_district=TABLE(org_unit_id integer, org_unit_name text, uncontrolled_n bigint, breaches text[], also_check boolean, rank integer)' THEN
        RAISE EXCEPTION 'chat function columns changed';
    END IF;
END $$;

-- h360_api has no table privileges; the definer functions still answer.
SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT week_4 FROM heart360tk_schema.chat_call_plan('2026-09-01', 303)) <> 20
       OR (SELECT controlled_pct FROM heart360tk_schema.chat_control_summary('2026-09-01', 302)) <> 40.0
       OR NOT (SELECT low FROM heart360tk_schema.chat_drug_stock_gate('2026-09-01', 302) WHERE category = 'CCB')
       OR (SELECT org_unit_id FROM heart360tk_schema.chat_facility_rank_district('2026-09-01', 200) WHERE rank = 1) <> 302 THEN
        RAISE EXCEPTION 'h360_api got different chat answers';
    END IF;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
DO $$
DECLARE
    v_fn TEXT;
BEGIN
    FOREACH v_fn IN ARRAY ARRAY['chat_control_summary', 'chat_drug_stock_gate', 'chat_call_plan', 'chat_facility_rank_district'] LOOP
        BEGIN
            EXECUTE format('SELECT * FROM heart360tk_schema.%I(%L, 0)', v_fn, '2026-09-01');
            RAISE EXCEPTION 'heart360tk_reader executed %', v_fn;
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    END LOOP;
END $$;
RESET ROLE;
SQL
echo "PASS grants: chat_* definer, executable by h360_api only (not PUBLIC, heart360tk_reader or heart360tk_cached)"

# ---------------------------------------------------------------------------
# Idempotence: a second apply changes nothing
# ---------------------------------------------------------------------------
snapshot() {
    psql_db -tA <<'SQL'
SELECT md5(string_agg(x, E'\n' ORDER BY x)) FROM (
    SELECT p.oid::regprocedure::text || pg_get_functiondef(p.oid) || COALESCE(p.proacl::text, '')
           || COALESCE(obj_description(p.oid, 'pg_proc'), '') AS x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema'
      AND (p.proname LIKE 'report_%' OR p.proname LIKE 'chat_%' OR p.proname LIKE 'h360_%')
    UNION ALL SELECT row(r.*)::text FROM heart360tk_schema.chat_control_summary('2026-09-01', 0) r
    UNION ALL SELECT row(r.*)::text FROM heart360tk_schema.chat_drug_stock_gate('2026-09-01', 0) r
    UNION ALL SELECT row(r.*)::text FROM heart360tk_schema.chat_call_plan('2026-09-01', 0) r
    UNION ALL SELECT row(r.*)::text FROM heart360tk_schema.chat_facility_rank_district('2026-09-01', 0) r
    UNION ALL SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.13_to_0.6.14 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, comments, thresholds or results" >&2
    exit 1
fi
run_checks
echo "PASS second apply is idempotent; fixtures still pass"

echo "chat levers verified"
