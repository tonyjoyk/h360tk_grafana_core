#!/bin/bash
# Verifies report_flags from 0.6.13_to_0.6.14 (story 5.10, AD-27, EP-4, EP-13, PD-2):
# exact rows on a fixture with real report functions (facility rows only, the new-patient
# phone flag listed as `calling` and joined to the calling reason, patients_n = under care),
# all five report names through stand-in report functions, stub tolerance (a report replaced
# by a zero-row `h360:stub` function), grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_report_flags.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATIONS="$ROOT/pg_init_scripts/migrations"
# The 01_heart360_tables.sql chain without 0.6.5_to_0.6.6 (roles and grants; the roles are made
# below): drug stock (chat_drug_stock_gate in the same file reads Patient-Days), medicine model,
# report common, the five reports and this migration.
CHAIN=(0.6.0_to_0.6.1 0.6.1_to_0.6.2 0.6.2_to_0.6.3 0.6.3_to_0.6.4 0.6.4_to_0.6.5 0.6.6_to_0.6.7
       0.6.7_to_0.6.8 0.6.8_to_0.6.9 0.6.9_to_0.6.10 0.6.10_to_0.6.11 0.6.11_to_0.6.12
       0.6.12_to_0.6.13 0.6.13_to_0.6.14)
MIGRATION="$MIGRATIONS/0.6.13_to_0.6.14.sql"
DB_NAME="${REPORT_FLAGS_VERIFY_DB:-report_flags_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$TABLES" "${CHAIN[@]/#/$MIGRATIONS/}"; do
    [[ "$required" == *.sql ]] || required="$required.sql"
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

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
# Fixture. Month 2026-09: window 2026-07-03..2026-09-30; new-patient cohort first visit in
# 2026-04-04..2026-07-02; overdue cut-off 07-18.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B, 303 Fac C
# Fac A: BP readings 137 x30 and 142 x5 on 09-01 (Sub A1: 137 x20, 142 x2) -> fudging score 6.00
#        flagged (Sub A1 alone 10.00); 5 high BP visits, titration too few.
# Fac B: 25 overdue with a phone (last visit 06-01), one called late on 09-05 -> called 4.0% and
#        early 0.0%, both flagged; 26 more without a phone, also first seen 06-01 -> 51 new patients,
#        25 with a usable phone = 49.0% flagged (new-patient phone flag, listed under `calling`, its
#        reason joined after the calling reasons).
# Fac C: nothing.
# HTN tab (heart360_patients_category 2026-09): Fac A 80 + Sub A1 20 under care; Fac B 50 total,
#        5 newly registered -> 45 under care; Fac C no rows -> 0.
# The district row is flagged on fudging and calling but report_flags lists facilities only.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200),
    (401, 'Sub A1', 4, 301);

CREATE TEMP TABLE spec (org INT, sys NUMERIC, n INT);
INSERT INTO spec VALUES (301, 137, 10), (301, 142, 3), (401, 137, 20), (401, 142, 2);
CREATE TEMP TABLE plan AS
SELECT row_number() OVER (ORDER BY s.org, s.sys, g) AS pid, s.org, s.sys
FROM spec s CROSS JOIN LATERAL generate_series(1, s.n) g;

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Fixture ' || pid, 'ALIVE', '2026-01-01', '1960-01-01', org FROM plan;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT pid, pid, '2026-09-01 10:00', org FROM plan;
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
SELECT pid, sys, 85 FROM plan;

-- Fac B: 25 with a phone (1001-1025), 26 without (1026-1051)
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, phone_number, org_unit_id)
SELECT 1000 + i, 'Fixture ' || (1000 + i), 'ALIVE', '2026-06-01', '1960-01-01',
       CASE WHEN i <= 25 THEN '08120000' || lpad(i::text, 2, '0') END, 302
FROM generate_series(1, 51) i;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT 1000 + i, 1000 + i, '2026-06-01 09:00', 302 FROM generate_series(1, 51) i;
INSERT INTO call_results (patient_id, call_date, result_type, removed_reason, org_unit_id)
VALUES (1001, '2026-09-05', NULL, 'Agreed to visit', 302);

INSERT INTO heart360tk_reporting.heart360_patients_category
    (ref_month, org_unit_id, total_number_of_patients, nb_patients_newly_registered,
     nb_patients_lost_to_follow_up, nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit)
VALUES
    ('2026-09-01', 301, 80, 0, 0, 56, 24, 0), ('2026-09-01', 401, 20, 0, 0, 14, 6, 0),
    ('2026-09-01', 302, 50, 5, 0, 20, 25, 0);
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_flags: exact rows on the real reports
# ---------------------------------------------------------------------------
check_flags() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, report TEXT,
                            flag_reason TEXT, patients_n BIGINT);
INSERT INTO expected VALUES
    ('d', 1, 301, 'Fac A',  'fudging',
         '6.00 readings just under 140 for every 1 just over. Check how BP is measured.', 100),
    ('d', 2, 302, 'Fac B',  'calling',
         'Few overdue patients are called: 4.0%. Most calls are late: 0.0% within 14 days. Few new patients have a usable phone number: 49.0%.', 45),
    ('a', 1, 301, 'Fac A',  'fudging',
         '6.00 readings just under 140 for every 1 just over. Check how BP is measured.', 100),
    ('a', 2, 302, 'Fac B',  'calling',
         'Few overdue patients are called: 4.0%. Most calls are late: 0.0% within 14 days. Few new patients have a usable phone number: 49.0%.', 45),
    ('n', 1, 301, 'Fac A',  'fudging',
         '6.00 readings just under 140 for every 1 just over. Check how BP is measured.', 100),
    ('n', 2, 302, 'Fac B',  'calling',
         'Few overdue patients are called: 4.0%. Most calls are late: 0.0% within 14 days. Few new patients have a usable phone number: 49.0%.', 45),
    ('f', 1, 301, 'Fac A',  'fudging',
         '6.00 readings just under 140 for every 1 just over. Check how BP is measured.', 100),
    ('s', 1, 401, 'Sub A1', 'fudging',
         '10.00 readings just under 140 for every 1 just over. Check how BP is measured.', 20),
    ('b', 1, 302, 'Fac B',  'calling',
         'Few overdue patients are called: 4.0%. Most calls are late: 0.0% within 14 days. Few new patients have a usable phone number: 49.0%.', 45);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_flags('2026-09-01', 200) r
UNION ALL SELECT 'a', row_number() OVER (), r.* FROM report_flags('2026-09-01', 0) r
UNION ALL SELECT 'n', row_number() OVER (), r.* FROM report_flags('2026-09-01', NULL) r
UNION ALL SELECT 'f', row_number() OVER (), r.* FROM report_flags('2026-09-01', 301) r
UNION ALL SELECT 's', row_number() OVER (), r.* FROM report_flags('2026-09-01', 401) r
UNION ALL SELECT 'b', row_number() OVER (), r.* FROM report_flags('2026-09-01', 302) r
UNION ALL SELECT 'c', row_number() OVER (), r.* FROM report_flags('2026-09-01', 303) r
UNION ALL SELECT 'x', row_number() OVER (), r.* FROM report_flags('2026-09-01', 999) r;

DO $$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(x::text, E'\n') INTO v_diff
    FROM (
        (SELECT 'missing' AS k, e.* FROM expected e
         EXCEPT ALL
         SELECT 'missing', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.report, g.flag_reason, g.patients_n FROM got g)
        UNION ALL
        (SELECT 'extra', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.report, g.flag_reason, g.patients_n FROM got g
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_flags differs:\n%', v_diff;
    END IF;
    -- the district row is flagged on two reports in the tabs, and is left out here
    IF (SELECT count(*) FROM report_fudging('2026-09-01', 200) WHERE is_selected AND flag) <> 1
       OR (SELECT count(*) FROM report_calling('2026-09-01', 200) WHERE is_selected AND flag) <> 1 THEN
        RAISE EXCEPTION 'fixture assumption changed: the district row should be flagged';
    END IF;
END $$;
SQL
}
check_flags
echo "PASS report_flags rows: facility rows only, Fac A fudging, Fac B calling + new-patient phone joined, patients_n"

# ---------------------------------------------------------------------------
# All five report names, through stand-in report functions (rolled back)
# Each stand-in flags the district (left out) and a facility; adherence also flags Fac A with an
# unflagged twin row; statins flags Fac C; calling and new patients both flag Fac B.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
BEGIN;
SET LOCAL ROLE heart360tk;
CREATE OR REPLACE FUNCTION report_adherence(p_reporting_month date, p_org_unit_id integer, p_include_new boolean DEFAULT false)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, flag boolean,
               flag_reason text, cohort_n bigint, controlled_n bigint, controlled_pct numeric, off_protocol_pct numeric,
               one_medicine_pct numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = heart360tk_schema, pg_temp SET jit = off AS $f$
    VALUES (200, 'Fixture District'::text, 2, TRUE, FALSE, TRUE, 'adh D'::text, 0::bigint, 0::bigint, NULL::numeric, NULL::numeric, NULL::numeric),
           (301, 'Fac A', 3, FALSE, FALSE, TRUE, 'adh A', 0, 0, NULL, NULL, NULL),
           (302, 'Fac B', 3, FALSE, FALSE, FALSE, NULL, 0, 0, NULL, NULL, NULL);
$f$;
CREATE OR REPLACE FUNCTION report_titration(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, flag boolean,
               flag_reason text, uncontrolled_visits_n bigint, stepped_up_n bigint, titration_pct numeric,
               excluded_too_recent_n bigint, excluded_no_baseline_n bigint, control_pct numeric, looks_fine_check boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = heart360tk_schema, pg_temp SET jit = off AS $f$
    VALUES (200, 'Fixture District'::text, 2, TRUE, FALSE, TRUE, 'tit D'::text, 0::bigint, 0::bigint, NULL::numeric, 0::bigint, 0::bigint, NULL::numeric, FALSE),
           (301, 'Fac A', 3, FALSE, FALSE, TRUE, 'tit A', 0, 0, NULL, 0, 0, NULL, FALSE);
$f$;
CREATE OR REPLACE FUNCTION report_statins(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, flag boolean,
               flag_reason text, eligible_n bigint, on_statin_n bigint, on_statin_pct numeric, not_on_statin_n bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = heart360tk_schema, pg_temp SET jit = off AS $f$
    VALUES (303, 'Fac C'::text, 3, FALSE, FALSE, TRUE, 'sta C'::text, 0::bigint, 0::bigint, NULL::numeric, 0::bigint);
$f$;
-- report_fudging, report_calling and report_new_patients stay real (Fac A fudging, Fac B calling + phone)

CREATE TEMP TABLE got5 AS SELECT row_number() OVER () AS ord, r.* FROM report_flags('2026-09-01', 200) r;
DO $$
DECLARE
    v_got TEXT;
BEGIN
    SELECT string_agg(org_unit_name || ':' || report || ':' || left(flag_reason, 5) || ':' || patients_n, ' | ' ORDER BY ord)
    INTO v_got FROM got5;
    IF v_got IS DISTINCT FROM
       'Fac A:adherence:adh A:100 | Fac A:titration:tit A:100 | Fac A:fudging:6.00 :100 | Fac B:calling:Few o:45 | Fac C:statins:sta C:0' THEN
        RAISE EXCEPTION 'five-report union differs: %', v_got;
    END IF;
END $$;

-- Stub rule (PD-2): report_statins cut to a zero-row stub with the h360:stub comment
CREATE OR REPLACE FUNCTION report_statins(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, too_few boolean, flag boolean,
               flag_reason text, eligible_n bigint, on_statin_n bigint, on_statin_pct numeric, not_on_statin_n bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = heart360tk_schema, pg_temp SET jit = off AS $f$
    SELECT NULL::integer, NULL::text, NULL::integer, NULL::boolean, NULL::boolean, NULL::boolean, NULL::text,
           NULL::bigint, NULL::bigint, NULL::numeric, NULL::bigint
    WHERE FALSE;
$f$;
COMMENT ON FUNCTION report_statins(date, integer) IS 'h360:stub';
DO $$
DECLARE
    v_got TEXT;
BEGIN
    SELECT string_agg(org_unit_name || ':' || report, ' | ' ORDER BY ord) INTO v_got
    FROM (SELECT row_number() OVER () AS ord, r.* FROM report_flags('2026-09-01', 200) r) s;
    IF v_got IS DISTINCT FROM 'Fac A:adherence | Fac A:titration | Fac A:fudging | Fac B:calling' THEN
        RAISE EXCEPTION 'statins stub: report_flags differs: %', v_got;
    END IF;
END $$;
ROLLBACK;
SQL
echo "PASS all five report names (adherence, titration, fudging, statins, calling) in report order; district rows left out"
echo "PASS stub tolerance: report_statins as a zero-row h360:stub drops only its own flags"

# ---------------------------------------------------------------------------
# Stub tolerance on the real data: report_fudging cut to a stub (rolled back)
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
BEGIN;
SET LOCAL ROLE heart360tk;
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
    SELECT string_agg(org_unit_name || ':' || report || ':' || patients_n, ' | ') INTO v_got
    FROM report_flags('2026-09-01', 200);
    IF v_got IS DISTINCT FROM 'Fac B:calling:45' THEN
        RAISE EXCEPTION 'fudging stub: report_flags differs: %', v_got;
    END IF;
    IF EXISTS (SELECT 1 FROM report_flags('2026-09-01', 301)) THEN
        RAISE EXCEPTION 'fudging stub: Fac A still flagged';
    END IF;
END $$;
ROLLBACK;
SQL
check_flags >/dev/null
echo "PASS stub tolerance on real data: report_fudging as a stub leaves Fac B calling; rollback restores Fac A"

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
      AND p.proname = 'report_flags'
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname = 'report_flags') <> 1 THEN
        RAISE EXCEPTION 'report_flags contract broken for: %', v_bad;
    END IF;
    IF pg_get_function_result('heart360tk_schema.report_flags(date, integer)'::regprocedure)
       <> 'TABLE(org_unit_id integer, org_unit_name text, report text, flag_reason text, patients_n bigint)' THEN
        RAISE EXCEPTION 'report_flags columns changed';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'report_flags' AND obj_description(oid, 'pg_proc') = 'h360:stub') THEN
        RAISE EXCEPTION 'report_flags is marked as a stub';
    END IF;
END $$;

-- h360_api and heart360tk_reader have no table privileges here; the definer function still answers.
SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT count(*) FROM heart360tk_schema.report_flags('2026-09-01', 200)) <> 2 THEN
        RAISE EXCEPTION 'h360_api got different report_flags rows';
    END IF;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
DO $$
BEGIN
    IF (SELECT count(*) FROM heart360tk_schema.report_flags('2026-09-01', 0)) <> 2 THEN
        RAISE EXCEPTION 'heart360tk_reader got different report_flags rows';
    END IF;
END $$;
RESET ROLE;
SET ROLE heart360tk_cached;
DO $$
BEGIN
    PERFORM * FROM heart360tk_schema.report_flags('2026-09-01', 0);
    RAISE EXCEPTION 'heart360tk_cached executed report_flags';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;
SQL
echo "PASS grants: report_flags definer, executable by heart360tk_reader and h360_api, not PUBLIC or heart360tk_cached"

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
    UNION ALL
    SELECT row(r.*)::text FROM heart360tk_schema.report_flags('2026-09-01', 0) r
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
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
check_flags >/dev/null
echo "PASS second apply is idempotent; fixtures still pass"

echo "report_flags verified"
