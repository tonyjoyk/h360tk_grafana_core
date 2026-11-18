#!/bin/bash
# Verifies the new patients part of 0.6.12_to_0.6.13 (story 5.6, CR-6, A53, A54):
# report_new_patients against hand-checked fixtures (cohort window boundaries, the
# 10-patient loss and usable phone fixture, too_few, the phone flag and its reason),
# thresholds read from report_flag_thresholds, grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_new_patients.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION_COMMON="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.12_to_0.6.13.sql"
DB_NAME="${NEW_PATIENTS_VERIFY_DB:-new_patients_verify}"
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

if ! grep -q '\\ir migrations/0.6.12_to_0.6.13.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.12_to_0.6.13.sql" >&2
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
echo "apply 0.6.0_to_0.6.1, 0.6.7_to_0.6.8, 0.6.8_to_0.6.9 (report common)"
psql_db < "$MIGRATION_PROTOCOL" >/dev/null
psql_db < "$MIGRATION_MEDICINE" >/dev/null
psql_db < "$MIGRATION_COMMON" >/dev/null
echo "apply 0.6.12_to_0.6.13"
psql_db < "$MIGRATION" >/dev/null

# ---------------------------------------------------------------------------
# Fixture. Month 2026-09: window_end 2026-09-30, so the cohort is first encounters in
# 2026-04-04..2026-07-02 inclusive.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B, 303 Fac C, 304 Fac D, 305 Fac E
#
# Fac A (story 5.6): 10 cohort patients, first visit 2026-05-01 09:00.
#   Lost (no encounter in (first, first + 90 days]): N1 (no visit), N2 (07-30 09:01, one minute
#   late), N3 (no visit). N4 comes back at exactly first + 90 days (07-30 09:00) and counts.
#   Phones: N1-N5 10 digits, N6 '+62 812-0000-06'; N7 NULL, N8 '', N9 5 digits,
#   N10 10 digits but marked Wrong phone number. N5 also has an Agreed to visit call.
#   -> loss 30.0%, usable phone 60.0%, not flagged. N1 lives under Sub A1.
#   Not in the cohort: N11 dead; N12 first visit 2026-03-01.
# Fac B: first visits 04-03 23:00 (out), 04-04 00:00 (in), 07-02 23:59 (in), 07-03 00:00 (out).
# Fac C: 25 patients, all back, 11 usable phones -> 44.0%, flagged.
# Fac D: 9 patients, none back, no phones -> too_few, not flagged.
# Fac E: no patients.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200),
    (304, 'Fac D', 3, 200), (305, 'Fac E', 3, 200),
    (401, 'Sub A1', 4, 301);

CREATE TEMP TABLE pt (pid BIGINT, org INT, status TEXT, phone TEXT);
CREATE TEMP TABLE vis (pid BIGINT, ts TIMESTAMP);
CREATE TEMP TABLE cal (pid BIGINT, d DATE, rt TEXT, reason TEXT);

INSERT INTO pt VALUES
    (1, 401, 'ALIVE', '0812000001'), (2, 301, 'ALIVE', '0812000002'), (3, 301, 'ALIVE', '0812000003'),
    (4, 301, 'ALIVE', '0812000004'), (5, 301, 'ALIVE', '0812000005'), (6, 301, 'ALIVE', '+62 812-0000-06'),
    (7, 301, 'ALIVE', NULL), (8, 301, 'ALIVE', ''), (9, 301, 'ALIVE', '12345'),
    (10, 301, 'ALIVE', '0812000010'),
    (11, 301, 'DEAD', '0812000011'), (12, 301, 'ALIVE', '0812000012');
INSERT INTO vis SELECT i, '2026-05-01 09:00'::timestamp FROM generate_series(1, 12) i;
INSERT INTO vis VALUES
    (2, '2026-07-30 09:01'), (4, '2026-07-30 09:00'),
    (5, '2026-06-01 09:00'), (6, '2026-06-01 09:00'), (7, '2026-06-01 09:00'),
    (8, '2026-06-01 09:00'), (9, '2026-06-01 09:00'), (10, '2026-06-01 09:00'),
    (11, '2026-06-01 09:00'), (12, '2026-03-01 09:00');
INSERT INTO cal VALUES
    (10, '2026-08-20', 'removed_from_overdue_list', 'Wrong phone number'),
    (5,  '2026-08-20', NULL, 'Agreed to visit');

INSERT INTO pt VALUES (21, 302, 'ALIVE', NULL), (22, 302, 'ALIVE', NULL), (23, 302, 'ALIVE', NULL), (24, 302, 'ALIVE', NULL);
INSERT INTO vis VALUES (21, '2026-04-03 23:00'), (22, '2026-04-04 00:00'), (23, '2026-07-02 23:59'), (24, '2026-07-03 00:00');

INSERT INTO pt SELECT 100 + i, 303, 'ALIVE', CASE WHEN i <= 11 THEN '08130000' || lpad(i::text, 2, '0') END
FROM generate_series(1, 25) i;
INSERT INTO vis SELECT 100 + i, '2026-05-10 09:00'::timestamp FROM generate_series(1, 25) i
UNION ALL SELECT 100 + i, '2026-06-10 09:00'::timestamp FROM generate_series(1, 25) i;

INSERT INTO pt SELECT 200 + i, 304, 'ALIVE', NULL FROM generate_series(1, 9) i;
INSERT INTO vis SELECT 200 + i, '2026-05-10 09:00'::timestamp FROM generate_series(1, 9) i;

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, phone_number, org_unit_id)
SELECT pid, 'Fixture ' || pid, status, '2025-01-01', '1960-01-01', phone, org FROM pt;
INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
SELECT v.pid, v.ts, pt.org FROM vis v JOIN pt USING (pid);
INSERT INTO call_results (patient_id, call_date, result_type, removed_reason, org_unit_id)
SELECT c.pid, c.d, c.rt, c.reason, pt.org FROM cal c JOIN pt USING (pid);
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_new_patients: exact rows
# ---------------------------------------------------------------------------
COLS="org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, new_patients_n, new_returned_n,
      new_loss_pct, new_usable_phone_n, new_usable_phone_pct"

check_report() {
    psql_db <<SQL
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (
    call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, level INT, is_selected BOOLEAN,
    too_few BOOLEAN, flag BOOLEAN, flag_reason TEXT,
    new_patients_n BIGINT, new_returned_n BIGINT, new_loss_pct NUMERIC, new_usable_phone_n BIGINT, new_usable_phone_pct NUMERIC
);
INSERT INTO expected VALUES
    ('d', 1, 200, 'Fixture District', 2, TRUE,  FALSE, TRUE,  'Few new patients have a usable phone number: 37.0%.', 46, 32, 30.4, 17, 37.0),
    ('d', 2, 301, 'Fac A',            3, FALSE, FALSE, FALSE, NULL, 10, 7,  30.0,  6,  60.0),
    ('d', 3, 302, 'Fac B',            3, FALSE, TRUE,  FALSE, NULL, 2,  0,  100.0, 0,  0.0),
    ('d', 4, 303, 'Fac C',            3, FALSE, FALSE, TRUE,  'Few new patients have a usable phone number: 44.0%.', 25, 25, 0.0, 11, 44.0),
    ('d', 5, 304, 'Fac D',            3, FALSE, TRUE,  FALSE, NULL, 9,  0,  100.0, 0,  0.0),
    ('d', 6, 305, 'Fac E',            3, FALSE, TRUE,  FALSE, NULL, 0,  0,  NULL,  0,  NULL),
    ('f', 1, 301, 'Fac A',            3, TRUE,  FALSE, FALSE, NULL, 10, 7,  30.0,  6,  60.0),
    ('s', 1, 401, 'Sub A1',           4, TRUE,  TRUE,  FALSE, NULL, 1,  0,  100.0, 1,  100.0),
    -- October (window_end 10-31, cohort 05-05..08-02): Fac A's 05-01 patients drop out
    ('o', 1, 301, 'Fac A',            3, TRUE,  TRUE,  FALSE, NULL, 0,  0,  NULL,  0,  NULL),
    ('oc', 1, 303, 'Fac C',           3, TRUE,  FALSE, TRUE,  'Few new patients have a usable phone number: 44.0%.', 25, 25, 0.0, 11, 44.0);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_new_patients('2026-09-01', 200) r
UNION ALL SELECT 'a',  row_number() OVER (), r.* FROM report_new_patients('2026-09-01', 0) r
UNION ALL SELECT 'a0', row_number() OVER (), r.* FROM report_new_patients('2026-09-01', NULL) r
UNION ALL SELECT 'f',  row_number() OVER (), r.* FROM report_new_patients('2026-09-01', 301) r
UNION ALL SELECT 's',  row_number() OVER (), r.* FROM report_new_patients('2026-09-01', 401) r
UNION ALL SELECT 'o',  row_number() OVER (), r.* FROM report_new_patients('2026-10-01', 301) r
UNION ALL SELECT 'oc', row_number() OVER (), r.* FROM report_new_patients('2026-10-01', 303) r
UNION ALL SELECT 'x',  row_number() OVER (), r.* FROM report_new_patients('2026-09-01', 999) r;

DO \$\$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(x::text, E'\n') INTO v_diff
    FROM (
        (SELECT 'missing' AS k, e.* FROM expected e
         EXCEPT ALL
         SELECT 'missing', g.call, g.ord::int, ${COLS} FROM got g)
        UNION ALL
        (SELECT 'extra', g.call, g.ord::int, ${COLS} FROM got g WHERE g.call IN ('d', 'f', 's', 'o', 'oc')
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_new_patients differs:\n%', v_diff;
    END IF;
    IF EXISTS (
        SELECT ord, too_few, flag, flag_reason, new_patients_n, new_returned_n, new_loss_pct, new_usable_phone_n,
               new_usable_phone_pct FROM got WHERE call = 'a'
        EXCEPT ALL
        SELECT ord, too_few, flag, flag_reason, new_patients_n, new_returned_n, new_loss_pct, new_usable_phone_n,
               new_usable_phone_pct FROM got WHERE call = 'd'
    ) OR EXISTS (
        (SELECT ${COLS} FROM got WHERE call = 'a' EXCEPT ALL SELECT ${COLS} FROM got WHERE call = 'a0')
        UNION ALL
        (SELECT ${COLS} FROM got WHERE call = 'a0' EXCEPT ALL SELECT ${COLS} FROM got WHERE call = 'a')
    ) OR (SELECT org_unit_id || '/' || org_unit_name FROM got WHERE call = 'a' AND ord = 1) <> '0/All places in view' THEN
        RAISE EXCEPTION 'report_new_patients(0), (NULL) and the district differ';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE call = 'x') THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;
END \$\$;
SQL
}
check_report
echo "PASS cohort window 2026-04-04..2026-07-02: first visits on 04-03 and 07-03 are outside"
echo "PASS 10-patient fixture: new_loss_pct 30.0, new_usable_phone_pct 60.0, not flagged"
echo "PASS too_few under 10; reason 'Few new patients have a usable phone number: 44.0%.'"

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
          AND p.proname = 'report_new_patients'
          AND p.prosrc ~ '\m(10|50)(\.0+)?\M'
    ) THEN
        RAISE EXCEPTION 'report_new_patients holds a threshold literal (10 or 50)';
    END IF;

    UPDATE report_flag_thresholds SET value = 60.1 WHERE report = 'new_patients' AND key = 'phone_below_pct';
    SELECT * INTO r FROM report_new_patients('2026-09-01', 301);
    IF (r.too_few, r.flag, r.flag_reason) IS DISTINCT FROM
       (FALSE, TRUE, 'Few new patients have a usable phone number: 60.0%.') THEN
        RAISE EXCEPTION 'phone_below_pct change not picked up: %', r;
    END IF;
    UPDATE report_flag_thresholds SET value = 11 WHERE report = 'new_patients' AND key = 'min_patients';
    SELECT * INTO r FROM report_new_patients('2026-09-01', 301);
    IF (r.too_few, r.flag, r.flag_reason) IS DISTINCT FROM (TRUE, FALSE, NULL::text) THEN
        RAISE EXCEPTION 'min_patients change not picked up: %', r;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(key || '=' || value, ',' ORDER BY key) FROM heart360tk_schema.report_flag_thresholds WHERE report = 'new_patients'")" \
      != "min_patients=10,phone_below_pct=50" ]]; then
    echo "FAIL threshold rows are wrong or the probe was not rolled back" >&2
    exit 1
fi
echo "PASS flags follow report_flag_thresholds (no literals; min_patients row seeded at 10)"

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
      AND p.proname = 'report_new_patients'
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname = 'report_new_patients') <> 1 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;
END $$;

SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT new_patients_n FROM heart360tk_schema.report_new_patients('2026-09-01', 0) WHERE is_selected) <> 46 THEN
        RAISE EXCEPTION 'h360_api got a different new_patients_n';
    END IF;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_new_patients('2026-09-01', 301);
RESET ROLE;
SQL
echo "PASS grants: report_new_patients definer, executable by heart360tk_reader and h360_api, not PUBLIC"

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
    SELECT row(r.*)::text FROM heart360tk_schema.report_new_patients('2026-09-01', 0) r
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.12_to_0.6.13 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, thresholds or results" >&2
    exit 1
fi
check_report
echo "PASS second apply is idempotent; fixtures still pass"

echo "new patients verified"
