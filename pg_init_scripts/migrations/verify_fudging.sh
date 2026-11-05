#!/bin/bash
# Verifies 0.6.10_to_0.6.11 (stories 5.2 and 5.3, CR-4): report_fudging and
# report_fudging_histogram against hand-checked fixtures (CLINICAL-RULES section 6
# BP readings cases, plus band edges, window edges, attribution and roll-up), the
# PD-5 wording, thresholds read from report_flag_thresholds, grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   PSQL="docker exec -i postgres psql -U h360tk_root" ./verify_fudging.sh
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION_COMMON="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.10_to_0.6.11.sql"
DB_NAME="${FUDGING_VERIFY_DB:-fudging_verify}"
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

if ! grep -q '\\ir migrations/0.6.10_to_0.6.11.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.10_to_0.6.11.sql" >&2
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
# 0.6.8_to_0.6.9 holds the report common helpers; its adherence functions need the medicine model.
# 0.6.9_to_0.6.10 (titration) is not a dependency of this report and is not applied.
echo "apply 0.6.0_to_0.6.1 (protocol_drugs)"
psql_db < "$MIGRATION_PROTOCOL" >/dev/null
echo "apply 0.6.7_to_0.6.8 (medicine model)"
psql_db < "$MIGRATION_MEDICINE" >/dev/null
echo "apply 0.6.8_to_0.6.9 (report common)"
psql_db < "$MIGRATION_COMMON" >/dev/null
echo "apply 0.6.10_to_0.6.11"
psql_db < "$MIGRATION" >/dev/null

# ---------------------------------------------------------------------------
# Fixture. Month 2026-09: window 2026-07-03 to 2026-09-30. One patient per reading,
# one encounter at 2026-09-01 10:00 with one BP row, unless stated.
#   100 Region > 200 District > 301 Fac A (> 401 Sub A1), 302 Fac B ... 308 Fac H
# CLINICAL-RULES section 6 cases (135-139, 140-144):
#   Fac A (541, 100) -> 5.41 flagged; 41 of the 541 belong to patients under Sub A1.
#         Plus 41 readings outside both bands: 122 x10, 127 x7, 131 x3, 147 x4, 152 x10,
#         and 100 x5, 180 x2 (outside the histogram).
#   Fac B (542, 100) -> 5.42 flagged.     Fac C (200, 100) -> 2.00 flagged.
#   Fac D (199, 100) -> 1.99 not flagged; one 137 reading is an encounter recorded at Fac C
#         by a Fac D patient (attribution follows patients.org_unit_id, A52).
#   Fac E (12, 5)    -> too few, no score. Fac F (25, 0) -> score NULL, flagged.
# Fac G, edges: 134.9 and 145 in no band; 135, 139.9 in 135-139; 140, 144.9 in 140-144;
#   137 at 07-03 00:00 and 09-30 23:30 count; 137 at 07-02 23:59:59 and 142 at 10-01 00:00 do not.
#   -> (4, 2), readings 8, too few.
# Fac H: no readings.
# HTN tab control (heart360tk_reporting.heart360_patients_category, 2026-09, 100 under care):
#   A 70, B 50, C 60, D 80, E 90, F 65; G, H and Sub A1 none.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200), (304, 'Fac D', 3, 200),
    (305, 'Fac E', 3, 200), (306, 'Fac F', 3, 200), (307, 'Fac G', 3, 200), (308, 'Fac H', 3, 200),
    (401, 'Sub A1', 4, 301);

CREATE TEMP TABLE spec (org INT, enc_org INT, ts TIMESTAMP, sys NUMERIC, n INT);
INSERT INTO spec VALUES
    (301, 301, '2026-09-01 10:00', 137, 500), (401, 401, '2026-09-01 10:00', 136, 41),
    (301, 301, '2026-09-01 10:00', 142, 100),
    (301, 301, '2026-09-01 10:00', 122, 10), (301, 301, '2026-09-01 10:00', 127, 7),
    (301, 301, '2026-09-01 10:00', 131, 3),  (301, 301, '2026-09-01 10:00', 147, 4),
    (301, 301, '2026-09-01 10:00', 152, 10), (301, 301, '2026-09-01 10:00', 100, 5),
    (301, 301, '2026-09-01 10:00', 180, 2),
    (302, 302, '2026-09-01 10:00', 138, 542), (302, 302, '2026-09-01 10:00', 141, 100),
    (303, 303, '2026-09-01 10:00', 135, 200), (303, 303, '2026-09-01 10:00', 144, 100),
    (304, 304, '2026-09-01 10:00', 139, 198), (304, 303, '2026-09-01 10:00', 137, 1),
    (304, 304, '2026-09-01 10:00', 140, 100),
    (305, 305, '2026-09-01 10:00', 137, 12),  (305, 305, '2026-09-01 10:00', 142, 5),
    (306, 306, '2026-09-01 10:00', 137, 25),
    (307, 307, '2026-09-01 10:00', 134.9, 1), (307, 307, '2026-09-01 10:00', 135, 1),
    (307, 307, '2026-09-01 10:00', 139.9, 1), (307, 307, '2026-09-01 10:00', 140, 1),
    (307, 307, '2026-09-01 10:00', 144.9, 1), (307, 307, '2026-09-01 10:00', 145, 1),
    (307, 307, '2026-07-03 00:00:00', 137, 1), (307, 307, '2026-09-30 23:30:00', 137, 1),
    (307, 307, '2026-07-02 23:59:59', 137, 1), (307, 307, '2026-10-01 00:00:00', 142, 1);

CREATE TEMP TABLE plan AS
SELECT row_number() OVER (ORDER BY s.org, s.sys, s.ts, g) AS pid, s.org, s.enc_org, s.ts, s.sys
FROM spec s CROSS JOIN LATERAL generate_series(1, s.n) g;

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT pid, 'Fixture ' || pid, 'ALIVE', '2026-01-01', '1960-01-01', org FROM plan;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT pid, pid, ts, enc_org FROM plan;
INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
SELECT pid, sys, 85 FROM plan;
-- a visit without a BP row is not a reading
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id) VALUES (900001, 1, '2026-09-02 10:00', 301);

INSERT INTO heart360tk_reporting.heart360_patients_category
    (ref_month, org_unit_id, total_number_of_patients, nb_patients_newly_registered,
     nb_patients_lost_to_follow_up, nb_patients_controlled, nb_patients_uncontrolled, nb_patients_no_visit)
VALUES
    ('2026-09-01', 301, 100, 0, 0, 70, 30, 0), ('2026-09-01', 302, 100, 0, 0, 50, 50, 0),
    ('2026-09-01', 303, 100, 0, 0, 60, 40, 0), ('2026-09-01', 304, 100, 0, 0, 80, 20, 0),
    ('2026-09-01', 305, 100, 0, 0, 90, 10, 0), ('2026-09-01', 306, 100, 0, 0, 65, 35, 0);
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_fudging: exact rows
# ---------------------------------------------------------------------------
check_report() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (
    call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, level INT, is_selected BOOLEAN,
    too_few BOOLEAN, flag BOOLEAN, flag_reason TEXT,
    readings_n BIGINT, band_135_139_n BIGINT, band_140_144_n BIGINT, score NUMERIC,
    control_pct NUMERIC, looks_fine_check BOOLEAN
);
INSERT INTO expected
SELECT c.call, v.*
FROM (VALUES ('d'), ('a')) c(call)
CROSS JOIN (VALUES
    (1, 200, 'Fixture District', 2, TRUE, FALSE, TRUE,
        '3.74 readings just under 140 for every 1 just over. Check how BP is measured.', 1973::bigint, 1523::bigint, 407::bigint, 3.74, 69.2, TRUE),
    (2, 301, 'Fac A', 3, FALSE, FALSE, TRUE,
        '5.41 readings just under 140 for every 1 just over. Check how BP is measured.', 682, 541, 100, 5.41, 70.0, TRUE),
    (3, 302, 'Fac B', 3, FALSE, FALSE, TRUE,
        '5.42 readings just under 140 for every 1 just over. Check how BP is measured.', 642, 542, 100, 5.42, 50.0, FALSE),
    (4, 303, 'Fac C', 3, FALSE, FALSE, TRUE,
        '2.00 readings just under 140 for every 1 just over. Check how BP is measured.', 300, 200, 100, 2.00, 60.0, TRUE),
    (5, 304, 'Fac D', 3, FALSE, FALSE, FALSE, NULL,                                    299, 199, 100, 1.99, 80.0, FALSE),
    (6, 305, 'Fac E', 3, FALSE, TRUE,  FALSE, NULL,                                    17,  12,  5,   NULL, 90.0, FALSE),
    (7, 306, 'Fac F', 3, FALSE, FALSE, TRUE,
        'No 140-144 readings. Check how BP is measured.',                               25,  25,  0,   NULL, 65.0, TRUE),
    (8, 307, 'Fac G', 3, FALSE, TRUE,  FALSE, NULL,                                    8,   4,   2,   NULL, NULL, FALSE),
    (9, 308, 'Fac H', 3, FALSE, TRUE,  FALSE, NULL,                                    0,   0,   0,   NULL, NULL, FALSE)
) v(ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason,
    readings_n, band_135_139_n, band_140_144_n, score, control_pct, looks_fine_check);
-- All places in view replaces the district as the selection row
UPDATE expected SET org_unit_id = 0, org_unit_name = 'All places in view', level = 0
WHERE call = 'a' AND ord = 1;
INSERT INTO expected VALUES
    ('f', 1, 301, 'Fac A', 3, TRUE, FALSE, TRUE,
        '5.41 readings just under 140 for every 1 just over. Check how BP is measured.', 682, 541, 100, 5.41, 70.0, TRUE),
    ('s', 1, 401, 'Sub A1', 4, TRUE, FALSE, TRUE,
        'No 140-144 readings. Check how BP is measured.', 41, 41, 0, NULL, NULL, FALSE),
    ('h', 1, 308, 'Fac H', 3, TRUE, TRUE, FALSE, NULL, 0, 0, 0, NULL, NULL, FALSE);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_fudging('2026-09-01', 200) r
UNION ALL SELECT 'a',  row_number() OVER (), r.* FROM report_fudging('2026-09-01', 0) r
UNION ALL SELECT 'a0', row_number() OVER (), r.* FROM report_fudging('2026-09-01', NULL) r
UNION ALL SELECT 'f',  row_number() OVER (), r.* FROM report_fudging('2026-09-01', 301) r
UNION ALL SELECT 's',  row_number() OVER (), r.* FROM report_fudging('2026-09-01', 401) r
UNION ALL SELECT 'h',  row_number() OVER (), r.* FROM report_fudging('2026-09-01', 308) r
UNION ALL SELECT 'x',  row_number() OVER (), r.* FROM report_fudging('2026-09-01', 999) r;

DO $$
DECLARE
    v_diff TEXT;
BEGIN
    SELECT string_agg(x::text, E'\n') INTO v_diff
    FROM (
        (SELECT 'missing' AS k, e.* FROM expected e
         EXCEPT ALL
         SELECT 'missing', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few, g.flag,
                g.flag_reason, g.readings_n, g.band_135_139_n, g.band_140_144_n, g.score, g.control_pct, g.looks_fine_check
         FROM got g)
        UNION ALL
        (SELECT 'extra', g.call, g.ord::int, g.org_unit_id, g.org_unit_name, g.level, g.is_selected, g.too_few, g.flag,
                g.flag_reason, g.readings_n, g.band_135_139_n, g.band_140_144_n, g.score, g.control_pct, g.looks_fine_check
         FROM got g WHERE g.call <> 'a0'
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_fudging differs:\n%', v_diff;
    END IF;
    -- scores keep two decimals for display (2.00, not 2)
    IF (SELECT score::text FROM got WHERE call = 'd' AND org_unit_id = 303) <> '2.00' THEN
        RAISE EXCEPTION 'score 2.00 lost its scale';
    END IF;
    -- 0 and NULL give identical rows
    IF EXISTS (
        SELECT ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, readings_n,
               band_135_139_n, band_140_144_n, score, control_pct, looks_fine_check FROM got WHERE call = 'a'
        EXCEPT ALL
        SELECT ord, org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, readings_n,
               band_135_139_n, band_140_144_n, score, control_pct, looks_fine_check FROM got WHERE call = 'a0')
       OR (SELECT count(*) FROM got WHERE call = 'a0') <> 9 THEN
        RAISE EXCEPTION 'report_fudging(0) and (NULL) differ';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE call = 'x') THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;
    -- PD-5 wording: no returned string names the internal report; reasons are 20 words or fewer
    IF EXISTS (SELECT 1 FROM got g WHERE row(g.*)::text ILIKE '%fudg%') THEN
        RAISE EXCEPTION 'a returned string contains fudg';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE array_length(regexp_split_to_array(flag_reason, '\s+'), 1) > 20) THEN
        RAISE EXCEPTION 'a reason is longer than 20 words';
    END IF;
END $$;
SQL
}
check_report
echo "PASS report_fudging rows: 5.41 flagged, 5.42 flagged, 2.00 flagged, 1.99 not, (12,5) too few, (25,0) NULL flagged"
echo "PASS band and window edges, attribution by patient, roll-up, control_pct, looks_fine_check, PD-5 wording"

# ---------------------------------------------------------------------------
# report_fudging_histogram
# ---------------------------------------------------------------------------
check_histogram() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    SELECT string_agg(band_low || '-' || band_high || ':' || readings_n || CASE WHEN highlight THEN '*' ELSE '' END,
                      ' ' ORDER BY band_low) INTO v
    FROM report_fudging_histogram('2026-09-01', 301);
    IF v IS DISTINCT FROM '120-124:10 125-129:7 130-134:3 135-139:541* 140-144:100* 145-149:4 150-154:10' THEN
        RAISE EXCEPTION 'histogram(301) = %', v;
    END IF;

    SELECT string_agg(band_low || '-' || band_high || ':' || readings_n || CASE WHEN highlight THEN '*' ELSE '' END,
                      ' ' ORDER BY band_low) INTO v
    FROM report_fudging_histogram('2026-09-01', 0);
    IF v IS DISTINCT FROM '120-124:10 125-129:7 130-134:4 135-139:1523* 140-144:407* 145-149:5 150-154:10' THEN
        RAISE EXCEPTION 'histogram(0) = %', v;
    END IF;

    -- seven bands 120-124 ... 150-154, highlighted counts equal the report's band counts, for every selection
    IF EXISTS (
        SELECT 1
        FROM unnest(ARRAY[0, 200, 301, 302, 303, 304, 305, 306, 307, 308, 401]) s(org)
        WHERE (SELECT string_agg(band_low || '-' || band_high || CASE WHEN highlight THEN '*' ELSE '' END, ' ' ORDER BY band_low)
               FROM report_fudging_histogram('2026-09-01', s.org))
              IS DISTINCT FROM '120-124 125-129 130-134 135-139* 140-144* 145-149 150-154'
           OR (SELECT readings_n FROM report_fudging_histogram('2026-09-01', s.org) WHERE band_low = 135)
              IS DISTINCT FROM (SELECT band_135_139_n FROM report_fudging('2026-09-01', s.org) WHERE is_selected)
           OR (SELECT readings_n FROM report_fudging_histogram('2026-09-01', s.org) WHERE band_low = 140)
              IS DISTINCT FROM (SELECT band_140_144_n FROM report_fudging('2026-09-01', s.org) WHERE is_selected)
    ) THEN
        RAISE EXCEPTION 'histogram bands or highlighted counts differ from report_fudging';
    END IF;

    -- empty facility: seven zero rows; unknown org unit: no rows
    IF (SELECT string_agg(readings_n::text, ' ' ORDER BY band_low) FROM report_fudging_histogram('2026-09-01', 308))
       IS DISTINCT FROM '0 0 0 0 0 0 0' THEN
        RAISE EXCEPTION 'histogram for an empty facility is wrong';
    END IF;
    IF EXISTS (SELECT 1 FROM report_fudging_histogram('2026-09-01', 999)) THEN
        RAISE EXCEPTION 'histogram for an unknown org unit gave rows';
    END IF;
END $$;
SQL
}
check_histogram
echo "PASS report_fudging_histogram (seven bands 120-124 to 150-154; highlighted counts equal band_135_139_n and band_140_144_n)"

# ---------------------------------------------------------------------------
# Thresholds come from report_flag_thresholds, not literals
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'heart360tk_schema'
          AND p.proname IN ('report_fudging', 'report_fudging_histogram', 'h360_bp_readings')
          AND p.prosrc ~ '(\m(20|60)(\.0+)?\M|\m2\.0)'
    ) THEN
        RAISE EXCEPTION 'a BP readings function holds a threshold literal (20, 60 or 2.0)';
    END IF;

    -- flag_score 5.42: Fac A no longer flagged, Fac B still is. min_readings 17: Fac E (17) gets a score.
    -- high_control_pct 50: Fac B looks fine.
    UPDATE report_flag_thresholds SET value = 5.42 WHERE report = 'fudging' AND key = 'flag_score';
    UPDATE report_flag_thresholds SET value = 17   WHERE report = 'fudging' AND key = 'min_readings';
    UPDATE report_flag_thresholds SET value = 50   WHERE report = 'common'  AND key = 'high_control_pct';
    SELECT string_agg(org_unit_id || ':' || too_few || '/' || flag || '/' || COALESCE(score::text, '-') || '/' || looks_fine_check,
                      ' ' ORDER BY org_unit_id) INTO v
    FROM report_fudging('2026-09-01', 200) WHERE org_unit_id IN (301, 302, 303, 305);
    IF v IS DISTINCT FROM '301:false/false/5.41/false 302:false/true/5.42/true 303:false/false/2.00/false 305:false/false/2.40/false' THEN
        RAISE EXCEPTION 'threshold change not picked up: %', v;
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(report || '.' || key || '=' || value, ',' ORDER BY report, key) FROM heart360tk_schema.report_flag_thresholds WHERE report IN ('fudging', 'common')")" \
      != "common.high_control_pct=60,fudging.flag_score=2.0,fudging.min_readings=20" ]]; then
    echo "FAIL threshold probe was not rolled back" >&2
    exit 1
fi
echo "PASS flags follow report_flag_thresholds (no literals; changed rows change flag, score and looks_fine_check)"

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
      AND p.proname IN ('report_fudging', 'report_fudging_histogram')
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL
       OR (SELECT count(*) FROM pg_proc WHERE proname IN ('report_fudging', 'report_fudging_histogram')) <> 2 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND p.proname = 'h360_bp_readings'
      AND (p.prosecdef
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('h360_api', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'reading-level helper is definer or executable outside heart360tk: %', v_bad;
    END IF;
END $$;

-- h360_api has no table privileges; the definer functions still answer.
SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT score FROM heart360tk_schema.report_fudging('2026-09-01', 0) WHERE is_selected) <> 3.74 THEN
        RAISE EXCEPTION 'h360_api got a different score';
    END IF;
    IF (SELECT count(*) FROM heart360tk_schema.report_fudging_histogram('2026-09-01', 0)) <> 7 THEN
        RAISE EXCEPTION 'h360_api got a different band count';
    END IF;
    BEGIN
        PERFORM * FROM heart360tk_schema.h360_bp_readings('2026-09-01', 0);
        RAISE EXCEPTION 'h360_api executed h360_bp_readings';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_fudging('2026-09-01', 301);
SELECT 1 FROM heart360tk_schema.report_fudging_histogram('2026-09-01', 301);
RESET ROLE;
SQL
echo "PASS grants: report_fudging* definer, executable by heart360tk_reader and h360_api, not PUBLIC; helper not granted"

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
    SELECT row(r.*)::text FROM heart360tk_schema.report_fudging('2026-09-01', 0) r
    UNION ALL
    SELECT row(h.*)::text FROM heart360tk_schema.report_fudging_histogram('2026-09-01', 0) h
    UNION ALL
    SELECT report || '/' || key || '=' || value FROM heart360tk_schema.report_flag_thresholds
) s;
SQL
}
before="$(snapshot)"
echo "apply 0.6.10_to_0.6.11 again"
psql_db < "$MIGRATION" >/dev/null
after="$(snapshot)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL second apply changed functions, grants, thresholds or results" >&2
    exit 1
fi
check_report
check_histogram
echo "PASS second apply is idempotent; fixtures still pass"

echo "BP readings check verified"
