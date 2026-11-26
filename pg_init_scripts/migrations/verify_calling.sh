#!/bin/bash
# Verifies the overdue calling part of 0.6.12_to_0.6.13 (story 5.5, CR-6):
# report_calling against hand-checked fixtures (CLINICAL-RULES section 6 Overdue calling
# C1-C5, plus flag, reason, phone, Pending, Died, removal, boundary, return and
# calls_per_week cases), called_n against HEART360_OVERDUE_PATIENTS_CALLED, thresholds read
# from report_flag_thresholds, grants and idempotence.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_calling.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION_MEDICINE="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
MIGRATION_COMMON="$ROOT/pg_init_scripts/migrations/0.6.8_to_0.6.9.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.12_to_0.6.13.sql"
DB_NAME="${CALLING_VERIFY_DB:-calling_verify}"
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
# Fixture. Month 2026-09: M = 09-01..09-30, overdue cut-off 07-18 (last visit before it),
# window 2026-07-03..2026-09-30. A filler visit on 2026-10-31 (Fac E) is the newest
# encounter in the database, so every call up to 10-01 has a known return.
#   100 Region > 200 District > 301 Fac C (> 401 Sub C1), 302 Fac B, 303 Fac L, 304 Fac D, 305 Fac E
# Phones are 10 digits unless stated.
#
# Fac C (CLINICAL-RULES section 6, C1-C5): overdue 3, called 2, 66.7%, early 50.0%,
#   returned 1 of 2 known, too_few. C1 lives under Sub C1.
# Fac B: 25 overdue; one called early (09-05, 7 days) -> called 4.0%, flagged
#   `Few overdue patients are called: 4.0%.`; calls_per_week ceil(25/4) = 7.
# Fac L: 25 overdue with a phone and 2 without (blank, 7 digits); all 25 called on 09-05,
#   8 early (Agreed), 10 late Call again later, 7 late removed (Wrong phone number) ->
#   early 32.0%, flagged `Most calls are late: 32.0% within 14 days.` Returns: 4 of 8 early
#   and 1 of 10 later came back; removed calls are left out of the return measures.
# Fac D: edge cases (see the plan rows).
# Fac E: the filler patient only.
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac C', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac L', 3, 200),
    (304, 'Fac D', 3, 200), (305, 'Fac E', 3, 200),
    (401, 'Sub C1', 4, 301);

CREATE TEMP TABLE pt (pid BIGINT, org INT, status TEXT, phone TEXT);
CREATE TEMP TABLE vis (pid BIGINT, ts TIMESTAMP);
CREATE TEMP TABLE cal (pid BIGINT, d DATE, rt TEXT, reason TEXT);

-- Fac C: CLINICAL-RULES C1-C5
INSERT INTO pt VALUES
    (1, 401, 'ALIVE', '0812345601'), (2, 301, 'ALIVE', '0812345602'), (3, 301, 'ALIVE', '0812345603'),
    (4, 301, 'ALIVE', '0812345604'), (5, 301, 'ALIVE', '0812345605');
INSERT INTO vis VALUES
    (1, '2026-07-10 09:00'), (1, '2026-09-20 09:00'),
    (2, '2026-07-01 09:00'),
    (3, '2026-07-05 09:00'),
    (4, '2026-07-20 09:00'),
    (5, '2026-06-01 09:00');
INSERT INTO cal VALUES
    (1, '2026-09-02', NULL, 'Agreed to visit'),
    (2, '2026-09-05', NULL, 'Call again later'),
    (3, '2026-09-03', NULL, 'Pending to call'),
    (5, '2026-08-01', 'removed_from_overdue_list', 'Moved out of catchment area');

-- Fac B: 1 early call among 25 overdue
INSERT INTO pt SELECT 1000 + i, 302, 'ALIVE', '08120000' || lpad(i::text, 2, '0') FROM generate_series(1, 25) i;
INSERT INTO vis SELECT 1000 + i, CASE WHEN i = 1 THEN '2026-07-15 09:00' ELSE '2026-06-01 09:00' END::timestamp
FROM generate_series(1, 25) i;
INSERT INTO cal VALUES (1001, '2026-09-05', NULL, 'Agreed to visit');

-- Fac L: 25 called, 8 early; 2 overdue without a usable phone
INSERT INTO pt SELECT 2000 + i, 303, 'ALIVE', '08130000' || lpad(i::text, 2, '0') FROM generate_series(1, 25) i;
INSERT INTO pt VALUES (2026, 303, 'ALIVE', NULL), (2027, 303, 'ALIVE', '081-2345');
INSERT INTO vis SELECT 2000 + i, CASE WHEN i <= 8 THEN '2026-07-15 09:00' ELSE '2026-06-01 09:00' END::timestamp
FROM generate_series(1, 27) i;
INSERT INTO cal
SELECT 2000 + i, '2026-09-05',
       CASE WHEN i > 18 THEN 'removed_from_overdue_list' END,
       CASE WHEN i <= 8 THEN 'Agreed to visit' WHEN i <= 18 THEN 'Call again later' ELSE 'Wrong phone number' END
FROM generate_series(1, 25) i;
-- returns: early 2001-2004 on 09-15; later 2009 on 10-05 (the last day of [09-05, 09-05 + 30]);
-- later 2010 on 10-06 (one day too late); removed 2019 on 09-10 (not counted)
INSERT INTO vis VALUES
    (2001, '2026-09-15 09:00'), (2002, '2026-09-15 09:00'), (2003, '2026-09-15 09:00'), (2004, '2026-09-15 09:00'),
    (2009, '2026-10-05 23:00'), (2010, '2026-10-06 00:00'), (2019, '2026-09-10 09:00');

-- Fac D: edge cases
--   3001 last 06-01; Pending 09-02 then Agreed 09-10 -> called on 09-10 (late), no return
--   3002 last 06-01; first September row is removed/Died 09-03, Agreed 09-12 -> not called
--   3003 dead, last 06-01 -> not overdue
--   3004 last 06-01; removed Wrong phone number 08-10 -> not overdue in September; its August
--        call is removed, so it is left out of the return measures
--   3006 last 2026-07-17 23:00 -> overdue (before 07-18); no call
--   3007 last 2026-07-18 00:00 -> not overdue
--   3008 last 06-01; Call again later 08-20 (August first call, late, known, no return) -> overdue
--   3009 last 08-01 -> not overdue in September; called 10-15 (October, return not yet known)
--   3010 last 06-01; Agreed 09-12, visit 10-05 -> returned, later
--   3011 last 06-01; Pending 09-04 only, and Agreed 2026-08-25 in August -> overdue, not called in
--        September; its August call is a known return with no visit
INSERT INTO pt VALUES
    (3001, 304, 'ALIVE', '0814000001'), (3002, 304, 'ALIVE', '0814000002'), (3003, 304, 'DEAD', '0814000003'),
    (3004, 304, 'ALIVE', '0814000004'), (3006, 304, 'ALIVE', '0814000006'), (3007, 304, 'ALIVE', '0814000007'),
    (3008, 304, 'ALIVE', '0814000008'), (3009, 304, 'ALIVE', '0814000009'), (3010, 304, 'ALIVE', '0814000010'),
    (3011, 304, 'ALIVE', '0814000011');
INSERT INTO vis VALUES
    (3001, '2026-06-01 09:00'), (3002, '2026-06-01 09:00'), (3003, '2026-06-01 09:00'), (3004, '2026-06-01 09:00'),
    (3006, '2026-07-17 23:00'), (3007, '2026-07-18 00:00'), (3008, '2026-06-01 09:00'), (3009, '2026-08-01 09:00'),
    (3010, '2026-06-01 09:00'), (3010, '2026-10-05 09:00'), (3011, '2026-06-01 09:00');
INSERT INTO cal VALUES
    (3001, '2026-09-02', NULL, 'Pending to call'), (3001, '2026-09-10', NULL, 'Agreed to visit'),
    (3002, '2026-09-03', 'removed_from_overdue_list', 'Died'), (3002, '2026-09-12', NULL, 'Agreed to visit'),
    (3004, '2026-08-10', 'removed_from_overdue_list', 'Wrong phone number'),
    (3008, '2026-08-20', NULL, 'Call again later'),
    (3009, '2026-10-15', NULL, 'Agreed to visit'),
    (3010, '2026-09-12', NULL, 'Agreed to visit'),
    (3011, '2026-08-25', NULL, 'Agreed to visit'), (3011, '2026-09-04', NULL, 'Pending to call');

-- Fac E: filler, the newest encounter in the database
INSERT INTO pt VALUES (9001, 305, 'ALIVE', '0819000001');
INSERT INTO vis VALUES (9001, '2026-10-31 10:00');

INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, phone_number, org_unit_id)
SELECT pid, 'Fixture ' || pid, status, '2025-01-01', '1960-01-01', phone, org FROM pt;
INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
SELECT v.pid, v.ts, pt.org FROM vis v JOIN pt USING (pid);
INSERT INTO call_results (patient_id, call_date, result_type, removed_reason, org_unit_id)
SELECT c.pid, c.d, c.rt, c.reason, pt.org FROM cal c JOIN pt USING (pid);
SQL
echo "fixture loaded"

# ---------------------------------------------------------------------------
# report_calling: exact rows
# ---------------------------------------------------------------------------
COLS="org_unit_id, org_unit_name, level, is_selected, too_few, flag, flag_reason, overdue_n, overdue_with_phone_n,
      called_n, called_pct, early_n, early_pct, agreed_n, call_again_n, removed_n, return_known_n, returned_n,
      returned_pct, returned_early_pct, returned_later_pct, return_not_yet_known_n, calls_per_week"

check_report() {
    psql_db <<SQL
SET search_path TO heart360tk_schema;
CREATE TEMP TABLE expected (
    call TEXT, ord INT, org_unit_id INT, org_unit_name TEXT, level INT, is_selected BOOLEAN,
    too_few BOOLEAN, flag BOOLEAN, flag_reason TEXT,
    overdue_n BIGINT, overdue_with_phone_n BIGINT, called_n BIGINT, called_pct NUMERIC, early_n BIGINT, early_pct NUMERIC,
    agreed_n BIGINT, call_again_n BIGINT, removed_n BIGINT, return_known_n BIGINT, returned_n BIGINT,
    returned_pct NUMERIC, returned_early_pct NUMERIC, returned_later_pct NUMERIC, return_not_yet_known_n BIGINT,
    calls_per_week BIGINT
);
INSERT INTO expected VALUES
    -- district
    ('d', 1, 200, 'Fixture District', 2, TRUE,  FALSE, TRUE, 'Most calls are late: 33.3% within 14 days.',
         61, 59, 30, 50.8, 10, 33.3, 12, 11, 7, 25, 7, 28.0, 50.0, 13.3, 0, 15),
    ('d', 2, 302, 'Fac B',            3, FALSE, FALSE, TRUE, 'Few overdue patients are called: 4.0%.',
         25, 25, 1, 4.0, 1, 100.0, 1, 0, 0, 1, 0, 0.0, 0.0, NULL, 0, 7),
    ('d', 3, 301, 'Fac C',            3, FALSE, TRUE,  FALSE, NULL,
         3, 3, 2, 66.7, 1, 50.0, 1, 1, 0, 2, 1, 50.0, 100.0, 0.0, 0, 1),
    ('d', 4, 304, 'Fac D',            3, FALSE, TRUE,  FALSE, NULL,
         6, 6, 2, 33.3, 0, 0.0, 2, 0, 0, 4, 1, 25.0, NULL, 25.0, 0, 2),
    ('d', 5, 305, 'Fac E',            3, FALSE, TRUE,  FALSE, NULL,
         0, 0, 0, NULL, 0, NULL, 0, 0, 0, 0, 0, NULL, NULL, NULL, 0, 0),
    ('d', 6, 303, 'Fac L',            3, FALSE, FALSE, TRUE, 'Most calls are late: 32.0% within 14 days.',
         27, 25, 25, 100.0, 8, 32.0, 8, 10, 7, 18, 5, 27.8, 50.0, 10.0, 0, 7),
    -- facility selection (one row), sub-facility selection (C1 only)
    ('f', 1, 301, 'Fac C',            3, TRUE,  TRUE,  FALSE, NULL,
         3, 3, 2, 66.7, 1, 50.0, 1, 1, 0, 2, 1, 50.0, 100.0, 0.0, 0, 1),
    ('s', 1, 401, 'Sub C1',           4, TRUE,  TRUE,  FALSE, NULL,
         1, 1, 1, 100.0, 1, 100.0, 1, 0, 0, 1, 1, 100.0, 100.0, NULL, 0, 1),
    -- October at Fac D: window 08-03..10-31; 3009's 10-15 call is not yet known
    ('o', 1, 304, 'Fac D',            3, TRUE,  TRUE,  FALSE, NULL,
         8, 8, 1, 12.5, 0, 0.0, 1, 0, 0, 4, 1, 25.0, NULL, 25.0, 1, 2);

CREATE TEMP TABLE got AS
SELECT 'd' AS call, row_number() OVER () AS ord, r.* FROM report_calling('2026-09-01', 200) r
UNION ALL SELECT 'a',  row_number() OVER (), r.* FROM report_calling('2026-09-01', 0) r
UNION ALL SELECT 'a0', row_number() OVER (), r.* FROM report_calling('2026-09-01', NULL) r
UNION ALL SELECT 'f',  row_number() OVER (), r.* FROM report_calling('2026-09-01', 301) r
UNION ALL SELECT 's',  row_number() OVER (), r.* FROM report_calling('2026-09-01', 401) r
UNION ALL SELECT 'o',  row_number() OVER (), r.* FROM report_calling('2026-10-01', 304) r
UNION ALL SELECT 'x',  row_number() OVER (), r.* FROM report_calling('2026-09-01', 999) r;

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
        (SELECT 'extra', g.call, g.ord::int, ${COLS} FROM got g WHERE g.call IN ('d', 'f', 's', 'o')
         EXCEPT ALL
         SELECT 'extra', e.* FROM expected e)
    ) x;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'report_calling differs:\n%', v_diff;
    END IF;
    -- All places in view: same numbers as the district (only one district), 0 and NULL identical
    IF EXISTS (
        SELECT ord, too_few, flag, flag_reason, overdue_n, called_n, early_n, return_known_n, returned_n, calls_per_week
        FROM got WHERE call = 'a'
        EXCEPT ALL
        SELECT ord, too_few, flag, flag_reason, overdue_n, called_n, early_n, return_known_n, returned_n, calls_per_week
        FROM got WHERE call = 'd'
    ) OR EXISTS (
        (SELECT ${COLS} FROM got WHERE call = 'a' EXCEPT ALL SELECT ${COLS} FROM got WHERE call = 'a0')
        UNION ALL
        (SELECT ${COLS} FROM got WHERE call = 'a0' EXCEPT ALL SELECT ${COLS} FROM got WHERE call = 'a')
    ) OR (SELECT org_unit_id || '/' || org_unit_name FROM got WHERE call = 'a' AND ord = 1) <> '0/All places in view' THEN
        RAISE EXCEPTION 'report_calling(0), (NULL) and the district differ';
    END IF;
    IF EXISTS (SELECT 1 FROM got WHERE call = 'x') THEN
        RAISE EXCEPTION 'unknown org unit gave rows';
    END IF;
END \$\$;
SQL
}
check_report
echo "PASS report_calling rows: C1-C5 overdue 3, called 2, 66.7%, early 50.0%, returned 1 of 2 known, too_few"
echo "PASS Pending to call, Died, removals, phone digits, 07-18 boundary, 30-day return edge, not-yet-known"
echo "PASS reasons 'Few overdue patients are called: 4.0%.' and 'Most calls are late: 32.0% within 14 days.'"

# ---------------------------------------------------------------------------
# calls_per_week = ceil(overdue_with_phone_n / 4) on every row; reconciliation with
# HEART360_OVERDUE_PATIENTS_CALLED (called_n at most the view's count, per node and month)
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(org_unit_id || ':' || overdue_with_phone_n || '->' || calls_per_week, ', ') INTO v_bad
    FROM (SELECT * FROM report_calling('2026-09-01', 0)
          UNION ALL SELECT * FROM report_calling('2026-10-01', 0)) r
    WHERE r.calls_per_week IS DISTINCT FROM ceil(r.overdue_with_phone_n / 4.0)::bigint;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'calls_per_week is not ceil(n/4): %', v_bad;
    END IF;
    IF (SELECT string_agg(calls_per_week::text, ',' ORDER BY org_unit_id) FROM report_calling('2026-09-01', 200))
       <> '15,1,7,7,2,0' THEN
        RAISE EXCEPTION 'calls_per_week values are wrong';
    END IF;

    SELECT string_agg(format('%s %s: report %s > view %s', m, r.org_unit_id, r.called_n, v.n), ', ') INTO v_bad
    FROM unnest(ARRAY['2026-08-01', '2026-09-01', '2026-10-01']::date[]) m
    CROSS JOIN LATERAL report_calling(m, 0) r
    CROSS JOIN LATERAL (
        SELECT COALESCE(sum(c.overdue_patients_called), 0) AS n
        FROM heart360_overdue_patients_called c
        WHERE c.ref_month = m
          AND c.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(r.org_unit_id, 0)) d)
    ) v
    WHERE r.called_n > v.n;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'called_n exceeds HEART360_OVERDUE_PATIENTS_CALLED: %', v_bad;
    END IF;
    -- the view counts C3's Pending row (3 at Fac C); Fac D matches (3002's Died row is out of both)
    IF (SELECT string_agg(c.org_unit_id || '=' || c.overdue_patients_called, ',' ORDER BY c.org_unit_id)
        FROM heart360_overdue_patients_called c WHERE c.ref_month = '2026-09-01' AND c.org_unit_id IN (301, 304, 401))
       <> '301=2,304=3,401=1' THEN
        RAISE EXCEPTION 'reconciliation fixture assumption changed';
    END IF;
END $$;
SQL
echo "PASS calls_per_week = ceil(overdue_with_phone_n / 4); called_n <= HEART360_OVERDUE_PATIENTS_CALLED"

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
          AND p.proname IN ('report_calling', 'h360_calling_patients')
          AND p.prosrc ~ '\m(10|14|30|45|50)(\.0+)?\M'
    ) THEN
        RAISE EXCEPTION 'a calling function holds a threshold literal (10, 14, 30, 45 or 50)';
    END IF;

    -- Fac C: minimum 3, early line 50.1, early days 9 -> flagged, reason names 9 days
    UPDATE report_flag_thresholds SET value = 3    WHERE report = 'calling' AND key = 'min_overdue_phone';
    UPDATE report_flag_thresholds SET value = 50.1 WHERE report = 'calling' AND key = 'early_below_pct';
    UPDATE report_flag_thresholds SET value = 9    WHERE report = 'calling' AND key = 'early_days';
    SELECT * INTO r FROM report_calling('2026-09-01', 301);
    IF (r.too_few, r.flag, r.flag_reason, r.early_n) IS DISTINCT FROM
       (FALSE, TRUE, 'Most calls are late: 50.0% within 9 days.', 1::bigint) THEN
        RAISE EXCEPTION 'threshold change not picked up: %', r;
    END IF;
    -- overdue_days 62 (cut-off 06-30): C1-C4 are too recent and C5 is removed -> Fac C has none
    UPDATE report_flag_thresholds SET value = 62 WHERE report = 'calling' AND key = 'overdue_days';
    IF (SELECT overdue_n FROM report_calling('2026-09-01', 301)) <> 0 THEN
        RAISE EXCEPTION 'overdue_days change not picked up';
    END IF;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0099';
EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
END $$;
SQL
if [[ "$(psql_db -tA -c "SELECT string_agg(key || '=' || value, ',' ORDER BY key) FROM heart360tk_schema.report_flag_thresholds WHERE report = 'calling'")" \
      != "called_below_pct=10,early_below_pct=50,early_days=14,min_overdue_phone=10,overdue_days=45,return_days=30" ]]; then
    echo "FAIL threshold probe was not rolled back" >&2
    exit 1
fi
echo "PASS flags follow report_flag_thresholds (no literals; changed rows change flag, reason and overdue)"

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
      AND p.proname = 'report_calling'
      AND (NOT p.prosecdef
           OR p.provolatile <> 's'
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('h360_api', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_cached', p.oid, 'EXECUTE')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp')
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'jit=off'));
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM pg_proc WHERE proname = 'report_calling') <> 1 THEN
        RAISE EXCEPTION 'report function contract broken for: %', v_bad;
    END IF;

    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'heart360tk_schema' AND p.proname = 'h360_calling_patients'
      AND (p.prosecdef
           OR pg_get_userbyid(p.proowner) <> 'heart360tk'
           OR has_function_privilege('public', p.oid, 'EXECUTE')
           OR has_function_privilege('heart360tk_reader', p.oid, 'EXECUTE')
           OR has_function_privilege('h360_api', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'patient-level helper is definer or executable outside heart360tk: %', v_bad;
    END IF;
END $$;

-- h360_api has no table privileges; the definer function still answers.
SET ROLE h360_api;
DO $$
BEGIN
    IF (SELECT called_n FROM heart360tk_schema.report_calling('2026-09-01', 0) WHERE is_selected) <> 30 THEN
        RAISE EXCEPTION 'h360_api got a different called_n';
    END IF;
    BEGIN
        PERFORM * FROM heart360tk_schema.h360_calling_patients('2026-09-01', 0);
        RAISE EXCEPTION 'h360_api executed h360_calling_patients';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
RESET ROLE;
SET ROLE heart360tk_reader;
SELECT 1 FROM heart360tk_schema.report_calling('2026-09-01', 301);
RESET ROLE;
SQL
echo "PASS grants: report_calling definer, executable by heart360tk_reader and h360_api, not PUBLIC"

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
    SELECT row(r.*)::text FROM heart360tk_schema.report_calling('2026-09-01', 0) r
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

echo "calling verified"
