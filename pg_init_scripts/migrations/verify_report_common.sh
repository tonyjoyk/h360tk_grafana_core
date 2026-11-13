#!/bin/bash
# Verifies the report-common part of 0.6.8_to_0.6.9 (story 5.1): report_window,
# report_flag_thresholds (all 30 rows of CLINICAL-RULES section 2), the report row
# helpers, h360_control_summary against the program dashboard's own HTN control query,
# grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_report_common.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
DASHBOARD="$ROOT/grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension-diabetes.program.json"
DB_NAME="${REPORT_COMMON_VERIFY_DB:-report_common_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$TABLES" "$MIGRATION_PROTOCOL" "$MIGRATION_MEDICINE" "$MIGRATION" "$DASHBOARD"; do
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
# report_flag_thresholds: exactly the 30 rows of CLINICAL-RULES section 2
# ---------------------------------------------------------------------------
check_thresholds() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected_thresholds (report TEXT, key TEXT, value NUMERIC);
INSERT INTO expected_thresholds VALUES
    ('common', 'high_control_pct', 60), ('adherence', 'min_cohort', 20),
    ('adherence', 'off_protocol_pct', 20), ('adherence', 'one_medicine_pct', 60),
    ('titration', 'min_visits', 10), ('titration', 'flag_below_pct', 40),
    ('titration', 'next_visit_days', 30), ('titration', 'too_recent_days', 30),
    ('fudging', 'min_readings', 20), ('fudging', 'flag_score', 2.0),
    ('statins', 'min_eligible', 10), ('statins', 'flag_below_pct', 25), ('statins', 'min_age', 40),
    ('calling', 'min_overdue_phone', 10), ('calling', 'overdue_days', 45),
    ('calling', 'called_below_pct', 10), ('calling', 'early_days', 14),
    ('calling', 'early_below_pct', 50), ('calling', 'return_days', 30),
    ('new_patients', 'phone_below_pct', 50),
    ('chat', 'new_loss_above_pct', 25), ('chat', 'usable_phone_below_pct', 90),
    ('chat', 'called_below_pct', 10), ('chat', 'early_below_pct', 50),
    ('chat', 'titration_below_pct', 40), ('chat', 'stock_days_below', 30),
    ('chattogram', 'control_below_pct', 50), ('chattogram', 'uncontrolled_above_pct', 20),
    ('chattogram', 'missed_visit_above_pct', 25), ('chattogram', 'ltfu_above_pct', 20);
DO $$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(format('%s', x), '; ') INTO v_diff FROM (
        (SELECT 'missing' AS k, report, key, value FROM expected_thresholds
         EXCEPT SELECT 'missing', report, key, value FROM report_flag_thresholds)
        UNION ALL
        (SELECT 'extra', report, key, value FROM report_flag_thresholds
         EXCEPT SELECT 'extra', report, key, value FROM expected_thresholds)
    ) x;
    IF v_diff IS NOT NULL OR (SELECT count(*) FROM report_flag_thresholds) <> 30 THEN
        RAISE EXCEPTION 'report_flag_thresholds differs from CLINICAL-RULES section 2: %', v_diff;
    END IF;
    IF h360_threshold('adherence', 'min_cohort') <> 20 THEN
        RAISE EXCEPTION 'h360_threshold(adherence, min_cohort) is wrong';
    END IF;
    BEGIN
        PERFORM h360_threshold('adherence', 'no_such_key');
        RAISE EXCEPTION 'h360_threshold accepted a missing key';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'report_flag_thresholds has no row%' THEN RAISE; END IF;
    END;
END $$;
SQL
}
check_thresholds
echo "PASS report_flag_thresholds holds the 30 CLINICAL-RULES rows"

# ---------------------------------------------------------------------------
# Fixture: a small tree, patients and the reporting table built from the HTN view
#   100 Region (1) > 200 District (2) > 301 Fac A (3) > 401 Sub A1 (4)
#                                     > 302 Fac B (3)
#                                     > 303 Fac C (3, no patients)
# Reference month 2026-09:
#   P1 401 BP 130/80 on 09-10                     controlled
#   P2 401 BP 150/90 on 08-10                     uncontrolled
#   P3 401 BP 120/70 on 05-10                     no visit in 3 months
#   P4 401 visit without BP on 09-20, BP 2025-06  under care by the tab, not in the BP-only count
#   P5 301 registered 2026-08                     newly registered
#   P6 301 last BP 2025-01                        lost to follow-up
#   P7 301 dead                                   excluded
#   P8 302 BP 130/80 on 09-01                     controlled
#   P1 has a later visit on 10-05 (after the window).
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200),
    (302, 'Fac B', 3, 200),
    (303, 'Fac C', 3, 200),
    (401, 'Sub A1', 4, 301);

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id) VALUES
    (1, 'P1', 'ALIVE', '2025-01-15', '1960-01-01', 401),
    (2, 'P2', 'ALIVE', '2025-01-15', '1960-01-01', 401),
    (3, 'P3', 'ALIVE', '2025-01-15', '1960-01-01', 401),
    (4, 'P4', 'ALIVE', '2025-01-15', '1960-01-01', 401),
    (5, 'P5', 'ALIVE', '2026-08-01', '1960-01-01', 301),
    (6, 'P6', 'ALIVE', '2024-06-15', '1960-01-01', 301),
    (7, 'P7', 'DEAD',  '2025-01-15', '1960-01-01', 301),
    (8, 'P8', 'ALIVE', '2025-01-15', '1960-01-01', 302);
INSERT INTO patient_diagnoses (patient_id, diagnosis_code) SELECT g, 'I10' FROM generate_series(1, 8) g;

INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES
    (11, 1, '2026-09-10 10:00', 401),
    (12, 1, '2026-10-05 10:00', 401),
    (21, 2, '2026-08-10 10:00', 401),
    (31, 3, '2026-05-10 10:00', 401),
    (41, 4, '2025-06-01 10:00', 401),
    (42, 4, '2026-09-20 10:00', 401),
    (51, 5, '2026-08-01 10:00', 301),
    (61, 6, '2025-01-01 10:00', 301),
    (71, 7, '2026-09-01 10:00', 301),
    (81, 8, '2026-09-01 10:00', 302);
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp) VALUES
    (11, 130, 80), (12, 125, 80), (21, 150, 90), (31, 120, 70), (41, 130, 80),
    (51, 120, 70), (61, 130, 80), (71, 130, 80), (81, 130, 80);

INSERT INTO heart360tk_reporting.heart360_patients_category
SELECT * FROM heart360tk_schema.heart360_patients_category;
SQL

# ---------------------------------------------------------------------------
# report_window
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    w RECORD;
BEGIN
    SELECT * INTO w FROM report_window('2026-09-01');
    IF (w.window_start, w.window_end, w.data_end) IS DISTINCT FROM ('2026-07-03'::date, '2026-09-30'::date, '2026-09-20'::date) THEN
        RAISE EXCEPTION 'report_window(2026-09-01) = %', w;
    END IF;
    SELECT * INTO w FROM report_window('2026-09-17');
    IF (w.window_start, w.window_end) IS DISTINCT FROM ('2026-07-03'::date, '2026-09-30'::date) THEN
        RAISE EXCEPTION 'report_window(2026-09-17) = %', w;
    END IF;
    SELECT * INTO w FROM report_window('2026-10-01');
    IF (w.window_start, w.window_end, w.data_end) IS DISTINCT FROM ('2026-08-03'::date, '2026-10-31'::date, '2026-10-05'::date) THEN
        RAISE EXCEPTION 'report_window(2026-10-01) = %', w;
    END IF;
    SELECT * INTO w FROM report_window('2028-02-01');
    IF (w.window_start, w.window_end) IS DISTINCT FROM ('2027-12-02'::date, '2028-02-29'::date) THEN
        RAISE EXCEPTION 'report_window(2028-02-01) = %', w;
    END IF;
    SELECT * INTO w FROM report_window('2025-01-01');
    IF w.data_end IS DISTINCT FROM '2025-01-01'::date THEN
        RAISE EXCEPTION 'report_window(2025-01-01) data_end %, expected 2025-01-01', w.data_end;
    END IF;
    SELECT * INTO w FROM report_window('2024-12-01');
    IF w.data_end IS NOT NULL THEN
        RAISE EXCEPTION 'report_window(2024-12-01) data_end % with no encounter on or before window_end', w.data_end;
    END IF;
    SELECT * INTO w FROM report_window(NULL);
    IF w.window_end IS DISTINCT FROM (date_trunc('month', current_date) - interval '1 day')::date
       OR w.window_start IS DISTINCT FROM w.window_end - 89 THEN
        RAISE EXCEPTION 'report_window(NULL) = %, expected the latest completed month', w;
    END IF;
END $$;
SQL
echo "PASS report_window (2026-09 = 2026-07-03 to 2026-09-30, data_end 2026-09-20; NULL = latest completed month)"

# ---------------------------------------------------------------------------
# Report rows and attribution
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(org_unit_id || ':' || org_unit_name || ':' || level || ':' || is_selected, ' | ' ORDER BY row_order) INTO v
    FROM h360_report_units(0);
    IF v IS DISTINCT FROM '0:All places in view:0:true | 301:Fac A:3:false | 302:Fac B:3:false | 303:Fac C:3:false' THEN
        RAISE EXCEPTION 'units(0) = %', v;
    END IF;
    IF (SELECT string_agg(org_unit_id::text, ',' ORDER BY row_order) FROM h360_report_units(NULL)) IS DISTINCT FROM '0,301,302,303' THEN
        RAISE EXCEPTION 'units(NULL) differs from units(0)';
    END IF;
    SELECT string_agg(org_unit_id::text, ',' ORDER BY row_order) INTO v FROM h360_report_units(200);
    IF v IS DISTINCT FROM '200,301,302,303' THEN RAISE EXCEPTION 'units(200) = %', v; END IF;
    SELECT string_agg(org_unit_id::text, ',' ORDER BY row_order) INTO v FROM h360_report_units(301);
    IF v IS DISTINCT FROM '301' THEN RAISE EXCEPTION 'units(301) = %', v; END IF;
    SELECT string_agg(org_unit_id::text, ',' ORDER BY row_order) INTO v FROM h360_report_units(401);
    IF v IS DISTINCT FROM '401' THEN RAISE EXCEPTION 'units(401) = %', v; END IF;
    IF EXISTS (SELECT 1 FROM h360_report_units(999)) OR EXISTS (SELECT 1 FROM h360_report_member(999)) THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;

    -- level 4 rolls up to its facility and to the selection
    SELECT string_agg(report_org_unit_id::text, ',' ORDER BY report_org_unit_id) INTO v
    FROM h360_report_member(200) WHERE member_org_unit_id = 401;
    IF v IS DISTINCT FROM '200,301' THEN RAISE EXCEPTION 'member(200) for 401 = %', v; END IF;
    SELECT string_agg(report_org_unit_id::text, ',' ORDER BY report_org_unit_id) INTO v
    FROM h360_report_member(0) WHERE member_org_unit_id = 401;
    IF v IS DISTINCT FROM '0,301' THEN RAISE EXCEPTION 'member(0) for 401 = %', v; END IF;
    SELECT string_agg(report_org_unit_id::text, ',' ORDER BY report_org_unit_id) INTO v
    FROM h360_report_member(0) WHERE member_org_unit_id = 200;
    IF v IS DISTINCT FROM '0' THEN RAISE EXCEPTION 'member(0) for district 200 = %', v; END IF;
    SELECT string_agg(member_org_unit_id || '>' || report_org_unit_id, ',' ORDER BY member_org_unit_id) INTO v
    FROM h360_report_member(301);
    IF v IS DISTINCT FROM '301>301,401>301' THEN RAISE EXCEPTION 'member(301) = %', v; END IF;
END $$;
SQL
echo "PASS report rows: selection or All places in view (id 0) first, then facilities; level 4 rolls up"

# ---------------------------------------------------------------------------
# h360_control_summary: hand-checked numbers, and the program dashboard's own
# `Hypertension treatment outcomes` query gives the same percentage per node.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    c RECORD;
BEGIN
    SELECT * INTO c FROM h360_control_summary('2026-09-01', 301);
    IF (c.ref_month, c.total_n, c.newly_registered_n, c.ltfu_n, c.under_care_n, c.controlled_n,
        c.uncontrolled_n, c.no_visit_n, c.controlled_pct, c.uncontrolled_pct, c.missed_visit_pct, c.ltfu_pct)
       IS DISTINCT FROM ('2026-09-01'::date, 6::bigint, 1::bigint, 1::bigint, 4::bigint, 1::bigint,
                         1::bigint, 1::bigint, 25.0, 25.0, 25.0, 16.7) THEN
        RAISE EXCEPTION 'control summary 301 = %', c;
    END IF;
    SELECT * INTO c FROM h360_control_summary('2026-09-01', 401);
    IF (c.under_care_n, c.controlled_n, c.controlled_pct) IS DISTINCT FROM (4::bigint, 1::bigint, 25.0) THEN
        RAISE EXCEPTION 'control summary 401 = %', c;
    END IF;
    SELECT * INTO c FROM h360_control_summary('2026-09-01', 200);
    IF (c.total_n, c.under_care_n, c.controlled_n, c.controlled_pct) IS DISTINCT FROM (7::bigint, 5::bigint, 2::bigint, 40.0) THEN
        RAISE EXCEPTION 'control summary 200 = %', c;
    END IF;
    IF (SELECT row(s.*)::text FROM h360_control_summary('2026-09-01', 0) s)
       IS DISTINCT FROM (SELECT row(s.*)::text FROM h360_control_summary('2026-09-01', 200) s)
       OR (SELECT row(s.*)::text FROM h360_control_summary('2026-09-01', NULL) s)
       IS DISTINCT FROM (SELECT row(s.*)::text FROM h360_control_summary('2026-09-01', 200) s) THEN
        RAISE EXCEPTION 'control summary for 0 or NULL differs from the whole tree';
    END IF;
    SELECT * INTO c FROM h360_control_summary('2026-09-01', 303);
    IF (c.under_care_n, c.controlled_n, c.controlled_pct) IS DISTINCT FROM (0::bigint, 0::bigint, NULL::numeric) THEN
        RAISE EXCEPTION 'control summary for an empty facility = %', c;
    END IF;
    -- The tab's denominator counts P4 (visit without BP); the BP-only column does not.
    IF (SELECT sum(nb_patients_under_care_registered_before_the_past_3_months)
        FROM heart360tk_reporting.heart360_patients_category
        WHERE ref_month = '2026-09-01' AND org_unit_id IN (301, 401)) <> 3 THEN
        RAISE EXCEPTION 'fixture no longer separates the two denominators';
    END IF;
END $$;
SQL

TAB_SQL="$(python3 - "$DASHBOARD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
q = d["spec"]["elements"]["panel-outcomes"]["spec"]["data"]["spec"]["queries"][0]["spec"]["query"]
print(q["spec"]["rawSql"])
PY
)"
if [[ "$TAB_SQL" != *"denominator_n"* || "$TAB_SQL" != *"controlled_n"* ]]; then
    echo "FAIL panel-outcomes no longer returns controlled_n and denominator_n" >&2
    exit 1
fi

for node in 0 200 301 302 401; do
    sql="${TAB_SQL//\$\{org_unit\}/$node}"
    sql="${sql//\$\{isAllowed\}/1}"
    tab_pct="$(psql_db -tA <<SQL
SET search_path TO heart360tk_reporting, heart360tk_schema, public;
SELECT COALESCE(round(100.0 * controlled_n / NULLIF(denominator_n, 0), 1)::text, 'NULL')
FROM ( $sql ) tab WHERE ref_month = DATE '2026-09-01';
SQL
)"
    fn_pct="$(psql_db -tA -c "SELECT COALESCE(controlled_pct::text, 'NULL') FROM heart360tk_schema.h360_control_summary('2026-09-01', $node)")"
    if [[ -z "$tab_pct" || "$tab_pct" != "$fn_pct" ]]; then
        echo "FAIL node $node: HTN tab ${tab_pct:-<no row>}%, h360_control_summary $fn_pct%" >&2
        exit 1
    fi
    echo "PASS node $node: h360_control_summary $fn_pct% = HTN tab $tab_pct%"
done

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------
psql_db <<'SQL' >/dev/null
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    -- report_window: definer, executable by the reader and the API, not by PUBLIC
    FOR v_bad IN SELECT unnest(ARRAY['heart360tk_reader', 'h360_api']) LOOP
        IF NOT has_function_privilege(v_bad, 'heart360tk_schema.report_window(date)', 'EXECUTE') THEN
            RAISE EXCEPTION '% cannot execute report_window', v_bad;
        END IF;
    END LOOP;
    IF has_function_privilege('public', 'heart360tk_schema.report_window(date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'PUBLIC can execute report_window';
    END IF;

    -- helpers: invoker, owner only
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema'
      AND p.proname IN ('h360_threshold', 'h360_report_units', 'h360_report_member', 'h360_control_summary')
      AND (p.prosecdef
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'helper is definer or executable outside heart360tk: %', v_bad;
    END IF;

    -- every 0.6.8_to_0.6.9 function: owner heart360tk, STABLE, pinned search_path
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema'
      AND p.proname IN ('report_window', 'h360_threshold', 'h360_report_units', 'h360_report_member', 'h360_control_summary')
      AND (pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR p.provolatile <> 's'
           OR (p.proname = 'report_window') <> p.prosecdef
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'function contract broken for: %', v_bad;
    END IF;

    IF NOT has_table_privilege('heart360tk_reader', 'heart360tk_schema.report_flag_thresholds', 'SELECT')
       OR has_table_privilege('heart360tk_reader', 'heart360tk_schema.report_flag_thresholds', 'INSERT, UPDATE, DELETE, TRUNCATE')
       OR has_table_privilege('h360_api', 'heart360tk_schema.report_flag_thresholds', 'SELECT')
       OR has_table_privilege('public', 'heart360tk_schema.report_flag_thresholds', 'SELECT') THEN
        RAISE EXCEPTION 'report_flag_thresholds grants are wrong';
    END IF;
END $$;

-- As the roles themselves
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_window('2026-09-01');
RESET ROLE;
SET ROLE h360_api;
SELECT 1 FROM heart360tk_schema.report_window('2026-09-01');
DO $$
BEGIN
    PERFORM * FROM heart360tk_schema.h360_control_summary('2026-09-01', 0);
    RAISE EXCEPTION 'h360_api executed h360_control_summary';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;
SQL
echo "PASS grants: report_window for heart360tk_reader and h360_api, not PUBLIC; helpers owner-only"

# ---------------------------------------------------------------------------
# Idempotence: a second apply changes nothing (functions, grants, threshold rows)
# ---------------------------------------------------------------------------
snapshot() {
    psql_db -tA <<'SQL'
SELECT md5(string_agg(x, E'\n' ORDER BY x)) FROM (
    SELECT p.oid::regprocedure::text || pg_get_functiondef(p.oid) || COALESCE(p.proacl::text, '') AS x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND (p.proname LIKE 'report_%' OR p.proname LIKE 'h360_%')
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
    UNION ALL
    SELECT COALESCE(relacl::text, '') FROM pg_class WHERE oid = 'heart360tk_schema.report_flag_thresholds'::regclass
) s;
SQL
}
before="$(snapshot)"
# A tuned threshold survives a re-run.
psql_db -c "SET ROLE heart360tk; UPDATE heart360tk_schema.report_flag_thresholds SET value = 21 WHERE report = 'adherence' AND key = 'min_cohort';" >/dev/null
echo "apply 0.6.8_to_0.6.9 again"
psql_db < "$MIGRATION" >/dev/null
if [[ "$(psql_db -tA -c "SELECT value FROM heart360tk_schema.report_flag_thresholds WHERE report = 'adherence' AND key = 'min_cohort'")" != "21" ]]; then
    echo "FAIL a re-run reset a tuned threshold" >&2
    exit 1
fi
psql_db -c "SET ROLE heart360tk; UPDATE heart360tk_schema.report_flag_thresholds SET value = 20 WHERE report = 'adherence' AND key = 'min_cohort';" >/dev/null
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants or thresholds" >&2
    exit 1
fi
check_thresholds
echo "PASS second apply is idempotent and keeps tuned thresholds"

echo "report common verified"
