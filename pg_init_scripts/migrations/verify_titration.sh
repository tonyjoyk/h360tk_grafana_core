#!/bin/bash
# Verifies 0.6.9_to_0.6.10 (story 5.4, CR-3): report_titration against hand-checked
# fixtures (CLINICAL-RULES section 6 Titration T1-T6, the 200/59 fixture, and the
# step-up, exclusion and window boundary cases), control_pct and looks_fine_check
# (PD-6), thresholds read from report_flag_thresholds, grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_titration.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION_COMMON="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.9_to_0.6.10.sql"
DB_NAME="${TITRATION_VERIFY_DB:-titration_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$TABLES" "$MIGRATION_PROTOCOL" "$MIGRATION_MEDICINE" "$MIGRATION_COMMON" "$MIGRATION"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

if ! grep -q '\\ir migrations/0.6.9_to_0.6.10.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.9_to_0.6.10.sql" >&2
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
echo "apply 0.6.0_to_0.6.1 (protocol_drugs)"
psql_db < "$MIGRATION_PROTOCOL" >/dev/null
echo "apply 0.6.7_to_0.6.8 (medicine model)"
psql_db < "$MIGRATION_MEDICINE" >/dev/null
echo "apply 0.6.8_to_0.6.9 (report common)"
psql_db < "$MIGRATION_COMMON" >/dev/null
echo "apply 0.6.9_to_0.6.10"
psql_db < "$MIGRATION" >/dev/null

# ---------------------------------------------------------------------------
# Fixture. Month 2026-09: window 2026-07-03 to 2026-09-30; a filler visit on 2026-09-30
# sets data_end, so a high BP visit after 2026-08-31 is too recent.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B, 303 Fac C, 304 Fac D
# Visits with no BP are written NULL/NULL; an Obat of NULL means no prescriptions row.
#
# Fac A (CLINICAL-RULES section 6, T1-T6; T1-T3 under Sub A1): 3 of 4 = 75.0%, too few,
#   too recent 1 (T5), no baseline 1 (T4).
# Fac B (Kolfe): 200 counted visits, 59 stepped up -> 29.5%, flagged.
#     1-50   baseline Step 1, high BP visit 08-01 at Step 2                -> stepped up at the visit
#     51-59  Step 1 at 08-01, next visit 08-31 (30 days) at Step 2        -> stepped up at the next visit
#     60-65  Step 1 at 08-01, next visit 09-01 (31 days) at Step 2        -> not stepped up
#     66-70  Step 1 at 08-31 23:00 (last day not too recent)              -> counted, not stepped up
#     71-200 Step 1 at 08-01                                              -> not stepped up
#     201-203 high BP visit 09-01 00:00                                   -> too recent
#     204    first visit is the high BP visit                             -> no baseline
#     205    baseline `Obat herbal` (unreadable)                          -> no baseline
# Fac C: only the filler patient (no BP) -> no visits.
# Fac D: step-up rule cases, each baseline 06-01, high BP visit 08-01 150/95 unless stated:
#     D1 Step 3 -> Step 2 (both on the ladder, lower)          not
#     D2 Losartan 50 -> Losartan 100 (more dose units)        stepped up
#     D3 Step 1 -> `Obat herbal` (Unrecognized)               not
#     D4 Step 2 -> Amlodipine 10 + Losartan 50 (more drugs)   stepped up
#     D5 Step 2 -> Lisinopril 10 (same count, fewer units)    not
#     D6 Step 1 -> Step 1                                     not
#     D7 Metformin -> Metformin (Unrecognized)                not
#     D8 no prescriptions row -> Step 2                       no baseline
#     D9 first visit 09-15 (too recent and no baseline)       too recent only
#     D10 Step 1 -> Step 2 at 130/90 (diastolic only)          stepped up
#     D11 Step 1 -> Step 1 at 139/89                          not a high BP visit
#     D12 Step 1 -> Step 2 at 07-02 23:59 (before the window) not counted
#   -> 8 counted, 3 stepped up (37.5%), too few; too recent 1, no baseline 1.
# HTN tab control (heart360_patients_category, 2026-09): Fac A 50 of 100, Fac B 75 of 100,
#   no row for Fac C and Fac D -> district 125 of 200 = 62.5%.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200), (304, 'Fac D', 3, 200),
    (401, 'Sub A1', 4, 301);

CREATE TEMP TABLE rx (k TEXT PRIMARY KEY, obat TEXT);
INSERT INTO rx VALUES
    ('S1',    'Amlodipine 5 mg - 1 x 1 Tablet Sehari'),
    ('S2',    'Amlodipine 10 mg - 1 x 1 Tablet Sehari'),
    ('S3',    'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari'),
    ('LOS50', 'Losartan 50 mg - 1 x 1 Tablet Sehari'),
    ('LOS100','Losartan 100 mg - 1 x 1 Tablet Sehari'),
    ('S2LOS', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Losartan 50 mg - 1 x 1 Tablet Sehari'),
    ('LIS10', 'Lisinopril 10 mg - 1 x 1 Tablet Sehari'),
    ('MET',   'Metformin 500 mg - 1 x 2 Tablet Sehari'),
    ('HERB',  'Obat herbal 2 x sehari'),
    ('NONE',  NULL);

-- one row per visit: patient, org, seq (encounter id = pid * 10 + seq), time, regimen, BP
CREATE TEMP TABLE plan (pid BIGINT, org INT, seq INT, ts TIMESTAMP, k TEXT, sys NUMERIC, dia NUMERIC, expect TEXT);
INSERT INTO plan VALUES
    -- Fac A: T1-T6
    (1, 401, 1, '2026-06-20 09:00', 'S1',   130, 80,  NULL),
    (1, 401, 2, '2026-07-15 09:00', 'S1',   150, 90,  'Step 1'),
    (1, 401, 3, '2026-08-05 09:00', 'S2',   NULL, NULL, 'Step 2'),
    (2, 401, 1, '2026-06-20 09:00', 'S1',   NULL, NULL, NULL),
    (2, 401, 2, '2026-07-20 09:00', 'S2',   150, 95,  'Step 2'),
    (3, 401, 1, '2026-06-20 09:00', 'S2',   NULL, NULL, NULL),
    (3, 401, 2, '2026-07-25 09:00', 'S2',   160, 100, 'Step 2'),
    (3, 401, 3, '2026-08-30 09:00', 'S2',   NULL, NULL, NULL),
    (4, 301, 1, '2026-07-10 09:00', 'S1',   155, 95,  'Step 1'),
    (5, 301, 1, '2026-08-01 09:00', 'S1',   NULL, NULL, NULL),
    (5, 301, 2, '2026-09-10 09:00', 'S1',   150, 90,  'Step 1'),
    (6, 301, 1, '2026-06-20 09:00', 'MET',  NULL, NULL, 'Unrecognized'),
    (6, 301, 2, '2026-07-12 09:00', 'S1',   150, 90,  'Step 1'),
    -- filler: newest encounter of the month, no BP
    (9, 303, 1, '2026-09-30 12:00', 'S1',   NULL, NULL, NULL),
    -- Fac D
    (4001, 304, 1, '2026-06-01 09:00', 'S3',     NULL, NULL, 'Step 3'),
    (4001, 304, 2, '2026-08-01 09:00', 'S2',     150, 95,  'Step 2'),
    (4002, 304, 1, '2026-06-01 09:00', 'LOS50',  NULL, NULL, 'Non-Protocol'),
    (4002, 304, 2, '2026-08-01 09:00', 'LOS100', 150, 95,  'Non-Protocol'),
    (4003, 304, 1, '2026-06-01 09:00', 'S1',     NULL, NULL, NULL),
    (4003, 304, 2, '2026-08-01 09:00', 'HERB',   150, 95,  'Unrecognized'),
    (4004, 304, 1, '2026-06-01 09:00', 'S2',     NULL, NULL, NULL),
    (4004, 304, 2, '2026-08-01 09:00', 'S2LOS',  150, 95,  'Non-Protocol'),
    (4005, 304, 1, '2026-06-01 09:00', 'S2',     NULL, NULL, NULL),
    (4005, 304, 2, '2026-08-01 09:00', 'LIS10',  150, 95,  'Other Protocol'),
    (4006, 304, 1, '2026-06-01 09:00', 'S1',     NULL, NULL, NULL),
    (4006, 304, 2, '2026-08-01 09:00', 'S1',     150, 95,  NULL),
    (4007, 304, 1, '2026-06-01 09:00', 'MET',    NULL, NULL, NULL),
    (4007, 304, 2, '2026-08-01 09:00', 'MET',    150, 95,  'Unrecognized'),
    (4008, 304, 1, '2026-06-01 09:00', 'NONE',   NULL, NULL, 'Unrecognized'),
    (4008, 304, 2, '2026-08-01 09:00', 'S2',     150, 95,  NULL),
    (4009, 304, 1, '2026-09-15 09:00', 'S1',     150, 95,  NULL),
    (4010, 304, 1, '2026-06-01 09:00', 'S1',     NULL, NULL, NULL),
    (4010, 304, 2, '2026-08-01 09:00', 'S2',     130, 90,  NULL),
    (4011, 304, 1, '2026-06-01 09:00', 'S1',     NULL, NULL, NULL),
    (4011, 304, 2, '2026-08-01 09:00', 'S1',     139, 89,  NULL),
    (4012, 304, 1, '2026-06-01 09:00', 'S1',     NULL, NULL, NULL),
    (4012, 304, 2, '2026-07-02 23:59', 'S2',     150, 95,  NULL);

-- Fac B: patients 2001-2205
INSERT INTO plan
SELECT 2000 + i, 302, 1, '2026-06-01 09:00', CASE WHEN i = 205 THEN 'HERB' ELSE 'S1' END, NULL, NULL, NULL
FROM generate_series(1, 205) i WHERE i <> 204;
INSERT INTO plan
SELECT 2000 + i, 302, 2,
       CASE WHEN i BETWEEN 66 AND 70 THEN '2026-08-31 23:00'
            WHEN i BETWEEN 201 AND 203 THEN '2026-09-01 00:00'
            ELSE '2026-08-01 10:00' END::timestamp,
       CASE WHEN i <= 50 THEN 'S2' ELSE 'S1' END, 150, 95, NULL
FROM generate_series(1, 205) i;
INSERT INTO plan
SELECT 2000 + i, 302, 3,
       CASE WHEN i <= 59 THEN '2026-08-31 08:00' ELSE '2026-09-01 08:00' END::timestamp,
       'S2', NULL, NULL, NULL
FROM generate_series(51, 65) i;

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Fixture ' || pid, 'ALIVE', min(ts), '1960-01-01', min(org) FROM plan GROUP BY pid;
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) SELECT DISTINCT pid, 'I10' FROM plan;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT pid * 10 + seq, pid, ts, org FROM plan;
INSERT INTO prescriptions (encounter_id, obat_raw, source)
SELECT p.pid * 10 + p.seq, rx.obat, 'fixture' FROM plan p JOIN rx USING (k) WHERE rx.obat IS NOT NULL;
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
SELECT pid * 10 + seq, sys, dia FROM plan WHERE sys IS NOT NULL;

-- HTN tab rows for control_pct
INSERT INTO heart360tk_reporting.heart360_patients_category
    (ref_month, org_unit_id, total_number_of_patients, nb_patients_newly_registered,
     nb_patients_lost_to_follow_up, nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit)
VALUES ('2026-09-01', 301, 100, 0, 0, 50, 30, 20),
       ('2026-09-01', 302, 100, 0, 0, 75, 20, 5);

-- The classifier agrees with the plan before the report is checked.
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(p.pid || '/' || p.seq || ':' || p.expect || '<>' || v.bucket, ', ') INTO v_bad
    FROM plan p JOIN visit_step v ON v.encounter_id = p.pid * 10 + p.seq
    WHERE p.expect IS NOT NULL AND v.bucket <> p.expect;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'fixture buckets differ from visit_step: %', v_bad;
    END IF;
    IF (SELECT data_end FROM report_window('2026-09-01')) <> '2026-09-30' THEN
        RAISE EXCEPTION 'filler visit does not set data_end';
    END IF;
END $$;
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_titration: exact rows
# ---------------------------------------------------------------------------
check_report() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (
    call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, level INT, is_selected BOOLEAN,
    too_few BOOLEAN, flag BOOLEAN, flag_reason TEXT,
    uncontrolled_visits_n BIGINT, stepped_up_n BIGINT, titration_pct NUMERIC,
    excluded_too_recent_n BIGINT, excluded_no_baseline_n BIGINT, control_pct NUMERIC, looks_fine_check BOOLEAN
);
INSERT INTO expected VALUES
    -- district
    ('d', 1, 200, 'Fixture District', 2, TRUE,  FALSE, TRUE,  'Medicine rarely stepped up: 30.7% of 212 high BP visits.',
         212, 65, 30.7, 5, 4, 62.5, TRUE),
    ('d', 2, 301, 'Fac A',            3, FALSE, TRUE,  FALSE, NULL, 4,   3,  75.0, 1, 1, 50.0, FALSE),
    ('d', 3, 302, 'Fac B',            3, FALSE, FALSE, TRUE,  'Medicine rarely stepped up: 29.5% of 200 high BP visits.',
         200, 59, 29.5, 3, 2, 75.0, TRUE),
    ('d', 4, 303, 'Fac C',            3, FALSE, TRUE,  FALSE, NULL, 0,   0,  NULL, 0, 0, NULL, FALSE),
    ('d', 5, 304, 'Fac D',            3, FALSE, TRUE,  FALSE, NULL, 8,   3,  37.5, 1, 1, NULL, FALSE),
    -- All places in view
    ('a', 1, 0,   'All places in view', 0, TRUE, FALSE, TRUE, 'Medicine rarely stepped up: 30.7% of 212 high BP visits.',
         212, 65, 30.7, 5, 4, 62.5, TRUE),
    ('a', 2, 301, 'Fac A',            3, FALSE, TRUE,  FALSE, NULL, 4,   3,  75.0, 1, 1, 50.0, FALSE),
    ('a', 3, 302, 'Fac B',            3, FALSE, FALSE, TRUE,  'Medicine rarely stepped up: 29.5% of 200 high BP visits.',
         200, 59, 29.5, 3, 2, 75.0, TRUE),
    ('a', 4, 303, 'Fac C',            3, FALSE, TRUE,  FALSE, NULL, 0,   0,  NULL, 0, 0, NULL, FALSE),
    ('a', 5, 304, 'Fac D',            3, FALSE, TRUE,  FALSE, NULL, 8,   3,  37.5, 1, 1, NULL, FALSE),
    -- facility and sub-facility selections: one row each
    ('f', 1, 301, 'Fac A',            3, TRUE,  TRUE,  FALSE, NULL, 4,   3,  75.0, 1, 1, 50.0, FALSE),
    ('k', 1, 302, 'Fac B',            3, TRUE,  FALSE, TRUE,  'Medicine rarely stepped up: 29.5% of 200 high BP visits.',
         200, 59, 29.5, 3, 2, 75.0, TRUE),
    ('s', 1, 401, 'Sub A1',           4, TRUE,  TRUE,  FALSE, NULL, 3,   2,  66.7, 0, 0, NULL, FALSE);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_titration('2026-09-01', 200) r
UNION ALL SELECT 'a',  row_number() OVER (), r.* FROM report_titration('2026-09-01', 0) r
UNION ALL SELECT 'a0', row_number() OVER (), r.* FROM report_titration('2026-09-01', NULL) r
UNION ALL SELECT 'f',  row_number() OVER (), r.* FROM report_titration('2026-09-01', 301) r
UNION ALL SELECT 'k',  row_number() OVER (), r.* FROM report_titration('2026-09-01', 302) r
UNION ALL SELECT 's',  row_number() OVER (), r.* FROM report_titration('2026-09-01', 401) r
UNION ALL SELECT 'x',  row_number() OVER (), r.* FROM report_titration('2026-09-01', 999) r;

DO $$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(x::text, E'\n') INTO v_diff
    FROM (
        (SELECT 'missing' AS k, e.* FROM expected e
         EXCEPT ALL
         SELECT 'missing', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few, g.flag,
                g.flag_reason, g.uncontrolled_visits_n, g.stepped_up_n, g.titration_pct, g.excluded_too_recent_n,
                g.excluded_no_baseline_n, g.control_pct, g.looks_fine_check
         FROM got g)
        UNION ALL
        (SELECT 'extra', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few, g.flag,
                g.flag_reason, g.uncontrolled_visits_n, g.stepped_up_n, g.titration_pct, g.excluded_too_recent_n,
                g.excluded_no_baseline_n, g.control_pct, g.looks_fine_check
         FROM got g
         WHERE g.call IN ('d', 'a', 'f', 'k', 's')
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_titration differs:\n%', v_diff;
    END IF;
    IF EXISTS (
        (SELECT ord, org_unit_id, too_few, flag, flag_reason, uncontrolled_visits_n, stepped_up_n, titration_pct,
                excluded_too_recent_n, excluded_no_baseline_n, control_pct, looks_fine_check FROM got WHERE call = 'a'
         EXCEPT ALL
         SELECT ord, org_unit_id, too_few, flag, flag_reason, uncontrolled_visits_n, stepped_up_n, titration_pct,
                excluded_too_recent_n, excluded_no_baseline_n, control_pct, looks_fine_check FROM got WHERE call = 'a0')
        UNION ALL
        (SELECT ord, org_unit_id, too_few, flag, flag_reason, uncontrolled_visits_n, stepped_up_n, titration_pct,
                excluded_too_recent_n, excluded_no_baseline_n, control_pct, looks_fine_check FROM got WHERE call = 'a0'
         EXCEPT ALL
         SELECT ord, org_unit_id, too_few, flag, flag_reason, uncontrolled_visits_n, stepped_up_n, titration_pct,
                excluded_too_recent_n, excluded_no_baseline_n, control_pct, looks_fine_check FROM got WHERE call = 'a')
    ) THEN
        RAISE EXCEPTION 'report_titration(0) and (NULL) differ';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE call = 'x') THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;
END $$;
SQL
}
check_report
echo "PASS report_titration rows (T1-T6 75.0% too few; 200/59 = 29.5% flagged; district, All places, facility, sub-facility)"

# ---------------------------------------------------------------------------
# Per-visit outcome of every fixture case (h360_titration_visits)
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(patient_id || '=' || COALESCE(excluded, CASE WHEN stepped_up THEN 'up' ELSE 'no' END), ' '
                      ORDER BY patient_id) INTO v
    FROM h360_titration_visits('2026-09-01', 0)
    WHERE patient_id < 2000 OR patient_id > 4000;
    IF v IS DISTINCT FROM
       '1=up 2=up 3=no 4=no_baseline 5=too_recent 6=up '
       '4001=no 4002=up 4003=no 4004=up 4005=no 4006=no 4007=no 4008=no_baseline 4009=too_recent 4010=up' THEN
        RAISE EXCEPTION 'per-visit outcomes = %', v;
    END IF;
    -- Fac B by group
    SELECT string_agg(g || ':' || n, ' ' ORDER BY g) INTO v FROM (
        SELECT CASE WHEN patient_id - 2000 <= 50 THEN 'a' WHEN patient_id - 2000 <= 59 THEN 'b'
                    WHEN patient_id - 2000 <= 65 THEN 'c' WHEN patient_id - 2000 <= 70 THEN 'd'
                    WHEN patient_id - 2000 <= 200 THEN 'e' ELSE 'f' END
               || ':' || COALESCE(excluded, CASE WHEN stepped_up THEN 'up' ELSE 'no' END) AS g,
               count(*) AS n
        FROM h360_titration_visits('2026-09-01', 302)
        GROUP BY 1
    ) s;
    IF v IS DISTINCT FROM 'a:up:50 b:up:9 c:no:6 d:no:5 e:no:130 f:no_baseline:2 f:too_recent:3' THEN
        RAISE EXCEPTION 'Fac B outcomes = %', v;
    END IF;
END $$;
SQL
echo "PASS step-up rule: ladder by step_no, else drugs then dose units; Unrecognized never; exclusions and bounds"

# ---------------------------------------------------------------------------
# Thresholds come from report_flag_thresholds, not literals
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    r RECORD;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'heart360tk_schema'
          AND p.proname IN ('report_titration', 'h360_titration_visits')
          AND p.prosrc ~ '\m(10|30|40|60)(\.0+)?\M'
    ) THEN
        RAISE EXCEPTION 'a titration function holds a threshold literal (10, 30, 40 or 60)';
    END IF;

    -- min 4 and flag below 75.1: Fac A (4 visits, 75.0%) flags; high control at 50: the pill shows
    UPDATE report_flag_thresholds SET value = 4    WHERE report = 'titration' AND key = 'min_visits';
    UPDATE report_flag_thresholds SET value = 75.1 WHERE report = 'titration' AND key = 'flag_below_pct';
    UPDATE report_flag_thresholds SET value = 50   WHERE report = 'common'    AND key = 'high_control_pct';
    SELECT * INTO r FROM report_titration('2026-09-01', 301);
    IF (r.too_few, r.flag, r.flag_reason, r.looks_fine_check) IS DISTINCT FROM
       (FALSE, TRUE, 'Medicine rarely stepped up: 75.0% of 4 high BP visits.', TRUE) THEN
        RAISE EXCEPTION 'threshold change not picked up: %', r;
    END IF;
    -- next visit within 20 days: T1's step-up 21 days later no longer counts;
    -- too recent after data_end - 20 (09-10): T5's 09-10 visit is now counted (not stepped up)
    UPDATE report_flag_thresholds SET value = 20 WHERE report = 'titration' AND key = 'next_visit_days';
    UPDATE report_flag_thresholds SET value = 20 WHERE report = 'titration' AND key = 'too_recent_days';
    SELECT * INTO r FROM report_titration('2026-09-01', 301);
    IF (r.uncontrolled_visits_n, r.stepped_up_n, r.excluded_too_recent_n) IS DISTINCT FROM (5::bigint, 2::bigint, 0::bigint) THEN
        RAISE EXCEPTION 'day thresholds not picked up: %', r;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(report || '.' || key || '=' || value, ',' ORDER BY report, key) FROM heart360tk_schema.report_flag_thresholds WHERE report IN ('titration', 'common')")" \
      != "common.high_control_pct=60,titration.flag_below_pct=40,titration.min_visits=10,titration.next_visit_days=30,titration.too_recent_days=30" ]]; then
    echo "FAIL threshold probe was not rolled back" >&2
    exit 1
fi
echo "PASS flags and day bounds follow report_flag_thresholds (no literals; changed rows change the result)"

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
      AND p.proname = 'report_titration'
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_function_identity_arguments(p.oid) <> 'p_reporting_month date, p_org_unit_id integer'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname = 'report_titration') <> 1 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND p.proname = 'h360_titration_visits'
      AND (p.prosecdef
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('h360_api', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'visit-level helper is definer or executable outside heart360tk: %', v_bad;
    END IF;
END $$;

-- h360_api has no table privileges; the definer function still answers.
SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT titration_pct FROM heart360tk_schema.report_titration('2026-09-01', 302)) <> 29.5 THEN
        RAISE EXCEPTION 'h360_api got a different titration_pct';
    END IF;
    BEGIN
        PERFORM * FROM heart360tk_schema.h360_titration_visits('2026-09-01', 0);
        RAISE EXCEPTION 'h360_api executed h360_titration_visits';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_titration('2026-09-01', 0);
RESET ROLE;
SQL
echo "PASS grants: report_titration definer, executable by heart360tk_reader and h360_api, not PUBLIC; helper not granted"

# ---------------------------------------------------------------------------
# Idempotence: a second apply changes nothing
# ---------------------------------------------------------------------------
snapshot() {
    psql_db -tA <<'SQL'
SELECT md5(string_agg(x, E'\n' ORDER BY x)) FROM (
    SELECT p.oid::regprocedure::text || pg_get_functiondef(p.oid) || COALESCE(p.proacl::text, '') AS x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND (p.proname LIKE 'report_%' OR p.proname LIKE 'h360_%')
    UNION ALL
    SELECT row(r.*)::text FROM heart360tk_schema.report_titration('2026-09-01', 0) r
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.9_to_0.6.10 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, thresholds or results" >&2
    exit 1
fi
check_report
echo "PASS second apply is idempotent; fixtures still pass"

echo "titration verified"
