#!/bin/bash
# Verifies 0.6.15_to_0.6.16 (story 7.9 group J: UX-03, UX-04, UX-05, UX-06, UX-11, UX-25) on a scratch
# database with hand-checked fixtures:
#   report_adherence_summary  HTN-tab control columns next to the CR-2 cohort columns (UX-03)
#   report_adherence_steps    the Excel step table: 13 rows, labels from the ladder, tool columns (UX-05)
#   report_titration_monthly  9 months, report rows + network average; each month equals report_titration
#   report_statins_monthly    9 months, report rows + network average; each month equals report_statins
#   report_fudging_quarterly  last 4 completed quarters (+ the quarter in progress), 130-139 / 140-149,
#                             bands green / yellow / flag / too_few (UX-25)
#   report_fudging_share      % of facilities at the flag ratio per quarter, n of N
#   report_calling(_return)   one return rule: patients called in the month, back within return_days (UX-11)
#   refresh_all_reporting_tables  DELETE, never TRUNCATE (UX-04)
# plus thresholds from report_flag_thresholds, grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   PSQL="docker exec -i postgres psql -U h360tk_root" ./verify_audit_reports.sh
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATIONS="$ROOT/pg_init_scripts/migrations"
# The 01_heart360_tables.sql chain without 0.6.5_to_0.6.6 (roles and grants; the roles are made below)
# and 0.6.14_to_0.6.15 (drug stock entry form, not used here).
CHAIN=(0.6.0_to_0.6.1 0.6.1_to_0.6.2 0.6.2_to_0.6.3 0.6.3_to_0.6.4 0.6.4_to_0.6.5 0.6.6_to_0.6.7
       0.6.7_to_0.6.8 0.6.8_to_0.6.9 0.6.9_to_0.6.10 0.6.10_to_0.6.11 0.6.11_to_0.6.12
       0.6.12_to_0.6.13 0.6.13_to_0.6.14 0.6.15_to_0.6.16)
MIGRATION="$MIGRATIONS/0.6.15_to_0.6.16.sql"
DB_NAME="${AUDIT_REPORTS_VERIFY_DB:-audit_reports_verify}"
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

if ! grep -q '\\ir migrations/0.6.15_to_0.6.16.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.15_to_0.6.16.sql" >&2
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
# Fixture. 100 Region > 200 District > 301 Fac A, 302 Fac B, 303 Fac C.
# Reporting month 2026-09: window 2026-07-03..2026-09-30; quarters Q4 2025..Q3 2026, none in progress.
# A filler encounter on 2026-10-20 is the newest visit in the database.
#
# Steps (Fac A, I10). First visit 2026-01-01 without a prescription; latest visit 09-01 with:
#   p1 Step 1 130/80, p2 Step 2 130/80, p3 Step 3 130/80, p4 Step 4 no BP, p5 Step 5, p6 Step 6,
#   p7 Other Protocol, p8 Non-Protocol, p9 unreadable (all 150/95), p11 Metformin only 130/80.
#   p10: latest visit 2026-01-15 Step 1 130/80 (before the window: patients, not cohort).
#   p12: first and only visit 09-01, no prescription, no BP (new: cohort only with include_new).
#   Patients 12; cohort 10, controlled 4 (p1, p2, p3, p11).
#   HTN tab (heart360_patients_category 2026-09, Fac A): total 50, new 5, LTFU 5, controlled 30 -> 75.0%.
#
# Fudging (one patient per reading; band 130-139 = a, 140-149 = b; 129.9 and 150 never count):
#   Fac B  Q4 2025 a 18 b 10 -> 1.80 yellow; Q1 2026 a 20 b 10 -> 2.00 flag; Q2 a 17 b 10 -> 1.70 green;
#          Q3 (09-30 23:00) a 12 b 5 -> too_few (17), ratio 2.40.
#   Fac C  Q1 (03-31 23:59) a 3 b 0 -> too_few, ratio NULL; Q2 a 30 b 10 -> 3.00 flag;
#          Q3 a 25 b 0 -> flag, ratio NULL.
#   Fac A  (from the steps patients) Q1 a 1 (p10), Q3 a 4 (p1-p3, p11) -> too_few.
#   District Q4 2025 18/10 1.80 yellow; Q1 24/10 2.40 flag; Q2 47/20 2.35 flag; Q3 41/5 8.20 flag.
#   Share (3 facilities): Q4 2025 0 of 1; Q1 1 of 1; Q2 1 of 2 (50.0); Q3 1 of 1.
#   Month 2026-10 adds Q4 2026 in progress (to 10-31): Fac B one reading 135 on 10-15.
#
# Calling (Fac C, 10-digit phones, month 2026-09, return_days 30, newest visit 10-20):
#   C1 last visit 07-10, called 09-02 (9 days, early) Agreed, visit 09-20 -> back.
#   C2 last visit 07-01, called 09-05 (late) Call again later, no visit; 10-05 <= 10-20 -> closed, not back.
#   C3 last visit 07-05, called 09-25 (late), removed (Moved out), visit 10-20 -> back (removed counts now).
#   C4 last visit 07-15, called 09-28 (late) Call again later, no visit; 10-28 > 10-20 -> open.
#   (Readings patients without a phone are also overdue at Fac C; only overdue with a phone is checked.)
#   called 4, back 2 = 50.0%; early back 1 of 1 = 100.0; later back 1 of 3 = 33.3; open 1; removed 1.
#
# Titration (Fac B): T2 06-20 Step 1 120/80, 07-20 Step 2 150/95 (stepped up at the same visit).
#   Jul and Aug: too recent (data_end 07-20); Sep: counted and stepped up -> 1 of 1.
#
# Statins (Fac A, E11, born 1960): S1 one visit 2026-05-15 with Atorvastatin. S2 visits 2025-12-01
#   (Metformin) and 2026-07-01 (Atorvastatin). Jan-Apr 0 of 1; May-Jun 1 of 2; Jul-Sep 2 of 2.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200);

CREATE TEMP TABLE rx (k TEXT PRIMARY KEY, obat TEXT);
INSERT INTO rx VALUES
    ('Step 1', 'Amlodipine 5 mg - 1 x 1 Tablet Sehari'),
    ('Step 2', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari'),
    ('Step 3', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari'),
    ('Step 4', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari'),
    ('Step 5', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Hydrochlorothiazide 12,5 mg - 1 x 1 Tablet Sehari'),
    ('Step 6', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Telmisartan 80 mg - 1 x 1 Tablet Sehari; Chlorthalidone 25 mg - 1 x 1 Tablet Sehari'),
    ('Other Protocol', 'Lisinopril 10 mg - 1 x 1 Tablet Sehari'),
    ('Non-Protocol', 'Losartan 50 mg - 1 x 1 Tablet Sehari'),
    ('Unrecognized', 'Obat herbal 2 x sehari'),
    ('Metformin', 'Metformin 500 mg - 2 x 1 Tablet Sehari'),
    ('Statin', 'Atorvastatin 20 mg - 1 x 1 Tablet Sehari');

-- Steps patients: (pid, first visit, latest visit, rx key or NULL, sys, dia)
CREATE TEMP TABLE plan (pid BIGINT, first_ts TIMESTAMP, visit_ts TIMESTAMP, k TEXT, sys NUMERIC, dia NUMERIC);
INSERT INTO plan VALUES
    (1,  '2026-01-01', '2026-09-01', 'Step 1', 130, 80),
    (2,  '2026-01-01', '2026-09-01', 'Step 2', 130, 80),
    (3,  '2026-01-01', '2026-09-01', 'Step 3', 130, 80),
    (4,  '2026-01-01', '2026-09-01', 'Step 4', NULL, NULL),
    (5,  '2026-01-01', '2026-09-01', 'Step 5', 150, 95),
    (6,  '2026-01-01', '2026-09-01', 'Step 6', 150, 95),
    (7,  '2026-01-01', '2026-09-01', 'Other Protocol', 150, 95),
    (8,  '2026-01-01', '2026-09-01', 'Non-Protocol', 150, 95),
    (9,  '2026-01-01', '2026-09-01', 'Unrecognized', 150, 95),
    (10, '2026-01-01', '2026-01-15', 'Step 1', 130, 80),
    (11, '2026-01-01', '2026-09-01', 'Metformin', 130, 80),
    (12, NULL,         '2026-09-01', NULL, NULL, NULL);

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Fixture ' || pid, 'ALIVE', COALESCE(first_ts, visit_ts), '1960-01-01', 301 FROM plan;
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) SELECT pid, 'I10' FROM plan;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT pid * 10 + 1, pid, first_ts, 301 FROM plan WHERE first_ts IS NOT NULL
UNION ALL
SELECT pid * 10 + 2, pid, visit_ts, 301 FROM plan;
INSERT INTO prescriptions (encounter_id, obat_raw, source)
SELECT p.pid * 10 + 2, rx.obat, 'fixture' FROM plan p JOIN rx USING (k);
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
SELECT pid * 10 + 2, sys, dia FROM plan WHERE sys IS NOT NULL;

INSERT INTO heart360tk_reporting.heart360_patients_category
    (ref_month, org_unit_id, total_number_of_patients, nb_patients_newly_registered,
     nb_patients_lost_to_follow_up, nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit)
VALUES ('2026-09-01', 301, 50, 5, 5, 30, 8, 2);

-- Fudging readings: one patient and one encounter each (ids from 10000)
CREATE TEMP TABLE rd (org INT, ts TIMESTAMP, sys NUMERIC, n INT);
INSERT INTO rd VALUES
    (302, '2025-11-10 10:00', 130,  10), (302, '2025-11-10 10:00', 139.9, 8),
    (302, '2025-11-10 10:00', 140,   9), (302, '2025-11-10 10:00', 149,   1),
    (302, '2025-11-10 10:00', 129.9, 3), (302, '2025-11-10 10:00', 150,   3),
    (302, '2026-02-10 10:00', 135,  20), (302, '2026-02-10 10:00', 145,  10),
    (302, '2026-05-10 10:00', 135,  17), (302, '2026-05-10 10:00', 145,  10),
    (302, '2026-09-30 23:00', 135,  12), (302, '2026-09-30 23:00', 145,   5),
    (302, '2026-10-15 10:00', 135,   1),
    (303, '2026-03-31 23:59', 135,   3),
    (303, '2026-05-10 10:00', 135,  30), (303, '2026-05-10 10:00', 145,  10),
    (303, '2026-08-10 10:00', 135,  25);
CREATE TEMP TABLE rdp AS
SELECT 10000 + row_number() OVER (ORDER BY org, ts, sys, g) AS pid, org, ts, sys
FROM rd CROSS JOIN LATERAL generate_series(1, rd.n) g;
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Reading ' || pid, 'ALIVE', ts, '1980-01-01', org FROM rdp;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) SELECT pid, pid, ts, org FROM rdp;
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp) SELECT pid, sys, 80 FROM rdp;

-- Calling (Fac C) and the filler visit (newest in the database)
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, phone_number, org_unit_id) VALUES
    (2001, 'C1', 'ALIVE', '2026-07-10', '1970-01-01', '0812000001', 303),
    (2002, 'C2', 'ALIVE', '2026-07-01', '1970-01-01', '0812000002', 303),
    (2003, 'C3', 'ALIVE', '2026-07-05', '1970-01-01', '0812000003', 303),
    (2004, 'C4', 'ALIVE', '2026-07-15', '1970-01-01', '0812000004', 303),
    (2009, 'Filler', 'ALIVE', '2026-10-20', '1970-01-01', NULL, 303);
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES
    (20011, 2001, '2026-07-10 09:00', 303), (20012, 2001, '2026-09-20 09:00', 303),
    (20021, 2002, '2026-07-01 09:00', 303),
    (20031, 2003, '2026-07-05 09:00', 303), (20032, 2003, '2026-10-20 08:00', 303),
    (20041, 2004, '2026-07-15 09:00', 303),
    (20091, 2009, '2026-10-20 09:00', 303);
INSERT INTO call_results (patient_id, call_date, result_type, removed_reason, org_unit_id) VALUES
    (2001, '2026-09-02', NULL, 'Agreed to visit', 303),
    (2002, '2026-09-05', NULL, 'Call again later', 303),
    (2003, '2026-09-25', 'removed_from_overdue_list', 'Moved out of catchment area', 303),
    (2004, '2026-09-28', NULL, 'Call again later', 303);

-- Titration T2 (Fac B)
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
VALUES (3002, 'T2', 'ALIVE', '2026-06-20', '1960-01-01', 302);
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES
    (30021, 3002, '2026-06-20 09:00', 302), (30022, 3002, '2026-07-20 09:00', 302);
INSERT INTO prescriptions (encounter_id, obat_raw, source) VALUES
    (30021, (SELECT obat FROM rx WHERE k = 'Step 1'), 'fixture'),
    (30022, (SELECT obat FROM rx WHERE k = 'Step 2'), 'fixture');
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp) VALUES (30021, 120, 80), (30022, 150, 95);

-- Statins S1, S2 (Fac A, E11)
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id) VALUES
    (4001, 'S1', 'ALIVE', '2026-05-15', '1960-01-01', 301),
    (4002, 'S2', 'ALIVE', '2025-12-01', '1960-01-01', 301);
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) VALUES (4001, 'E11'), (4002, 'E11');
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES
    (40011, 4001, '2026-05-15 09:00', 301),
    (40021, 4002, '2025-12-01 09:00', 301), (40022, 4002, '2026-07-01 09:00', 301);
INSERT INTO prescriptions (encounter_id, obat_raw, source) VALUES
    (40011, (SELECT obat FROM rx WHERE k = 'Statin'), 'fixture'),
    (40021, (SELECT obat FROM rx WHERE k = 'Metformin'), 'fixture'),
    (40022, (SELECT obat FROM rx WHERE k = 'Statin'), 'fixture');
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# UX-05 report_adherence_steps and UX-03 report_adherence
# ---------------------------------------------------------------------------
check_steps() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(concat_ws('|', row_order, row_key, label, patients_n, patients_pct, step_share_pct, cohort_n,
                                cohort_controlled_n, cohort_controlled_pct, controlled_share_pct, controlled_share_cum_pct),
                      E'\n' ORDER BY row_order) INTO v
    FROM (SELECT row_order, row_key, label, patients_n,
                 COALESCE(patients_pct::text, '-') AS patients_pct, COALESCE(step_share_pct::text, '-') AS step_share_pct,
                 cohort_n, cohort_controlled_n, COALESCE(cohort_controlled_pct::text, '-') AS cohort_controlled_pct,
                 COALESCE(controlled_share_pct::text, '-') AS controlled_share_pct,
                 COALESCE(controlled_share_cum_pct::text, '-') AS controlled_share_cum_pct
          FROM report_adherence_steps('2026-09-01', 301)) s;
    IF v IS DISTINCT FROM concat_ws(E'\n',
        '1|protocol_total|Protocol medicines|8|66.7|-|7|3|42.9|-|-',
        '2|steps_total|On a protocol step|7|58.3|100.0|6|3|50.0|-|-',
        '3|step_1|Step 1 · Amlodipine 5 mg|2|16.7|28.6|1|1|100.0|33.3|33.3',
        '4|step_2|Step 2 · Amlodipine 10 mg|1|8.3|14.3|1|1|100.0|33.3|66.7',
        '5|step_3|Step 3 · Amlodipine 10 mg + Lisinopril or Telmisartan (standard dose)|1|8.3|14.3|1|1|100.0|33.3|100.0',
        '6|step_4|Step 4 · Amlodipine 10 mg + Lisinopril or Telmisartan (full dose)|1|8.3|14.3|1|0|0.0|0.0|100.0',
        '7|step_5|Step 5 · Step 4 + Hydrochlorothiazide or Chlorthalidone 12.5 mg|1|8.3|14.3|1|0|0.0|0.0|100.0',
        '8|step_6|Step 6 · Step 4 + Hydrochlorothiazide or Chlorthalidone 25 mg|1|8.3|14.3|1|0|0.0|0.0|100.0',
        '9|other_protocol|Other mix of protocol medicines|1|8.3|-|1|0|0.0|-|-',
        '10|non_protocol|Medicine outside the protocol|1|8.3|-|1|0|0.0|-|-',
        '11|no_htn_medicine|No BP medicine at last visit|2|16.7|-|1|1|100.0|-|-',
        '12|unreadable|Could not read the entry|1|8.3|-|1|0|0.0|-|-',
        '13|grand_total|All patients|12|100.0|-|10|4|40.0|-|-') THEN
        RAISE EXCEPTION E'report_adherence_steps(301) =\n%', v;
    END IF;

    -- include_new: p12 (no prescription, no BP) joins the cohort
    SELECT string_agg(row_key || ':' || patients_n || '/' || cohort_n || '/' || cohort_controlled_n, ' ' ORDER BY row_order) INTO v
    FROM report_adherence_steps('2026-09-01', 301, true) WHERE row_key IN ('no_htn_medicine', 'grand_total');
    IF v IS DISTINCT FROM 'no_htn_medicine:2/2/1 grand_total:12/11/4' THEN
        RAISE EXCEPTION 'report_adherence_steps(301, true) = %', v;
    END IF;

    -- cohort columns equal report_adherence_buckets and report_adherence for every selection and mode
    IF EXISTS (
        SELECT 1
        FROM (VALUES (0, false), (0, true), (200, false), (200, true), (301, false), (301, true), (302, false)) s(org, inc)
        WHERE (SELECT string_agg(b.patients_n || '/' || b.controlled_n, ' ' ORDER BY b.bucket_order)
               FROM report_adherence_buckets('2026-09-01', s.org, s.inc) b)
              IS DISTINCT FROM
              (SELECT string_agg(x.c || '/' || x.t, ' ' ORDER BY x.o)
               FROM (SELECT CASE WHEN st.step_no IS NOT NULL THEN st.step_no
                                 WHEN st.row_key = 'other_protocol' THEN 7 WHEN st.row_key = 'non_protocol' THEN 8
                                 ELSE 9 END AS o,
                            sum(st.cohort_n) AS c, sum(st.cohort_controlled_n) AS t
                     FROM report_adherence_steps('2026-09-01', s.org, s.inc) st
                     WHERE st.step_no IS NOT NULL
                        OR st.row_key IN ('other_protocol', 'non_protocol', 'no_htn_medicine', 'unreadable')
                     GROUP BY 1) x)
           OR (SELECT cohort_n FROM report_adherence_steps('2026-09-01', s.org, s.inc) WHERE row_key = 'grand_total')
              IS DISTINCT FROM (SELECT cohort_n FROM report_adherence('2026-09-01', s.org, s.inc) WHERE is_selected)
           OR (SELECT count(*) FROM report_adherence_steps('2026-09-01', s.org, s.inc)) <> 13
    ) THEN
        RAISE EXCEPTION 'report_adherence_steps cohort columns differ from report_adherence_buckets / report_adherence';
    END IF;
    IF EXISTS (SELECT 1 FROM report_adherence_steps('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'unknown org unit gave step rows';
    END IF;

    -- UX-03: HTN-tab control next to the CR-2 cohort measure
    SELECT concat_ws('|', cohort_n, cohort_controlled_n, cohort_controlled_pct, off_protocol_n, off_protocol_pct,
                     one_medicine_n, one_medicine_pct, step_3_plus_n, step_3_plus_pct, under_care_n, controlled_n,
                     control_pct, too_few, flag) INTO v
    FROM report_adherence_summary('2026-09-01', 301) WHERE is_selected;
    IF v IS DISTINCT FROM '10|4|40.0|2|20.0|2|20.0|4|40.0|40|30|75.0|t|f' THEN
        RAISE EXCEPTION 'report_adherence_summary(301) = %', v;
    END IF;
    -- same rows, flags and cohort numbers as report_adherence, for every selection and mode
    IF EXISTS (
        SELECT 1
        FROM (VALUES (0, false), (0, true), (200, false), (301, false), (301, true), (302, false), (999, false)) s(org, inc)
        WHERE (SELECT string_agg(concat_ws('|', org_unit_id, too_few, flag, flag_reason, cohort_n, cohort_controlled_n,
                                           cohort_controlled_pct, off_protocol_pct, one_medicine_pct), ' ')
               FROM report_adherence_summary('2026-09-01', s.org, s.inc))
              IS DISTINCT FROM
              (SELECT string_agg(concat_ws('|', org_unit_id, too_few, flag, flag_reason, cohort_n, controlled_n,
                                           controlled_pct, off_protocol_pct, one_medicine_pct), ' ')
               FROM report_adherence('2026-09-01', s.org, s.inc))
    ) THEN
        RAISE EXCEPTION 'report_adherence_summary differs from report_adherence';
    END IF;
    IF (SELECT concat_ws('|', under_care_n, controlled_n, control_pct) FROM report_adherence_summary('2026-09-01', 301) WHERE is_selected)
       IS DISTINCT FROM (SELECT concat_ws('|', under_care_n, controlled_n, controlled_pct) FROM h360_control_summary('2026-09-01', 301)) THEN
        RAISE EXCEPTION 'report_adherence_summary control differs from h360_control_summary';
    END IF;
END $$;
SQL
}
check_steps
echo "PASS report_adherence_steps: 13 rows, ladder labels, tool columns; cohort equals buckets; report_adherence_summary control = HTN tab"

# ---------------------------------------------------------------------------
# UX-25 report_fudging_quarterly and report_fudging_share
# ---------------------------------------------------------------------------
check_fudging() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(concat_ws('|', org_unit_id, quarter_label, quarter_start, quarter_end, is_complete,
                                n_130_139, n_140_149, COALESCE(ratio::text, '-'), band, too_few, flag),
                      E'\n' ORDER BY ord) INTO v
    FROM (SELECT row_number() OVER () AS ord, q.* FROM report_fudging_quarterly('2026-09-01', 200) q) s;
    IF v IS DISTINCT FROM concat_ws(E'\n',
        '200|Q4 2025|2025-10-01|2025-12-31|t|18|10|1.80|yellow|f|f',
        '200|Q1 2026|2026-01-01|2026-03-31|t|24|10|2.40|flag|f|t',
        '200|Q2 2026|2026-04-01|2026-06-30|t|47|20|2.35|flag|f|t',
        '200|Q3 2026|2026-07-01|2026-09-30|t|41|5|8.20|flag|f|t',
        '301|Q4 2025|2025-10-01|2025-12-31|t|0|0|-|too_few|t|f',
        '301|Q1 2026|2026-01-01|2026-03-31|t|1|0|-|too_few|t|f',
        '301|Q2 2026|2026-04-01|2026-06-30|t|0|0|-|too_few|t|f',
        '301|Q3 2026|2026-07-01|2026-09-30|t|4|0|-|too_few|t|f',
        '302|Q4 2025|2025-10-01|2025-12-31|t|18|10|1.80|yellow|f|f',
        '302|Q1 2026|2026-01-01|2026-03-31|t|20|10|2.00|flag|f|t',
        '302|Q2 2026|2026-04-01|2026-06-30|t|17|10|1.70|green|f|f',
        '302|Q3 2026|2026-07-01|2026-09-30|t|12|5|2.40|too_few|t|f',
        '303|Q4 2025|2025-10-01|2025-12-31|t|0|0|-|too_few|t|f',
        '303|Q1 2026|2026-01-01|2026-03-31|t|3|0|-|too_few|t|f',
        '303|Q2 2026|2026-04-01|2026-06-30|t|30|10|3.00|flag|f|t',
        '303|Q3 2026|2026-07-01|2026-09-30|t|25|0|-|flag|f|t') THEN
        RAISE EXCEPTION E'report_fudging_quarterly(200) =\n%', v;
    END IF;

    SELECT string_agg(concat_ws('|', quarter_label, is_complete, facilities_n, checked_n, flagged_n,
                                COALESCE(flagged_pct::text, '-')), ' ; ' ORDER BY quarter_start) INTO v
    FROM report_fudging_share('2026-09-01', 200);
    IF v IS DISTINCT FROM 'Q4 2025|t|3|1|0|0.0 ; Q1 2026|t|3|1|1|100.0 ; Q2 2026|t|3|2|1|50.0 ; Q3 2026|t|3|1|1|100.0' THEN
        RAISE EXCEPTION 'report_fudging_share(200) = %', v;
    END IF;
    -- all places equals the district here; a facility selection is one facility
    IF (SELECT string_agg(flagged_n || '/' || checked_n, ' ' ORDER BY quarter_start) FROM report_fudging_share('2026-09-01', NULL))
       IS DISTINCT FROM '0/1 1/1 1/2 1/1'
       OR (SELECT string_agg(flagged_n || '/' || checked_n || '/' || facilities_n, ' ' ORDER BY quarter_start)
           FROM report_fudging_share('2026-09-01', 302)) IS DISTINCT FROM '0/1/1 1/1/1 0/1/1 0/0/1' THEN
        RAISE EXCEPTION 'report_fudging_share at all places / Fac B is wrong';
    END IF;

    -- 2026-10: four completed quarters ending Q3 2026, then Q4 2026 in progress to 10-31
    SELECT string_agg(concat_ws('|', quarter_label, is_complete, quarter_end, n_130_139, n_140_149, band), ' ; ' ORDER BY quarter_start) INTO v
    FROM report_fudging_quarterly('2026-10-01', 302);
    IF v IS DISTINCT FROM 'Q4 2025|t|2025-12-31|18|10|yellow ; Q1 2026|t|2026-03-31|20|10|flag ; Q2 2026|t|2026-06-30|17|10|green ; Q3 2026|t|2026-09-30|12|5|too_few ; Q4 2026|f|2026-10-31|1|0|too_few' THEN
        RAISE EXCEPTION 'report_fudging_quarterly(2026-10, 302) = %', v;
    END IF;
    IF EXISTS (SELECT 1 FROM report_fudging_quarterly('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'unknown org unit gave quarterly rows';
    END IF;
END $$;
SQL
}
check_fudging
echo "PASS report_fudging_quarterly: 4 completed quarters (+ in progress), 130-139/140-149, bands at 1.8 and 2.0, too_few; report_fudging_share n of N"

# ---------------------------------------------------------------------------
# UX-11 report_calling: one return rule
# ---------------------------------------------------------------------------
check_calling() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT concat_ws('|', overdue_with_phone_n, called_n, early_n, removed_n,
                     return_known_n, returned_n, returned_pct, returned_early_pct, returned_later_pct,
                     return_not_yet_known_n, too_few) INTO v
    FROM report_calling('2026-09-01', 303) WHERE is_selected;
    IF v IS DISTINCT FROM '4|4|1|1|4|2|50.0|100.0|33.3|1|t' THEN
        RAISE EXCEPTION 'report_calling(303) = %', v;
    END IF;
    SELECT concat_ws('|', called_month_n, returned_month_n, returned_month_pct, return_open_n,
                     returned_early_pct, returned_later_pct, too_few) INTO v
    FROM report_calling_return('2026-09-01', 303) WHERE is_selected;
    IF v IS DISTINCT FROM '4|2|50.0|1|100.0|33.3|t' THEN
        RAISE EXCEPTION 'report_calling_return(303) = %', v;
    END IF;
    IF (SELECT concat_ws('|', called_month_n, returned_month_n, return_open_n) FROM report_calling_return('2026-09-01', 200) WHERE is_selected)
       IS DISTINCT FROM '4|2|1'
       OR (SELECT count(*) FROM report_calling_return('2026-09-01', 200)) <> 4 THEN
        RAISE EXCEPTION 'report_calling_return(200) is wrong';
    END IF;
END $$;
SQL
}
check_calling
echo "PASS report_calling / report_calling_return: called in the month 4, back within 30 days 2 (50.0%), open 1"

# ---------------------------------------------------------------------------
# UX-06 monthly series
# ---------------------------------------------------------------------------
check_monthly() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(to_char(month_date, 'MM') || ':' || follow_up_n || '/' || titrated_n || '/' || COALESCE(rate_pct::text, '-')
                      || '/' || average_follow_up_n || '/' || average_titrated_n, ' ' ORDER BY month_date) INTO v
    FROM report_titration_monthly('2026-09-01', 200) WHERE org_unit_id = 302;
    IF v IS DISTINCT FROM '01:0/0/-/0/0 02:0/0/-/0/0 03:0/0/-/0/0 04:0/0/-/0/0 05:0/0/-/0/0 06:0/0/-/0/0 07:0/0/-/0/0 08:0/0/-/0/0 09:1/1/100.0/1/1' THEN
        RAISE EXCEPTION 'report_titration_monthly Fac B = %', v;
    END IF;

    SELECT string_agg(to_char(month_date, 'MM') || ':' || eligible_n || '/' || on_statin_n || '/' || COALESCE(rate_pct::text, '-')
                      || '/' || average_rate_pct || '/' || too_few, ' ' ORDER BY month_date) INTO v
    FROM report_statins_monthly('2026-09-01', 301);
    IF v IS DISTINCT FROM '01:1/0/0.0/0.0/true 02:1/0/0.0/0.0/true 03:1/0/0.0/0.0/true 04:1/0/0.0/0.0/true 05:2/1/50.0/50.0/true 06:2/1/50.0/50.0/true 07:2/2/100.0/100.0/true 08:2/2/100.0/100.0/true 09:2/2/100.0/100.0/true' THEN
        RAISE EXCEPTION 'report_statins_monthly Fac A = %', v;
    END IF;

    -- every month and report row equals that month's report; the average equals the all-places row
    IF EXISTS (
        SELECT 1
        FROM (VALUES (0), (200), (301), (302), (303)) s(org)
        CROSS JOIN LATERAL report_titration_monthly('2026-09-01', s.org) m
        LEFT JOIN LATERAL report_titration(m.month_date, s.org) r ON r.org_unit_id = m.org_unit_id
        LEFT JOIN LATERAL report_titration(m.month_date, NULL) a ON a.is_selected
        WHERE (m.follow_up_n, m.titrated_n, m.rate_pct, m.too_few, m.average_follow_up_n, m.average_titrated_n)
              IS DISTINCT FROM (r.uncontrolled_visits_n, r.stepped_up_n, r.titration_pct, r.too_few,
                                a.uncontrolled_visits_n, a.stepped_up_n)
    ) OR EXISTS (
        SELECT 1
        FROM (VALUES (0), (200), (301), (302), (303)) s(org)
        CROSS JOIN LATERAL report_statins_monthly('2026-09-01', s.org) m
        LEFT JOIN LATERAL report_statins(m.month_date, s.org) r ON r.org_unit_id = m.org_unit_id
        LEFT JOIN LATERAL report_statins(m.month_date, NULL) a ON a.is_selected
        WHERE (m.eligible_n, m.on_statin_n, m.rate_pct, m.too_few, m.average_eligible_n, m.average_on_statin_n)
              IS DISTINCT FROM (r.eligible_n, r.on_statin_n, r.on_statin_pct, r.too_few, a.eligible_n, a.on_statin_n)
    ) THEN
        RAISE EXCEPTION 'a monthly row differs from that month''s report_titration / report_statins';
    END IF;
    IF (SELECT count(*) FROM report_titration_monthly('2026-09-01', 200)) <> 36
       OR (SELECT count(DISTINCT month_date) FROM report_statins_monthly('2026-09-01', 0)) <> 9
       OR EXISTS (SELECT 1 FROM report_statins_monthly('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'monthly row counts are wrong';
    END IF;
END $$;
SQL
}
check_monthly
echo "PASS report_titration_monthly / report_statins_monthly: 9 months, each equal to that month's report, network average"

# ---------------------------------------------------------------------------
# UX-04, thresholds and literals
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'heart360tk_reporting.refresh_all_reporting_tables()'::regprocedure) ~* 'truncate\s+table'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'heart360tk_reporting.refresh_all_reporting_tables()'::regprocedure) !~* 'DELETE FROM heart360tk_reporting' THEN
        RAISE EXCEPTION 'refresh_all_reporting_tables still truncates';
    END IF;

    IF (SELECT string_agg(key || '=' || value, ',' ORDER BY key) FROM report_flag_thresholds
        WHERE report = 'fudging' AND key IN ('warn_ratio', 'flag_ratio')) IS DISTINCT FROM 'flag_ratio=2.0,warn_ratio=1.8' THEN
        RAISE EXCEPTION 'fudging warn_ratio / flag_ratio rows are missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'heart360tk_schema'
          AND p.proname IN ('report_fudging_quarterly', 'report_fudging_share', 'report_titration_monthly',
                            'report_statins_monthly', 'report_calling', 'report_adherence_summary')
          AND p.prosrc ~ '\m(1\.8|2\.0|20|25|10|14|30|40|45|60)\M'
    ) THEN
        RAISE EXCEPTION 'a new report function holds a threshold literal';
    END IF;

    -- a changed row changes the band: warn 1.81 turns Fac B Q4 2025 (1.80) green
    UPDATE report_flag_thresholds SET value = 1.81 WHERE report = 'fudging' AND key = 'warn_ratio';
    SELECT band INTO v FROM report_fudging_quarterly('2026-09-01', 302) WHERE quarter_label = 'Q4 2025';
    IF v IS DISTINCT FROM 'green' THEN
        RAISE EXCEPTION 'warn_ratio change not picked up: %', v;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
echo "PASS refresh uses DELETE; fudging warn_ratio 1.8 / flag_ratio 2.0 rows; no threshold literals; a changed row changes the band"

# ---------------------------------------------------------------------------
# Privileges, and calls as the roles themselves
# ---------------------------------------------------------------------------
psql_db <<'SQL' >/dev/null
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema'
      AND p.proname IN ('report_adherence_summary', 'report_adherence_steps', 'report_titration_monthly', 'report_statins_monthly',
                        'report_fudging_quarterly', 'report_fudging_share', 'report_calling', 'report_calling_return')
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname IN ('report_adherence_summary', 'report_adherence_steps',
            'report_titration_monthly', 'report_statins_monthly', 'report_fudging_quarterly', 'report_fudging_share',
            'report_calling', 'report_calling_return')) <> 8 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;
    IF has_function_privilege('heart360tk_reader', 'heart360tk_schema.h360_ladder_step_labels()', 'EXECUTE')
       OR has_function_privilege('h360_api', 'heart360tk_schema.h360_ladder_step_labels()', 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'heart360tk_schema.h360_ladder_step_labels()'::regprocedure) THEN
        RAISE EXCEPTION 'h360_ladder_step_labels is executable outside heart360tk';
    END IF;
END $$;

SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT count(*) FROM heart360tk_schema.report_adherence_steps('2026-09-01', 301)) <> 13
       OR (SELECT count(*) FROM heart360tk_schema.report_fudging_share('2026-09-01', 200)) <> 4
       OR (SELECT called_month_n FROM heart360tk_schema.report_calling_return('2026-09-01', 303) WHERE is_selected) <> 4 THEN
        RAISE EXCEPTION 'h360_api got different rows';
    END IF;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_titration_monthly('2026-09-01', 302);
SELECT 1 FROM heart360tk_schema.report_statins_monthly('2026-09-01', 301);
SELECT 1 FROM heart360tk_schema.report_fudging_quarterly('2026-09-01', 0);
SELECT 1 FROM heart360tk_schema.report_adherence_summary('2026-09-01', 0, true);
SELECT 1 FROM heart360tk_schema.report_flags('2026-09-01', 0);
RESET ROLE;
SQL
echo "PASS grants: new and recreated report functions definer, executable by heart360tk_reader and h360_api only"

# ---------------------------------------------------------------------------
# Idempotence: a second apply changes nothing
# ---------------------------------------------------------------------------
snapshot() {
    psql_db -tA <<'SQL'
SELECT md5(string_agg(x, E'\n' ORDER BY x)) FROM (
    SELECT p.oid::regprocedure::text || pg_get_functiondef(p.oid) || COALESCE(p.proacl::text, '') AS x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('heart360tk_schema', 'heart360tk_reporting')
      AND (p.proname LIKE 'report_%' OR p.proname LIKE 'h360_%' OR p.proname LIKE 'refresh_%')
    UNION ALL
    SELECT row(r.*)::text FROM heart360tk_schema.report_adherence_steps('2026-09-01', 0) r
    UNION ALL
    SELECT row(r.*)::text FROM heart360tk_schema.report_fudging_quarterly('2026-09-01', 0) r
    UNION ALL
    SELECT row(r.*)::text FROM heart360tk_schema.report_calling('2026-09-01', 0) r
    UNION ALL
    SELECT row(r.*)::text FROM heart360tk_schema.report_adherence_summary('2026-09-01', 0) r
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.15_to_0.6.16 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, thresholds or results" >&2
    exit 1
fi
check_steps
check_fudging
check_calling
check_monthly
echo "PASS second apply is idempotent; fixtures still pass"

echo "audit reports verified"
