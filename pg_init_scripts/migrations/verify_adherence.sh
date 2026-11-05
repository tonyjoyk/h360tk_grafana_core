#!/bin/bash
# Verifies the protocol adherence part of 0.6.8_to_0.6.9 (story 5.7, CR-2):
# report_adherence and report_adherence_buckets against hand-checked fixtures
# (CLINICAL-RULES section 6 Adherence, plus flag, rounding, too-few and boundary
# cases), thresholds read from report_flag_thresholds, grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   PSQL="docker exec -i postgres psql -U h360tk_root" ./verify_adherence.sh
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
DB_NAME="${ADHERENCE_VERIFY_DB:-adherence_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$TABLES" "$MIGRATION_PROTOCOL" "$MIGRATION_MEDICINE" "$MIGRATION"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

if ! grep -q '\\ir migrations/0.6.8_to_0.6.9.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.8_to_0.6.9.sql" >&2
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
echo "apply 0.6.8_to_0.6.9"
psql_db < "$MIGRATION" >/dev/null

# ---------------------------------------------------------------------------
# Fixture. Month 2026-09: window 2026-07-03 to 2026-09-30.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B, 303 Fac C,
#                               304 Fac D, 305 Fac E, 306 Fac F (no patients)
# Each patient: a first visit 2026-01-01 (no prescription) and one visit in the window
# with the bucket's Obat cell and BP, unless stated.
#
# Fac A (CLINICAL-RULES section 6): patients 1-9 under Sub A1, one per bucket, Steps 1-3
#   controlled, Step 4 without a BP row, the rest 150/95. Patient 1 also has a Non-Protocol
#   visit on 07-10 (earlier in the window) and on 10-05 (after it): Step 1 must win.
#   Patient 10 at Fac A: first visit 2026-08-01, Step 2 120/70 on 09-01 (include_new only).
#   Excluded: 11 dead, 12 E11 only, 13 last visit 06-30 (before the window).
# Fac B: 34 patients; 4 Non-Protocol + 4 Other Protocol (150/95), 5 Step 1, 5 Step 2,
#   4 each Step 3-6 (130/80) -> off-protocol 23.5%, flagged.
# Fac C: 25 patients, no BP; 8 Step 1, 8 Step 2, 2 Other, 2 Non, 5 Step 3 -> one medicine 64.0%.
# Fac D: 496 patients, 130/80; 298 Step 1, 99 Non-Protocol, 99 Step 3 -> off 19.96% shows
#   20.0% and is flagged (displayed value), one medicine 60.08% shows 60.1%.
# Fac E: 20 Non-Protocol patients, no BP; window visits at 07-03 00:00 and 09-30 23:30 count,
#   one at 07-02 23:59:59 does not -> cohort 19, too few, not flagged.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200),
    (304, 'Fac D', 3, 200), (305, 'Fac E', 3, 200), (306, 'Fac F', 3, 200),
    (401, 'Sub A1', 4, 301);

CREATE TEMP TABLE rx (bucket TEXT PRIMARY KEY, obat TEXT);
INSERT INTO rx VALUES
    ('Step 1', 'Amlodipine 5 mg - 1 x 1 Tablet Sehari'),
    ('Step 2', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari'),
    ('Step 3', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari'),
    ('Step 4', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari'),
    ('Step 5', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Hydrochlorothiazide 12,5 mg - 1 x 1 Tablet Sehari'),
    ('Step 6', 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Telmisartan 80 mg - 1 x 1 Tablet Sehari; Chlorthalidone 25 mg - 1 x 1 Tablet Sehari'),
    ('Other Protocol', 'Lisinopril 10 mg - 1 x 1 Tablet Sehari'),
    ('Non-Protocol', 'Losartan 50 mg - 1 x 1 Tablet Sehari'),
    ('Unrecognized', 'Obat herbal 2 x sehari');

CREATE TEMP TABLE plan (
    pid BIGINT, org INT, status TEXT, dx TEXT,
    first_ts TIMESTAMP, visit_ts TIMESTAMP, bucket TEXT, sys NUMERIC, dia NUMERIC
);
INSERT INTO plan VALUES
    (1,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Step 1',         130, 80),
    (2,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Step 2',         130, 80),
    (3,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Step 3',         130, 80),
    (4,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Step 4',         NULL, NULL),
    (5,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Step 5',         150, 95),
    (6,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Step 6',         150, 95),
    (7,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Other Protocol', 150, 95),
    (8,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Non-Protocol',   150, 95),
    (9,  401, 'ALIVE', 'I10', '2026-01-01', '2026-09-01', 'Unrecognized',   150, 95),
    (10, 301, 'ALIVE', 'I10', '2026-08-01', '2026-09-01', 'Step 2',         120, 70),
    (11, 401, 'DEAD',  'I10', '2026-01-01', '2026-09-01', 'Step 1',         130, 80),
    (12, 401, 'ALIVE', 'E11', '2026-01-01', '2026-09-01', 'Step 1',         130, 80),
    (13, 401, 'ALIVE', 'I10', '2026-01-01', '2026-06-30', 'Step 1',         130, 80);

INSERT INTO plan
SELECT 1000 + i, 302, 'ALIVE', 'I10', '2026-01-01', '2026-09-01',
       CASE WHEN i <= 4 THEN 'Non-Protocol' WHEN i <= 8 THEN 'Other Protocol'
            WHEN i <= 13 THEN 'Step 1' WHEN i <= 18 THEN 'Step 2' WHEN i <= 22 THEN 'Step 3'
            WHEN i <= 26 THEN 'Step 4' WHEN i <= 30 THEN 'Step 5' ELSE 'Step 6' END,
       CASE WHEN i <= 8 THEN 150 ELSE 130 END, CASE WHEN i <= 8 THEN 95 ELSE 80 END
FROM generate_series(1, 34) i;

INSERT INTO plan
SELECT 2000 + i, 303, 'ALIVE', 'I10', '2026-01-01', '2026-09-01',
       CASE WHEN i <= 8 THEN 'Step 1' WHEN i <= 16 THEN 'Step 2' WHEN i <= 18 THEN 'Other Protocol'
            WHEN i <= 20 THEN 'Non-Protocol' ELSE 'Step 3' END,
       NULL, NULL
FROM generate_series(1, 25) i;

INSERT INTO plan
SELECT 3000 + i, 304, 'ALIVE', 'I10', '2026-01-01', '2026-09-01',
       CASE WHEN i <= 298 THEN 'Step 1' WHEN i <= 397 THEN 'Non-Protocol' ELSE 'Step 3' END,
       130, 80
FROM generate_series(1, 496) i;

INSERT INTO plan
SELECT 4000 + i, 305, 'ALIVE', 'I10', '2026-01-01',
       CASE i WHEN 1 THEN '2026-07-03 00:00:00' WHEN 2 THEN '2026-09-30 23:30:00'
              WHEN 20 THEN '2026-07-02 23:59:59' ELSE '2026-09-01' END::timestamp,
       'Non-Protocol', NULL, NULL
FROM generate_series(1, 20) i;

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Fixture ' || pid, status, first_ts, '1960-01-01', org FROM plan;
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) SELECT pid, dx FROM plan;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT pid * 10 + 1, pid, first_ts, org FROM plan
UNION ALL
SELECT pid * 10 + 2, pid, visit_ts, org FROM plan;
-- patient 1: Non-Protocol visits earlier in the window and after it
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES
    (13, 1, '2026-07-10 09:00', 401),
    (14, 1, '2026-10-05 09:00', 401);
INSERT INTO prescriptions (encounter_id, obat_raw, source)
SELECT p.pid * 10 + 2, rx.obat, 'fixture' FROM plan p JOIN rx USING (bucket)
UNION ALL
SELECT e, (SELECT obat FROM rx WHERE bucket = 'Non-Protocol'), 'fixture' FROM unnest(ARRAY[13, 14]::bigint[]) e;
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
SELECT pid * 10 + 2, sys, dia FROM plan WHERE sys IS NOT NULL
UNION ALL
VALUES (13::bigint, 160::numeric, 100::numeric), (14, 160, 100);

-- The classifier agrees with the plan before the report is checked.
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(p.pid || ':' || p.bucket || '<>' || v.bucket, ', ') INTO v_bad
    FROM plan p JOIN visit_step v ON v.encounter_id = p.pid * 10 + 2
    WHERE v.bucket <> p.bucket;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'fixture buckets differ from visit_step: %', v_bad;
    END IF;
END $$;
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_adherence: exact rows
# ---------------------------------------------------------------------------
check_report() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (
    call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, level INT, is_selected BOOLEAN,
    too_few BOOLEAN, flag BOOLEAN, flag_reason TEXT,
    cohort_n BIGINT, controlled_n BIGINT, controlled_pct NUMERIC, off_protocol_pct NUMERIC, one_medicine_pct NUMERIC
);
INSERT INTO expected VALUES
    -- district, strict
    ('d', 1, 200, 'Fixture District', 2, TRUE,  FALSE, TRUE,  'Many patients are on medicines outside the protocol: 22.6%.', 583, 525, 90.1, 22.6, 55.9),
    ('d', 2, 301, 'Fac A',            3, FALSE, TRUE,  FALSE, NULL, 9,   3,   33.3, 22.2, 22.2),
    ('d', 3, 302, 'Fac B',            3, FALSE, FALSE, TRUE,  'Many patients are on medicines outside the protocol: 23.5%.', 34, 26, 76.5, 23.5, 29.4),
    ('d', 4, 303, 'Fac C',            3, FALSE, FALSE, TRUE,  'Most patients stay on one medicine: 64.0%.', 25, 0, 0.0, 16.0, 64.0),
    ('d', 5, 304, 'Fac D',            3, FALSE, FALSE, TRUE,
         'Many patients are on medicines outside the protocol: 20.0%. Most patients stay on one medicine: 60.1%.', 496, 496, 100.0, 20.0, 60.1),
    ('d', 6, 305, 'Fac E',            3, FALSE, TRUE,  FALSE, NULL, 19,  0,   0.0,  100.0, 0.0),
    ('d', 7, 306, 'Fac F',            3, FALSE, TRUE,  FALSE, NULL, 0,   0,   NULL, NULL, NULL),
    -- all places, strict (0 and NULL)
    ('a', 1, 0,   'All places in view', 0, TRUE, FALSE, TRUE, 'Many patients are on medicines outside the protocol: 22.6%.', 583, 525, 90.1, 22.6, 55.9),
    ('a', 2, 301, 'Fac A',            3, FALSE, TRUE,  FALSE, NULL, 9,   3,   33.3, 22.2, 22.2),
    ('a', 3, 302, 'Fac B',            3, FALSE, FALSE, TRUE,  'Many patients are on medicines outside the protocol: 23.5%.', 34, 26, 76.5, 23.5, 29.4),
    ('a', 4, 303, 'Fac C',            3, FALSE, FALSE, TRUE,  'Most patients stay on one medicine: 64.0%.', 25, 0, 0.0, 16.0, 64.0),
    ('a', 5, 304, 'Fac D',            3, FALSE, FALSE, TRUE,
         'Many patients are on medicines outside the protocol: 20.0%. Most patients stay on one medicine: 60.1%.', 496, 496, 100.0, 20.0, 60.1),
    ('a', 6, 305, 'Fac E',            3, FALSE, TRUE,  FALSE, NULL, 19,  0,   0.0,  100.0, 0.0),
    ('a', 7, 306, 'Fac F',            3, FALSE, TRUE,  FALSE, NULL, 0,   0,   NULL, NULL, NULL),
    -- facility selection: one row; sub-facility selection: one row
    ('f', 1, 301, 'Fac A',            3, TRUE,  TRUE,  FALSE, NULL, 9,   3,   33.3, 22.2, 22.2),
    ('s', 1, 401, 'Sub A1',           4, TRUE,  TRUE,  FALSE, NULL, 9,   3,   33.3, 22.2, 22.2),
    -- include_new: patient 10 joins Fac A
    ('fn', 1, 301, 'Fac A',           3, TRUE,  TRUE,  FALSE, NULL, 10,  4,   40.0, 20.0, 30.0),
    ('dn', 1, 200, 'Fixture District', 2, TRUE, FALSE, TRUE,  'Many patients are on medicines outside the protocol: 22.6%.', 584, 526, 90.1, 22.6, 56.0),
    ('dn', 2, 301, 'Fac A',           3, FALSE, TRUE,  FALSE, NULL, 10,  4,   40.0, 20.0, 30.0);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_adherence('2026-09-01', 200) r
UNION ALL SELECT 'a',  row_number() OVER (), r.* FROM report_adherence('2026-09-01', 0) r
UNION ALL SELECT 'a0', row_number() OVER (), r.* FROM report_adherence('2026-09-01', NULL) r
UNION ALL SELECT 'f',  row_number() OVER (), r.* FROM report_adherence('2026-09-01', 301) r
UNION ALL SELECT 's',  row_number() OVER (), r.* FROM report_adherence('2026-09-01', 401) r
UNION ALL SELECT 'fn', row_number() OVER (), r.* FROM report_adherence('2026-09-01', 301, true) r
UNION ALL SELECT 'dn', row_number() OVER (), r.* FROM report_adherence('2026-09-01', 200, true) r
UNION ALL SELECT 'x',  row_number() OVER (), r.* FROM report_adherence('2026-09-01', 999) r;

DO $$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(x::text, E'\n') INTO v_diff
    FROM (
        (SELECT 'missing' AS k, e.* FROM expected e
         EXCEPT ALL
         SELECT 'missing', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few, g.flag,
                g.flag_reason, g.cohort_n, g.controlled_n, g.controlled_pct, g.off_protocol_pct, g.one_medicine_pct
         FROM got g)
        UNION ALL
        (SELECT 'extra', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few, g.flag,
                g.flag_reason, g.cohort_n, g.controlled_n, g.controlled_pct, g.off_protocol_pct, g.one_medicine_pct
         FROM got g
         WHERE g.call IN ('d', 'a', 'f', 's', 'fn') OR (g.call = 'dn' AND g.ord <= 2)
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_adherence differs:\n%', v_diff;
    END IF;
    -- 0 and NULL give identical rows
    IF EXISTS (
        (SELECT ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, cohort_n, controlled_n,
                controlled_pct, off_protocol_pct, one_medicine_pct FROM got WHERE call = 'a'
         EXCEPT ALL
         SELECT ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, cohort_n, controlled_n,
                controlled_pct, off_protocol_pct, one_medicine_pct FROM got WHERE call = 'a0')
        UNION ALL
        (SELECT ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, cohort_n, controlled_n,
                controlled_pct, off_protocol_pct, one_medicine_pct FROM got WHERE call = 'a0'
         EXCEPT ALL
         SELECT ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, cohort_n, controlled_n,
                controlled_pct, off_protocol_pct, one_medicine_pct FROM got WHERE call = 'a')
    ) THEN
        RAISE EXCEPTION 'report_adherence(0) and (NULL) differ';
    END IF;
    -- include_new at the district: selection and Fac A checked above; the other facilities are unchanged
    IF (SELECT count(*) FROM got WHERE call = 'dn') <> 7
       OR EXISTS (SELECT org_unit_id, cohort_n, flag_reason FROM got WHERE call = 'dn' AND ord > 2
                  EXCEPT SELECT org_unit_id, cohort_n, flag_reason FROM got WHERE call = 'd' AND ord > 2) THEN
        RAISE EXCEPTION 'report_adherence(200, true) facility rows are wrong';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE call = 'x') THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;
END $$;
SQL
}
check_report
echo "PASS report_adherence rows (district, All places in view, facility, sub-facility, include_new)"

# ---------------------------------------------------------------------------
# report_adherence_buckets
# ---------------------------------------------------------------------------
check_buckets() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    -- CLINICAL-RULES section 6: nine rows, one patient each, Steps 1-3 controlled
    SELECT string_agg(bucket_order || '|' || bucket || '|' || label || '|' || patients_n || '|' || controlled_n || '|'
                      || COALESCE(controlled_pct::text, '-'), E'\n' ORDER BY bucket_order) INTO v
    FROM report_adherence_buckets('2026-09-01', 301);
    IF v IS DISTINCT FROM concat_ws(E'\n',
        '1|Step 1|1 medicine, starting dose|1|1|100.0',
        '2|Step 2|1 medicine, full dose|1|1|100.0',
        '3|Step 3|2 medicines, one at full dose|1|1|100.0',
        '4|Step 4|2 medicines, both at full dose|1|0|0.0',
        '5|Step 5|3 medicines, third at starting dose|1|0|0.0',
        '6|Step 6|3 medicines, all at full dose|1|0|0.0',
        '7|Other Protocol|Other protocol combination|1|0|0.0',
        '8|Non-Protocol|Medicine outside the protocol|1|0|0.0',
        '9|Unrecognized|Could not read the entry|1|0|0.0') THEN
        RAISE EXCEPTION E'buckets(301) =\n%', v;
    END IF;

    -- step labels are htn_ladder_steps.label (C16)
    IF EXISTS (
        SELECT 1 FROM report_adherence_buckets('2026-09-01', 301) b
        JOIN htn_ladder_steps s ON s.step_no = b.bucket_order
        WHERE b.label <> s.label
    ) THEN
        RAISE EXCEPTION 'step labels differ from htn_ladder_steps.label';
    END IF;

    -- include_new: the 10th patient (Step 2, controlled) appears; counts sum to cohort_n
    SELECT string_agg(bucket_order || ':' || patients_n || '/' || controlled_n, ' ' ORDER BY bucket_order) INTO v
    FROM report_adherence_buckets('2026-09-01', 301, true);
    IF v IS DISTINCT FROM '1:1/1 2:2/2 3:1/1 4:1/0 5:1/0 6:1/0 7:1/0 8:1/0 9:1/0' THEN
        RAISE EXCEPTION 'buckets(301, true) = %', v;
    END IF;

    -- All places: counts and controlled per bucket, summing to the cohort
    SELECT string_agg(bucket_order || ':' || patients_n || '/' || controlled_n || '/' || COALESCE(controlled_pct::text, '-'),
                      ' ' ORDER BY bucket_order) INTO v
    FROM report_adherence_buckets('2026-09-01', 0);
    IF v IS DISTINCT FROM '1:312/304/97.4 2:14/6/42.9 3:109/104/95.4 4:5/4/80.0 5:5/4/80.0 6:5/4/80.0 7:7/0/0.0 8:125/99/79.2 9:1/0/0.0' THEN
        RAISE EXCEPTION 'buckets(0) = %', v;
    END IF;

    -- bucket counts sum to cohort_n of the selection row, for every selection and mode
    IF EXISTS (
        SELECT 1
        FROM (VALUES (0, false), (0, true), (200, false), (200, true), (301, false), (301, true),
                     (302, false), (303, false), (304, false), (305, false), (306, false), (401, false)) s(org, inc)
        WHERE (SELECT sum(patients_n) FROM report_adherence_buckets('2026-09-01', s.org, s.inc))
              IS DISTINCT FROM (SELECT cohort_n FROM report_adherence('2026-09-01', s.org, s.inc) WHERE is_selected)
           OR (SELECT sum(controlled_n) FROM report_adherence_buckets('2026-09-01', s.org, s.inc))
              IS DISTINCT FROM (SELECT controlled_n FROM report_adherence('2026-09-01', s.org, s.inc) WHERE is_selected)
           OR (SELECT count(*) FROM report_adherence_buckets('2026-09-01', s.org, s.inc)) <> 9
    ) THEN
        RAISE EXCEPTION 'bucket counts do not sum to the cohort';
    END IF;

    -- empty facility: nine zero rows, percent NULL; unknown org: no rows
    IF (SELECT string_agg(patients_n || '/' || COALESCE(controlled_pct::text, '-'), ' ' ORDER BY bucket_order)
        FROM report_adherence_buckets('2026-09-01', 306)) IS DISTINCT FROM '0/- 0/- 0/- 0/- 0/- 0/- 0/- 0/- 0/-' THEN
        RAISE EXCEPTION 'buckets for an empty facility are wrong';
    END IF;
    IF EXISTS (SELECT 1 FROM report_adherence_buckets('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'buckets for an unknown org unit gave rows';
    END IF;
END $$;
SQL
}
check_buckets
echo "PASS report_adherence_buckets (nine rows, ladder labels, include_new, sums equal cohort_n)"

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
          AND p.proname IN ('report_adherence', 'report_adherence_buckets', 'h360_adherence_patients')
          AND p.prosrc ~ '\m(20|60)(\.0+)?\M'
    ) THEN
        RAISE EXCEPTION 'an adherence function holds a threshold literal (20 or 60)';
    END IF;

    -- lower the minimum to 9 and the one-medicine line to 22.2: Fac A (cohort 9, both 22.2%) flags twice
    UPDATE report_flag_thresholds SET value = 9 WHERE report = 'adherence' AND key = 'min_cohort';
    UPDATE report_flag_thresholds SET value = 22.2 WHERE report = 'adherence' AND key = 'one_medicine_pct';
    SELECT * INTO r FROM report_adherence('2026-09-01', 301);
    IF (r.too_few, r.flag, r.flag_reason) IS DISTINCT FROM
       (FALSE, TRUE, 'Many patients are on medicines outside the protocol: 22.2%. Most patients stay on one medicine: 22.2%.') THEN
        RAISE EXCEPTION 'threshold change not picked up: %', r;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(key || '=' || value, ',' ORDER BY key) FROM heart360tk_schema.report_flag_thresholds WHERE report = 'adherence'")" \
      != "min_cohort=20,off_protocol_pct=20,one_medicine_pct=60" ]]; then
    echo "FAIL threshold probe was not rolled back" >&2
    exit 1
fi
echo "PASS flags follow report_flag_thresholds (no literals; a changed row changes the flag)"

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
      AND p.proname IN ('report_adherence', 'report_adherence_buckets')
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname IN ('report_adherence', 'report_adherence_buckets')) <> 2 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND p.proname = 'h360_adherence_patients'
      AND (p.prosecdef
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('h360_api', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'patient-level helper is definer or executable outside heart360tk: %', v_bad;
    END IF;
END $$;

-- h360_api has no table privileges; the definer functions still answer.
SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT cohort_n FROM heart360tk_schema.report_adherence('2026-09-01', 0) WHERE is_selected) <> 583 THEN
        RAISE EXCEPTION 'h360_api got a different cohort';
    END IF;
    IF (SELECT count(*) FROM heart360tk_schema.report_adherence_buckets('2026-09-01', 0)) <> 9 THEN
        RAISE EXCEPTION 'h360_api got a different bucket count';
    END IF;
    BEGIN
        PERFORM * FROM heart360tk_schema.h360_adherence_patients('2026-09-01', 0, false);
        RAISE EXCEPTION 'h360_api executed h360_adherence_patients';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_adherence('2026-09-01', 301);
SELECT 1 FROM heart360tk_schema.report_adherence_buckets('2026-09-01', 301, true);
RESET ROLE;
SQL
echo "PASS grants: report_adherence* definer, executable by heart360tk_reader and h360_api, not PUBLIC"

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
    SELECT row(r.*)::text FROM heart360tk_schema.report_adherence('2026-09-01', 0) r
    UNION ALL
    SELECT row(b.*)::text FROM heart360tk_schema.report_adherence_buckets('2026-09-01', 0, true) b
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.8_to_0.6.9 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, thresholds or results" >&2
    exit 1
fi
check_report
check_buckets
echo "PASS second apply is idempotent; fixtures still pass"

echo "adherence verified"
