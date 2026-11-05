#!/bin/bash
# Verifies 0.6.11_to_0.6.12 (stories 5.8 and 5.9, CR-5): report_statins and
# report_statins_patients against hand-checked fixtures (CLINICAL-RULES section 6
# Statins, plus flag, rounding, too-few and boundary cases), thresholds read from
# report_flag_thresholds, grants (patient list reader-only) and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   PSQL="docker exec -i postgres psql -U h360tk_root" ./verify_statins.sh
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION_COMMON="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.11_to_0.6.12.sql"
DB_NAME="${STATINS_VERIFY_DB:-statins_verify}"
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

if ! grep -q '\\ir migrations/0.6.11_to_0.6.12.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.11_to_0.6.12.sql" >&2
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
echo "apply 0.6.11_to_0.6.12"
psql_db < "$MIGRATION" >/dev/null

# ---------------------------------------------------------------------------
# Fixture. Month 2026-09: window_end 2026-09-30; visit look-back 2025-10-01 to 2026-09-30;
# age 40 means born on or before 1986-09-30.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B, 303 Fac C,
#                               304 Fac D, 305 Fac E, 306 Fac F (no patients)
#
# Fac A (CLINICAL-RULES section 6 Statins, plus boundaries):
#   1  born 1986-10-01 (39), E11, statin                         not eligible (age)
#   2  born 1986-09-30 (40), E11, no statin                      eligible, Diabetes, not on statin
#   3  born 1971-01-01 (55), MI 2025-03-01, no E11, statin       eligible, Heart attack or stroke, on statin
#   4  born 1966-01-01 (60), E11, DEAD, statin                   not eligible (dead)
#   5  born 1960-01-01, E11: atorvastatin 2026-03-01, latest 2026-08-01 without one,
#      and a statin visit 2026-10-05 after window_end            not on statin
#   6  born 1960-01-01, E11 + STROKE 2024-05-01: statin 2026-07-01, then a visit 2026-09-10
#      with no prescriptions row                                 Both, on statin, last visit 09-10
#   7  born 1960-01-01, E11, last visit 2025-09-30               not eligible (no visit in the year)
#   8  born 1960-01-01, E11, one visit 2025-10-01, no prescription row  eligible, not on statin
#   9  born 1960-01-01, MI on 2026-10-15 only                    not eligible (event after window_end)
#   10 birth_date NULL, E11, statin                              not eligible
#   11 born 1980-10-01 (45 on 09-30), STROKE 2020-01-01, under Sub A1, no statin
#                                                                eligible, Heart attack or stroke
#   12 born 1960-01-01, I10 only, no CVD, statin                 not eligible (no risk)
#   -> Fac A: eligible 6 (2, 3, 5, 6, 8, 11), on statin 2, too few.
# Fac B: 100 eligible (E11), 21 on statin -> 21.0%, flagged.
# Fac C: 40 eligible, 10 on statin -> 25.0%, not flagged (boundary).
# Fac D: 10 eligible, 0 on statin -> not too few (10 = minimum), 0.0%, flagged.
# Fac E: 9 eligible, 0 on statin -> too few, not flagged.
# District: 165 eligible, 33 on statin -> 20.0%, flagged.
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

CREATE TEMP TABLE plan (
    pid BIGINT, org INT, status TEXT, birth DATE, dm BOOLEAN, cvd_type TEXT, cvd_date DATE
);
INSERT INTO plan VALUES
    (1,  301, 'ALIVE', '1986-10-01', TRUE,  NULL,     NULL),
    (2,  301, 'ALIVE', '1986-09-30', TRUE,  NULL,     NULL),
    (3,  301, 'ALIVE', '1971-01-01', FALSE, 'MI',     '2025-03-01'),
    (4,  301, 'DEAD',  '1966-01-01', TRUE,  NULL,     NULL),
    (5,  301, 'ALIVE', '1960-01-01', TRUE,  NULL,     NULL),
    (6,  301, 'ALIVE', '1960-01-01', TRUE,  'STROKE', '2024-05-01'),
    (7,  301, 'ALIVE', '1960-01-01', TRUE,  NULL,     NULL),
    (8,  301, 'ALIVE', '1960-01-01', TRUE,  NULL,     NULL),
    (9,  301, 'ALIVE', '1960-01-01', FALSE, 'MI',     '2026-10-15'),
    (10, 301, 'ALIVE', NULL,         TRUE,  NULL,     NULL),
    (11, 401, 'ALIVE', '1980-10-01', FALSE, 'STROKE', '2020-01-01'),
    (12, 301, 'ALIVE', '1960-01-01', FALSE, NULL,     NULL);

-- visits: (pid, ts, statin?) where statin NULL = no prescriptions row
CREATE TEMP TABLE visit (pid BIGINT, ts TIMESTAMP, statin BOOLEAN);
INSERT INTO visit VALUES
    (1,  '2026-09-01 09:00', TRUE),
    (2,  '2026-09-01 09:00', FALSE),
    (3,  '2026-09-01 09:00', TRUE),
    (4,  '2026-09-01 09:00', TRUE),
    (5,  '2026-03-01 09:00', TRUE),
    (5,  '2026-08-01 09:00', FALSE),
    (5,  '2026-10-05 09:00', TRUE),
    (6,  '2026-07-01 09:00', TRUE),
    (6,  '2026-09-10 09:00', NULL),
    (7,  '2025-09-30 09:00', TRUE),
    (8,  '2025-10-01 00:00', NULL),
    (9,  '2026-09-01 09:00', FALSE),
    (10, '2026-09-01 09:00', TRUE),
    (11, '2026-09-30 23:30', FALSE),
    (12, '2026-09-01 09:00', TRUE);

-- Bulk facilities: E11, born 1960-01-01, one visit 2026-09-01; the first k are on a statin.
INSERT INTO plan
SELECT f.base + i, f.org, 'ALIVE', '1960-01-01', TRUE, NULL, NULL
FROM (VALUES (1000, 302, 100), (2000, 303, 40), (3000, 304, 10), (4000, 305, 9)) f(base, org, n)
CROSS JOIN LATERAL generate_series(1, f.n) i;
INSERT INTO visit
SELECT f.base + i, '2026-09-01 09:00', i <= f.k
FROM (VALUES (1000, 100, 21), (2000, 40, 10), (3000, 10, 0), (4000, 9, 0)) f(base, n, k)
CROSS JOIN LATERAL generate_series(1, f.n) i;

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Fixture ' || lpad(pid::text, 4, '0'), status, '2020-01-01', birth, org FROM plan;
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) SELECT pid, 'I10' FROM plan;
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) SELECT pid, 'E11' FROM plan WHERE dm;
INSERT INTO patient_cvd_history (patient_id, event_type, event_date, source)
SELECT pid, cvd_type, cvd_date, 'fixture' FROM plan WHERE cvd_type IS NOT NULL;

CREATE TEMP TABLE enc AS
SELECT row_number() OVER (ORDER BY v.pid, v.ts) AS id, v.pid, v.ts, v.statin, p.org
FROM visit v JOIN plan p USING (pid);
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) SELECT id, pid, ts, org FROM enc;
INSERT INTO prescriptions (encounter_id, obat_raw, source)
SELECT id,
       CASE WHEN statin
            THEN 'Amlodipine 5 mg - 1 x 1 Tablet Sehari; Atorvastatin 20 mg - 1 x 1 Tablet Sehari'
            ELSE 'Amlodipine 5 mg - 1 x 1 Tablet Sehari' END,
       'fixture'
FROM enc WHERE statin IS NOT NULL;

-- The parser agrees with the plan before the report is checked.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM enc e
        WHERE e.statin IS NOT NULL
          AND e.statin IS DISTINCT FROM EXISTS (
              SELECT 1 FROM prescription_lines l JOIN medicines m USING (drug_name)
              WHERE l.encounter_id = e.id AND m.is_statin)
    ) THEN
        RAISE EXCEPTION 'fixture statin lines differ from the plan';
    END IF;
END $$;
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_statins: exact rows
# ---------------------------------------------------------------------------
check_report() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (
    call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, level INT, is_selected BOOLEAN,
    too_few BOOLEAN, flag BOOLEAN, flag_reason TEXT,
    eligible_n BIGINT, on_statin_n BIGINT, on_statin_pct NUMERIC, not_on_statin_n BIGINT
);
INSERT INTO expected VALUES
    ('d', 1, 200, 'Fixture District', 2, TRUE,  FALSE, TRUE,  'Few eligible patients are on a statin: 20.0%.', 165, 33, 20.0, 132),
    ('d', 2, 301, 'Fac A',            3, FALSE, TRUE,  FALSE, NULL, 6,   2,  33.3, 4),
    ('d', 3, 302, 'Fac B',            3, FALSE, FALSE, TRUE,  'Few eligible patients are on a statin: 21.0%.', 100, 21, 21.0, 79),
    ('d', 4, 303, 'Fac C',            3, FALSE, FALSE, FALSE, NULL, 40,  10, 25.0, 30),
    ('d', 5, 304, 'Fac D',            3, FALSE, FALSE, TRUE,  'Few eligible patients are on a statin: 0.0%.', 10, 0, 0.0, 10),
    ('d', 6, 305, 'Fac E',            3, FALSE, TRUE,  FALSE, NULL, 9,   0,  0.0,  9),
    ('d', 7, 306, 'Fac F',            3, FALSE, TRUE,  FALSE, NULL, 0,   0,  NULL, 0),
    ('a', 1, 0,   'All places in view', 0, TRUE, FALSE, TRUE, 'Few eligible patients are on a statin: 20.0%.', 165, 33, 20.0, 132),
    ('a', 2, 301, 'Fac A',            3, FALSE, TRUE,  FALSE, NULL, 6,   2,  33.3, 4),
    ('a', 3, 302, 'Fac B',            3, FALSE, FALSE, TRUE,  'Few eligible patients are on a statin: 21.0%.', 100, 21, 21.0, 79),
    ('a', 4, 303, 'Fac C',            3, FALSE, FALSE, FALSE, NULL, 40,  10, 25.0, 30),
    ('a', 5, 304, 'Fac D',            3, FALSE, FALSE, TRUE,  'Few eligible patients are on a statin: 0.0%.', 10, 0, 0.0, 10),
    ('a', 6, 305, 'Fac E',            3, FALSE, TRUE,  FALSE, NULL, 9,   0,  0.0,  9),
    ('a', 7, 306, 'Fac F',            3, FALSE, TRUE,  FALSE, NULL, 0,   0,  NULL, 0),
    ('f', 1, 301, 'Fac A',            3, TRUE,  TRUE,  FALSE, NULL, 6,   2,  33.3, 4),
    ('s', 1, 401, 'Sub A1',           4, TRUE,  TRUE,  FALSE, NULL, 1,   0,  0.0,  1);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_statins('2026-09-01', 200) r
UNION ALL SELECT 'a',  row_number() OVER (), r.* FROM report_statins('2026-09-01', 0) r
UNION ALL SELECT 'a0', row_number() OVER (), r.* FROM report_statins('2026-09-01', NULL) r
UNION ALL SELECT 'f',  row_number() OVER (), r.* FROM report_statins('2026-09-01', 301) r
UNION ALL SELECT 's',  row_number() OVER (), r.* FROM report_statins('2026-09-01', 401) r
UNION ALL SELECT 'x',  row_number() OVER (), r.* FROM report_statins('2026-09-01', 999) r;

DO $$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(x::text, E'\n') INTO v_diff
    FROM (
        (SELECT 'missing' AS k, e.* FROM expected e
         EXCEPT ALL
         SELECT 'missing', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few,
                g.flag, g.flag_reason, g.eligible_n, g.on_statin_n, g.on_statin_pct, g.not_on_statin_n
         FROM got g)
        UNION ALL
        (SELECT 'extra', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few,
                g.flag, g.flag_reason, g.eligible_n, g.on_statin_n, g.on_statin_pct, g.not_on_statin_n
         FROM got g WHERE g.call IN ('d', 'a', 'f', 's')
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_statins differs:\n%', v_diff;
    END IF;
    IF EXISTS (
        (SELECT ord, org_unit_id, too_few, flag, flag_reason, eligible_n, on_statin_n, on_statin_pct, not_on_statin_n
         FROM got WHERE call = 'a'
         EXCEPT ALL
         SELECT ord, org_unit_id, too_few, flag, flag_reason, eligible_n, on_statin_n, on_statin_pct, not_on_statin_n
         FROM got WHERE call = 'a0')
        UNION ALL
        (SELECT ord, org_unit_id, too_few, flag, flag_reason, eligible_n, on_statin_n, on_statin_pct, not_on_statin_n
         FROM got WHERE call = 'a0'
         EXCEPT ALL
         SELECT ord, org_unit_id, too_few, flag, flag_reason, eligible_n, on_statin_n, on_statin_pct, not_on_statin_n
         FROM got WHERE call = 'a')
    ) THEN
        RAISE EXCEPTION 'report_statins(0) and (NULL) differ';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE call = 'x') THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;
END $$;
SQL
}
check_report
echo "PASS report_statins rows (district, All places in view, facility, sub-facility; flag, boundary, too few)"

# ---------------------------------------------------------------------------
# Eligibility and statin cases (CLINICAL-RULES section 6), through the helper
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(patient_id || ':' || reason_eligible || ':' || age || ':' || last_visit_date || ':' || on_statin,
                      ' ' ORDER BY patient_id) INTO v
    FROM h360_statin_patients('2026-09-01', 301);
    IF v IS DISTINCT FROM concat_ws(' ',
        '2:Diabetes:40:2026-09-01:false',
        '3:Heart attack or stroke:55:2026-09-01:true',
        '5:Diabetes:66:2026-08-01:false',
        '6:Both:66:2026-09-10:true',
        '8:Diabetes:66:2025-10-01:false',
        '11:Heart attack or stroke:45:2026-09-30:false') THEN
        RAISE EXCEPTION E'eligible patients of Fac A =\n%', v;
    END IF;
END $$;
SQL
echo "PASS eligibility: age 39 out, age 40 in, MI without E11 in, dead out, no visit in the year out, event after window_end out"
echo "PASS earlier statin, latest prescription without one: not on a statin (later visit after window_end ignored)"

# ---------------------------------------------------------------------------
# report_statins_patients
# ---------------------------------------------------------------------------
check_patients() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    -- Fac A: exact rows and order (org unit name, then patient name)
    SELECT string_agg(concat_ws('|', patient_id, patient_name, age, reason_eligible, last_visit_date, org_unit_name),
                      E'\n' ORDER BY ord) INTO v
    FROM (SELECT row_number() OVER () AS ord, p.* FROM report_statins_patients('2026-09-01', 301) p) x;
    IF v IS DISTINCT FROM concat_ws(E'\n',
        '2|Fixture 0002|40|Diabetes|2026-09-01|Fac A',
        '5|Fixture 0005|66|Diabetes|2026-08-01|Fac A',
        '8|Fixture 0008|66|Diabetes|2025-10-01|Fac A',
        '11|Fixture 0011|45|Heart attack or stroke|2026-09-30|Sub A1') THEN
        RAISE EXCEPTION E'report_statins_patients(301) =\n%', v;
    END IF;

    -- count equals not_on_statin_n of the selection row, at every level 3 or below
    IF EXISTS (
        SELECT 1 FROM unnest(ARRAY[301, 302, 303, 304, 305, 306, 401]) o
        WHERE (SELECT count(*) FROM report_statins_patients('2026-09-01', o))
              IS DISTINCT FROM (SELECT not_on_statin_n FROM report_statins('2026-09-01', o) WHERE is_selected)
    ) THEN
        RAISE EXCEPTION 'patient list count differs from not_on_statin_n';
    END IF;

    -- above level 3 (region, district, all places), and an unknown id: no rows
    IF EXISTS (SELECT 1 FROM report_statins_patients('2026-09-01', 100))
       OR EXISTS (SELECT 1 FROM report_statins_patients('2026-09-01', 200))
       OR EXISTS (SELECT 1 FROM report_statins_patients('2026-09-01', 0))
       OR EXISTS (SELECT 1 FROM report_statins_patients('2026-09-01', NULL))
       OR EXISTS (SELECT 1 FROM report_statins_patients('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'patient list returned rows above level 3 or for an unknown id';
    END IF;

    -- reason_eligible: exactly the three values, all present
    SELECT string_agg(DISTINCT reason_eligible, ',' ORDER BY reason_eligible) INTO v
    FROM (SELECT reason_eligible FROM report_statins_patients('2026-09-01', 301)
          UNION ALL SELECT reason_eligible FROM report_statins_patients('2026-09-01', 302)
          UNION ALL SELECT s.reason_eligible FROM h360_statin_patients('2026-09-01', 0) s) r;
    IF v IS DISTINCT FROM 'Both,Diabetes,Heart attack or stroke' THEN
        RAISE EXCEPTION 'reason_eligible values = %', v;
    END IF;

    -- column names (CLINICAL-RULES section 1)
    SELECT array_to_string(p.proargnames[3:], ',') INTO v FROM pg_proc p WHERE p.proname = 'report_statins_patients';
    IF v IS DISTINCT FROM 'patient_id,patient_name,age,reason_eligible,last_visit_date,org_unit_name' THEN
        RAISE EXCEPTION 'report_statins_patients columns = %', v;
    END IF;
    SELECT array_to_string(p.proargnames[3:], ',') INTO v FROM pg_proc p WHERE p.proname = 'report_statins';
    IF v IS DISTINCT FROM 'org_unit_id,org_unit_name,level,is_selected,too_few,flag,flag_reason,eligible_n,on_statin_n,on_statin_pct,not_on_statin_n' THEN
        RAISE EXCEPTION 'report_statins columns = %', v;
    END IF;
END $$;
SQL
}
check_patients
echo "PASS report_statins_patients (rows, count = not_on_statin_n, none above level 3, reason values, columns)"

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
          AND p.proname IN ('report_statins', 'report_statins_patients', 'h360_statin_patients')
          AND (p.prosrc ~ '\m(25|40)(\.0+)?\M' OR p.prosrc ~ '[<>=]\s*10\M')
    ) THEN
        RAISE EXCEPTION 'a statins function holds a threshold literal (10, 25 or 40)';
    END IF;

    -- min_eligible 6 and flag line 33.4: Fac A (6 eligible, 33.3%) is no longer too few and flags
    UPDATE report_flag_thresholds SET value = 6 WHERE report = 'statins' AND key = 'min_eligible';
    UPDATE report_flag_thresholds SET value = 33.4 WHERE report = 'statins' AND key = 'flag_below_pct';
    SELECT * INTO r FROM report_statins('2026-09-01', 301);
    IF (r.too_few, r.flag, r.flag_reason) IS DISTINCT FROM
       (FALSE, TRUE, 'Few eligible patients are on a statin: 33.3%.') THEN
        RAISE EXCEPTION 'threshold change not picked up: %', r;
    END IF;
    -- min_age 39: patient 1 (39, on a statin) joins Fac A
    UPDATE report_flag_thresholds SET value = 39 WHERE report = 'statins' AND key = 'min_age';
    SELECT * INTO r FROM report_statins('2026-09-01', 301);
    IF (r.eligible_n, r.on_statin_n) IS DISTINCT FROM (7::bigint, 3::bigint) THEN
        RAISE EXCEPTION 'min_age change not picked up: %', r;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(key || '=' || value, ',' ORDER BY key) FROM heart360tk_schema.report_flag_thresholds WHERE report = 'statins'")" \
      != "flag_below_pct=25,min_age=40,min_eligible=10" ]]; then
    echo "FAIL threshold probe was not rolled back" >&2
    exit 1
fi
echo "PASS flags and age follow report_flag_thresholds (no literals; a changed row changes the result)"

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
      AND p.proname IN ('report_statins', 'report_statins_patients')
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname IN ('report_statins', 'report_statins_patients')) <> 2 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;

    IF NOT has_function_privilege('h360_api', 'heart360tk_schema.report_statins(date, integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'h360_api cannot execute report_statins';
    END IF;
    IF has_function_privilege('h360_api', 'heart360tk_schema.report_statins_patients(date, integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'h360_api can execute report_statins_patients';
    END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND p.proname = 'h360_statin_patients'
      AND (p.prosecdef
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('h360_api', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'patient-level helper is definer or executable outside heart360tk: %', v_bad;
    END IF;
END $$;

SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT eligible_n FROM heart360tk_schema.report_statins('2026-09-01', 0) WHERE is_selected) <> 165 THEN
        RAISE EXCEPTION 'h360_api got a different eligible_n';
    END IF;
    BEGIN
        PERFORM * FROM heart360tk_schema.report_statins_patients('2026-09-01', 301);
        RAISE EXCEPTION 'h360_api executed report_statins_patients';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM * FROM heart360tk_schema.h360_statin_patients('2026-09-01', 301);
        RAISE EXCEPTION 'h360_api executed h360_statin_patients';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
DO $$
BEGIN
    IF (SELECT count(*) FROM heart360tk_schema.report_statins_patients('2026-09-01', 301)) <> 4 THEN
        RAISE EXCEPTION 'heart360tk_reader got a different patient list';
    END IF;
END $$;
RESET ROLE;
SQL
echo "PASS grants: report_statins to reader and h360_api; report_statins_patients reader only (h360_api denied); helper not granted"

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
    SELECT row(r.*)::text FROM heart360tk_schema.report_statins('2026-09-01', 0) r
    UNION ALL
    SELECT row(s.*)::text FROM heart360tk_schema.report_statins_patients('2026-09-01', 301) s
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.11_to_0.6.12 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, thresholds or results" >&2
    exit 1
fi
check_report
check_patients
echo "PASS second apply is idempotent; fixtures still pass"

echo "statins verified"
