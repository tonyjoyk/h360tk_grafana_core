#!/bin/bash
# Verifies 0.6.6_to_0.6.7 (AD-19, AD-22) on a scratch database.
# Each fixture runs first on the 0.6.0..0.6.5 chain (the bug is asserted),
# then on the same data after 0.6.6_to_0.6.7 (the fix is asserted).
#   Bug 1: latest submitted_at wins, not sheet row order (FR-19).
#   Bug 3: submitter email and append-only history (FR-21).
#   Bug 5: blank strength makes the category unknown; subtree N; All row (FR-23).
# PSQL overrides the psql command, e.g.
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_drug_stock_fixes.sh'
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS="$ROOT/pg_init_scripts/migrations"
BEFORE_CHAIN=(
    "$MIGRATIONS/0.6.0_to_0.6.1.sql"
    "$MIGRATIONS/0.6.1_to_0.6.2.sql"
    "$MIGRATIONS/0.6.2_to_0.6.3.sql"
    "$MIGRATIONS/0.6.3_to_0.6.4.sql"
    "$MIGRATIONS/0.6.4_to_0.6.5.sql"
)
FIX="$MIGRATIONS/0.6.6_to_0.6.7.sql"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
DB_NAME="${DRUG_STOCK_FIXES_VERIFY_DB:-drug_stock_fixes_verify}"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "${BEFORE_CHAIN[@]}" "$FIX" "$TABLES"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

choose_psql() {
    if [[ -n "${PSQL:-}" ]]; then
        read -r -a PSQL_CMD <<< "$PSQL"
        if "${PSQL_CMD[@]}" -X -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
            echo "psql mode: PSQL=$PSQL"
            return
        fi
        echo "verifier-blocked: PSQL=$PSQL cannot connect" >&2
        exit 1
    fi
    if sudo -n -u postgres psql -X -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
        PSQL_CMD=(sudo -n -u postgres psql)
        echo "psql mode: sudo -u postgres"
        return
    fi
    if psql -X -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
        PSQL_CMD=(psql)
        echo "psql mode: local"
        return
    fi
    echo "verifier-blocked: set PSQL, or allow sudo -u postgres psql or local psql" >&2
    exit 1
}

choose_psql

sql_on() {
    local db="$1"
    shift
    "${PSQL_CMD[@]}" -X -q -v ON_ERROR_STOP=1 -d "$db" "$@"
}

sql() {
    sql_on "$DB_NAME" "$@"
}

apply_file() {
    local out
    if ! out="$(sql < "$1" 2>&1)"; then
        printf '%s\n' "$out" >&2
        exit 1
    fi
}

CREATED_READER=0

drop_db() {
    sql_on postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null
    sql_on postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
}

cleanup() {
    drop_db || true
    if [[ "$CREATED_READER" == "1" ]]; then
        sql_on postgres -c "DROP ROLE IF EXISTS heart360tk_reader;" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

drop_db

if [[ "$(sql_on postgres -tA -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'heart360tk_reader'")" == "0" ]]; then
    sql_on postgres -c "CREATE ROLE heart360tk_reader NOLOGIN;" >/dev/null
    CREATED_READER=1
fi

sql_on postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk') THEN
        CREATE ROLE heart360tk LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana') THEN
        CREATE ROLE grafana LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_cached') THEN
        CREATE ROLE heart360tk_cached LOGIN;
    END IF;
END \$\$;
CREATE DATABASE ${DB_NAME} OWNER heart360tk;
SQL

sql <<'SQL'
CREATE SCHEMA heart360tk_schema AUTHORIZATION heart360tk;
CREATE SCHEMA heart360tk_reporting AUTHORIZATION heart360tk;
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
CREATE TABLE org_units (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    level       INTEGER NOT NULL,
    parent_id   INTEGER REFERENCES org_units(id)
);
CREATE OR REPLACE FUNCTION get_descendant_ids(p_parent_id INTEGER)
RETURNS TABLE(id INTEGER)
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE descendants AS (
        SELECT ou.id FROM org_units ou
        WHERE COALESCE(p_parent_id, 0) <> 0 AND ou.id = p_parent_id
        UNION ALL
        SELECT o.id FROM org_units o JOIN descendants d ON o.parent_id = d.id
    )
    SELECT d.id FROM descendants d
    UNION ALL
    SELECT ou.id FROM org_units ou WHERE COALESCE(p_parent_id, 0) = 0;
$$;
CREATE TABLE heart360tk_reporting.heart360_patients_registered (
    ref_month date,
    org_unit_id integer,
    cumulative_number_of_patients numeric,
    nb_new_patients numeric
);
SQL

for file in "${BEFORE_CHAIN[@]}"; do
    echo "apply $(basename "$file")"
    apply_file "$file"
done

# Fixture. Patients sit at level 4 under PHC 11 and partly under PHC 12.
# Cohort = the four level-3 PHCs of North District. PHC 31 is outside it.
sql <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
INSERT INTO org_units (id, name, level, parent_id) VALUES
    (1,   'State',          1, NULL),
    (2,   'North District', 2, 1),
    (3,   'South District', 2, 1),
    (11,  'PHC 11',         3, 2),
    (12,  'PHC 12',         3, 2),
    (13,  'PHC 13',         3, 2),
    (14,  'PHC 14',         3, 2),
    (31,  'PHC 31',         3, 3),
    (111, 'Site 111',       4, 11),
    (112, 'Site 112',       4, 11),
    (121, 'Site 121',       4, 12);
INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (11), (12), (13), (14);
INSERT INTO heart360tk_reporting.heart360_patients_registered (
    ref_month, org_unit_id, cumulative_number_of_patients, nb_new_patients
) VALUES
    (DATE '2026-09-01', 111, 60, 1),
    (DATE '2026-09-01', 112, 40, 1),
    (DATE '2026-09-01', 12,  30, 1),
    (DATE '2026-09-01', 121, 50, 1),
    (DATE '2026-09-01', 13,  50, 1),
    (DATE '2026-09-01', 14,  20, 1),
    (DATE '2026-09-01', 31,  500, 1),
    (DATE '2026-08-01', 111, 55, 1);
SQL

# Bug 1 / 3 fixture rows, PHC 31, August 2026. Sheet rows are out of time order.
P1='[
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"329528","in_stock":"40","submitted_at":"2026-08-25T09:00:00Z","submitted_by":"  Nurse.A@Example.org ","sheet_row":2},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"329528","in_stock":"10","submitted_at":"2026-08-20T09:00:00Z","submitted_by":"nurse.b@example.org","sheet_row":3},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"329526","in_stock":"7","submitted_at":"2026-08-26T08:00:00Z","submitted_by":"nurse.c@example.org","sheet_row":5},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"329526","in_stock":"9","submitted_at":"2026-08-26T08:00:00Z","submitted_by":"nurse.d@example.org","sheet_row":4},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"316764","in_stock":"55","submitted_at":"2026-08-21T00:00:00Z","submitted_by":"nurse.a@example.org","sheet_row":6},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"316765","in_stock":"1","submitted_at":"","submitted_by":""}
]'
P2='[
  {"org_unit_id":"31","reporting_month":"2026-08-01","drug_code":"329528","in_stock":"99","submitted_at":"2026-08-18T09:00:00Z","submitter_email":"Late.Sync@Example.org","sheet_row":"1"},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"316764","in_stock":"66","submitted_at":""},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"316765","in_stock":"2","submitted_at":"","submitted_by":""},
  {"org_unit_id":"31","reporting_month":"2026-08","drug_code":"331132","in_stock":"3","submitted_at":"2026-08-22T00:00:00Z","submitted_by":"x@example.org","sheet_row":"abc"}
]'
P12="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))' "$P1" "$P2")"

# Bug 5 fixture rows, September 2026. Blank = NULL in_stock.
P5='[
  {"org_unit_id":"11","reporting_month":"2026-09","drug_code":"329528","in_stock":"100"},
  {"org_unit_id":"11","reporting_month":"2026-09","drug_code":"329526","in_stock":"50"},
  {"org_unit_id":"11","reporting_month":"2026-09","drug_code":"316764","in_stock":"37"},
  {"org_unit_id":"11","reporting_month":"2026-09","drug_code":"316765","in_stock":"18.5"},
  {"org_unit_id":"11","reporting_month":"2026-09","drug_code":"331132","in_stock":"6"},
  {"org_unit_id":"11","reporting_month":"2026-09","drug_code":"197499","in_stock":"3"},
  {"org_unit_id":"12","reporting_month":"2026-09","drug_code":"329528","in_stock":"112"},
  {"org_unit_id":"12","reporting_month":"2026-09","drug_code":"329526","in_stock":""},
  {"org_unit_id":"12","reporting_month":"2026-09","drug_code":"316764","in_stock":"74"},
  {"org_unit_id":"12","reporting_month":"2026-09","drug_code":"316765","in_stock":"0"},
  {"org_unit_id":"12","reporting_month":"2026-09","drug_code":"331132","in_stock":"0"},
  {"org_unit_id":"12","reporting_month":"2026-09","drug_code":"197499","in_stock":"0"},
  {"org_unit_id":"14","reporting_month":"2026-09","drug_code":"329528","in_stock":"28"},
  {"org_unit_id":"31","reporting_month":"2026-09","drug_code":"329528","in_stock":"5"}
]'

pull() {
    sql -tA -F '|' -v payload="$1" <<'SQL'
SET ROLE heart360tk;
SELECT accepted, rejected FROM heart360tk_schema.drug_stock_pull_apply(:'payload'::jsonb);
SQL
}

expect_pull() {
    local label="$1" expected="$2" payload="$3" got
    got="$(pull "$payload")"
    if [[ "$got" != "$expected" ]]; then
        echo "$label returned accepted|rejected $got, expected $expected" >&2
        exit 1
    fi
    echo "$label accepted|rejected = $got"
}

show_current() {
    sql -c "SELECT rxnorm_code, in_stock, submitted_at AT TIME ZONE 'UTC' AS submitted_at_utc FROM heart360tk_schema.drug_stock_submission WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' ORDER BY rxnorm_code;"
}

echo
echo "=== BEFORE 0.6.6_to_0.6.7 ==="
echo "--- bug 1: one pull, sheet rows out of time order"
expect_pull "P1" "6|0" "$P1"
show_current
sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
BEGIN
    IF (SELECT in_stock FROM drug_stock_submission
        WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '329528') IS DISTINCT FROM 10 THEN
        RAISE EXCEPTION 'before: expected the bug (sheet row 3, older value 10, wins)';
    END IF;
    IF (SELECT in_stock FROM drug_stock_submission
        WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '329526') IS DISTINCT FROM 9 THEN
        RAISE EXCEPTION 'before: expected the tie to go to array order (9)';
    END IF;
END $$;
SQL
echo "--- bug 1: a later pull carries only older rows"
expect_pull "P2" "4|0" "$P2"
show_current
sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
BEGIN
    IF (SELECT in_stock FROM drug_stock_submission
        WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '329528') IS DISTINCT FROM 99 THEN
        RAISE EXCEPTION 'before: expected the bug (older 2026-08-18 value 99 overwrote 2026-08-25)';
    END IF;
    IF (SELECT in_stock FROM drug_stock_submission
        WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '316764') IS DISTINCT FROM 66 THEN
        RAISE EXCEPTION 'before: expected the bug (undated 66 overwrote dated 55)';
    END IF;
END $$;
SQL
echo "--- bug 3: no submitter column, no history table"
sql <<'SQL'
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'heart360tk_schema' AND table_name = 'drug_stock_submission'
          AND column_name = 'submitted_by'
    ) OR to_regclass('heart360tk_schema.drug_stock_submission_history') IS NOT NULL THEN
        RAISE EXCEPTION 'before: submitter or history already present';
    END IF;
    RAISE NOTICE 'before: no submitted_by column, no history table; 10 rows accepted, % kept',
        (SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission);
END $$;
SQL

echo "--- bug 5: patient days with a blank strength, level-4 patients, All row"
expect_pull "P5" "14|0" "$P5"
sql <<'SQL'
SELECT org_unit_id, drug_category, patients_n, round(category_patient_days, 6) AS patient_days
FROM heart360tk_reporting.drug_stock_patient_days
WHERE reporting_month = DATE '2026-09-01'
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2;
SELECT matrix->>'Facility' AS facility, matrix->>'CCB Patient days' AS ccb, matrix->>'ARB Patient days' AS arb, matrix->>'Diuretic Patient days' AS diuretic
FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL);
DO $$
DECLARE
    v_all json;
BEGIN
    IF EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11 AND reporting_month = DATE '2026-09-01'
          AND (patients_n IS NOT NULL OR category_patient_days IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'before: expected the bug (PHC 11 N is NULL, patients sit at level 4)';
    END IF;
    IF abs((SELECT MAX(category_patient_days) FROM heart360tk_reporting.drug_stock_patient_days
            WHERE org_unit_id = 12 AND reporting_month = DATE '2026-09-01' AND drug_category = 'CCB')
           - 112::numeric / 42) >= 0.000001 THEN
        RAISE EXCEPTION 'before: expected the bug (PHC 12 CCB = partial 112/42 with Amlodipine 10 mg blank)';
    END IF;
    SELECT matrix INTO v_all
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'All';
    IF abs((v_all->>'CCB Patient days')::numeric - 340::numeric / 140) >= 0.000001
       OR abs((v_all->>'ARB Patient days')::numeric - 4) >= 0.000001
       OR abs((v_all->>'Diuretic Patient days')::numeric - 2) >= 0.000001 THEN
        RAISE EXCEPTION 'before: All row is %', v_all;
    END IF;
END $$;
SQL

dump_state() {
    sql -tA -F $'\t' -c \
        "SELECT org_unit_id, reporting_month, rxnorm_code, country_code, programme_code, COALESCE(in_stock::text, '<null>'), COALESCE(submitted_at::text, '<null>'), pulled_at FROM heart360tk_schema.drug_stock_submission ORDER BY 1, 2, 3;"
}

BEFORE_STATE="$(mktemp)"
AFTER_STATE="$(mktemp)"
dump_state > "$BEFORE_STATE"

echo
echo "=== APPLY 0.6.6_to_0.6.7 (twice) ==="
apply_file "$FIX"
apply_file "$FIX"
dump_state > "$AFTER_STATE"
if ! diff -u "$BEFORE_STATE" "$AFTER_STATE"; then
    echo "the migration changed stored submission rows" >&2
    exit 1
fi
echo "stored submission rows unchanged by the migration"

sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_columns text;
BEGIN
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_schema' AND table_name = 'drug_stock_submission';
    IF v_columns IS DISTINCT FROM
        'org_unit_id,reporting_month,rxnorm_code,country_code,programme_code,in_stock,submitted_at,pulled_at,submitted_by,sheet_row' THEN
        RAISE EXCEPTION 'submission columns are [%]', v_columns;
    END IF;
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_schema' AND table_name = 'drug_stock_submission_history';
    IF v_columns IS DISTINCT FROM
        'history_id,org_unit_id,reporting_month,rxnorm_code,country_code,programme_code,in_stock,submitted_at,submitted_by,sheet_row,pulled_at' THEN
        RAISE EXCEPTION 'history columns are [%]', v_columns;
    END IF;
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_schema' AND table_name = 'drug_stock_submission_reject';
    IF v_columns IS DISTINCT FROM
        'org_unit_id,reporting_month,drug_code,in_stock,submitted_at,reason,pulled_at,submitted_by,sheet_row' THEN
        RAISE EXCEPTION 'reject columns are [%]', v_columns;
    END IF;
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_reporting' AND table_name = 'drug_stock_patient_days';
    IF v_columns IS DISTINCT FROM
        'org_unit_id,facility_name,reporting_month,drug_category,rxnorm_code,drug_name,dosage,submission_present,in_stock,dose_factor,patients_n,load_factor,category_coeff,normalized_stock,category_patient_days,category_known,category_normalized_stock' THEN
        RAISE EXCEPTION 'patient-days columns are [%]', v_columns;
    END IF;
    IF (SELECT COUNT(*) FROM drug_stock_submission_history)
       IS DISTINCT FROM (SELECT COUNT(*) FROM drug_stock_submission) THEN
        RAISE EXCEPTION 'upgrade did not copy each stored row into history once';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission s
        WHERE NOT EXISTS (
            SELECT 1 FROM drug_stock_submission_history h
            WHERE h.org_unit_id = s.org_unit_id AND h.reporting_month = s.reporting_month
              AND h.rxnorm_code = s.rxnorm_code
              AND h.in_stock IS NOT DISTINCT FROM s.in_stock
              AND h.submitted_at IS NOT DISTINCT FROM s.submitted_at
        )
    ) THEN
        RAISE EXCEPTION 'a stored row has no history row after upgrade';
    END IF;
    RAISE NOTICE 'upgrade: % stored rows copied to history', (SELECT COUNT(*) FROM drug_stock_submission_history);
END $$;
SQL

echo
echo "=== AFTER 0.6.6_to_0.6.7 (same fixtures, clean tables) ==="
sql <<'SQL'
SET ROLE heart360tk;
TRUNCATE heart360tk_schema.drug_stock_submission,
         heart360tk_schema.drug_stock_submission_reject,
         heart360tk_schema.drug_stock_submission_history RESTART IDENTITY;
SQL

echo "--- bug 1: one pull, sheet rows out of time order"
expect_pull "P1" "6|0" "$P1"
show_current
sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    r record;
BEGIN
    SELECT * INTO r FROM drug_stock_submission
    WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '329528';
    IF r.in_stock IS DISTINCT FROM 40
       OR r.submitted_at IS DISTINCT FROM TIMESTAMPTZ '2026-08-25T09:00:00Z'
       OR r.sheet_row IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'after: newest submitted_at did not win: %', row_to_json(r);
    END IF;
    SELECT * INTO r FROM drug_stock_submission
    WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '329526';
    IF r.in_stock IS DISTINCT FROM 7 OR r.sheet_row IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'after: submitted_at tie did not go to the higher sheet_row: %', row_to_json(r);
    END IF;
END $$;
SQL

echo "--- bug 1: a later pull carries only older rows"
expect_pull "P2" "3|1" "$P2"
show_current
sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    r record;
BEGIN
    SELECT * INTO r FROM drug_stock_submission
    WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '329528';
    IF r.in_stock IS DISTINCT FROM 40 OR r.submitted_by IS DISTINCT FROM 'nurse.a@example.org' THEN
        RAISE EXCEPTION 'after: an older pull replaced the newest value: %', row_to_json(r);
    END IF;
    SELECT * INTO r FROM drug_stock_submission
    WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '316764';
    IF r.in_stock IS DISTINCT FROM 55 THEN
        RAISE EXCEPTION 'after: an undated row replaced a dated one: %', row_to_json(r);
    END IF;
    SELECT * INTO r FROM drug_stock_submission
    WHERE org_unit_id = 31 AND reporting_month = DATE '2026-08-01' AND rxnorm_code = '316765';
    IF r.in_stock IS DISTINCT FROM 2 OR r.submitted_by IS NOT NULL THEN
        RAISE EXCEPTION 'after: undated rows did not go to the later-ingested row: %', row_to_json(r);
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE org_unit_id = 31 AND rxnorm_code = '331132'
    ) THEN
        RAISE EXCEPTION 'after: a row with sheet_row abc was stored';
    END IF;
    IF (
        SELECT COUNT(*) FROM drug_stock_submission_reject
        WHERE reason = 'invalid_sheet_row' AND sheet_row = 'abc'
          AND submitted_by = 'x@example.org' AND drug_code = '331132'
    ) <> 1 THEN
        RAISE EXCEPTION 'after: invalid sheet_row was not quarantined with its submitter';
    END IF;
END $$;
SQL

echo "--- bug 3: submitter and history"
sql -c "SELECT rxnorm_code, in_stock, submitted_at AT TIME ZONE 'UTC' AS submitted_at_utc, submitted_by, sheet_row FROM heart360tk_schema.drug_stock_submission_history WHERE org_unit_id = 31 ORDER BY rxnorm_code, submitted_at NULLS FIRST, sheet_row NULLS FIRST, history_id;"
sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM drug_stock_submission_history) <> 9 THEN
        RAISE EXCEPTION 'after: history has % rows, expected 9', (SELECT COUNT(*) FROM drug_stock_submission_history);
    END IF;
    IF (
        SELECT string_agg(in_stock::text || '/' || COALESCE(submitted_by, '-'), ',' ORDER BY submitted_at)
        FROM drug_stock_submission_history
        WHERE org_unit_id = 31 AND rxnorm_code = '329528'
    ) IS DISTINCT FROM '99/late.sync@example.org,10/nurse.b@example.org,40/nurse.a@example.org' THEN
        RAISE EXCEPTION 'after: 329528 history is not three rows with submitters';
    END IF;
    IF (
        SELECT COUNT(*) FROM drug_stock_submission
        WHERE org_unit_id = 31 AND rxnorm_code = '329528'
    ) <> 1 THEN
        RAISE EXCEPTION 'after: more than one displayed value';
    END IF;
END $$;
SQL

echo "--- bug 1/3: re-pull of every sheet row in one call (no duplicates, same winners)"
expect_pull "P1+P2" "9|1" "$P12"
sql <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_mismatch int;
BEGIN
    IF (SELECT COUNT(*) FROM drug_stock_submission_history) <> 9 THEN
        RAISE EXCEPTION 'after: re-pull duplicated history (% rows)', (SELECT COUNT(*) FROM drug_stock_submission_history);
    END IF;
    IF (SELECT COUNT(*) FROM drug_stock_submission_reject) <> 1 THEN
        RAISE EXCEPTION 'after: re-pull duplicated rejects';
    END IF;
    IF (
        SELECT string_agg(rxnorm_code || '=' || in_stock::text, ',' ORDER BY rxnorm_code)
        FROM drug_stock_submission WHERE org_unit_id = 31
    ) IS DISTINCT FROM '316764=55,316765=2,329526=7,329528=40' THEN
        RAISE EXCEPTION 'after: re-pull changed the winners';
    END IF;
    -- The board must agree with the newest history row of every key.
    SELECT COUNT(*) INTO v_mismatch
    FROM drug_stock_submission s
    JOIN LATERAL (
        SELECT h.*
        FROM drug_stock_submission_history h
        WHERE h.org_unit_id = s.org_unit_id
          AND h.reporting_month = s.reporting_month
          AND h.rxnorm_code = s.rxnorm_code
        ORDER BY h.submitted_at DESC NULLS LAST, COALESCE(h.sheet_row, 0) DESC, h.history_id DESC
        LIMIT 1
    ) newest ON true
    WHERE newest.in_stock IS DISTINCT FROM s.in_stock
       OR newest.submitted_at IS DISTINCT FROM s.submitted_at
       OR newest.submitted_by IS DISTINCT FROM s.submitted_by
       OR newest.sheet_row IS DISTINCT FROM s.sheet_row;
    IF v_mismatch <> 0 THEN
        RAISE EXCEPTION 'after: % stored rows disagree with the newest history row', v_mismatch;
    END IF;
END $$;
SQL

echo "--- bug 5: patient days with a blank strength, level-4 patients, All row"
expect_pull "P5" "14|0" "$P5"
sql <<'SQL'
SELECT org_unit_id, drug_category, patients_n, category_known, round(category_patient_days, 6) AS patient_days
FROM heart360tk_reporting.drug_stock_patient_days
WHERE reporting_month = DATE '2026-09-01'
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2;
SELECT matrix->>'Facility' AS facility, matrix->>'CCB Patient days' AS ccb, matrix->>'ARB Patient days' AS arb, matrix->>'Diuretic Patient days' AS diuretic
FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL);
SELECT drug_category, round(category_patient_days, 6) AS patient_days, reporting_n, cohort_n, normalized_stock, patients_n
FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', NULL);
SQL
sql <<'SQL'
DO $$
DECLARE
    v_all json;
    v_row json;
    v_text text;
    r record;
BEGIN
    -- Subtree N (A51).
    IF (
        SELECT string_agg(org_unit_id || '=' || COALESCE(patients_n::text, 'null'), ',' ORDER BY org_unit_id)
        FROM (
            SELECT DISTINCT org_unit_id, patients_n
            FROM heart360tk_reporting.drug_stock_patient_days
            WHERE reporting_month = DATE '2026-09-01'
        ) n
    ) IS DISTINCT FROM '11=100,12=80,13=50,14=20' THEN
        RAISE EXCEPTION 'after: subtree N is wrong';
    END IF;

    -- Facility patient days (A50).
    FOR r IN
        SELECT * FROM (VALUES
            (11, 'CCB',      200::numeric / 140),
            (11, 'ARB',      74::numeric / 37),
            (11, 'Diuretic', 12::numeric / 6),
            (12, 'CCB',      NULL::numeric),
            (12, 'ARB',      74::numeric / 29.6),
            (12, 'Diuretic', 0::numeric),
            (13, 'CCB',      NULL), (13, 'ARB', NULL), (13, 'Diuretic', NULL),
            (14, 'CCB',      NULL), (14, 'ARB', NULL), (14, 'Diuretic', NULL)
        ) AS e(org_unit_id, drug_category, expected)
    LOOP
        IF EXISTS (
            SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days v
            WHERE v.org_unit_id = r.org_unit_id
              AND v.reporting_month = DATE '2026-09-01'
              AND v.drug_category = r.drug_category
              AND NOT (
                  (r.expected IS NULL AND v.category_patient_days IS NULL)
                  OR abs(v.category_patient_days - r.expected) < 0.000001
              )
        ) THEN
            RAISE EXCEPTION 'after: % % patient days is not %', r.org_unit_id, r.drug_category, r.expected;
        END IF;
    END LOOP;
    IF EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 12 AND reporting_month = DATE '2026-09-01' AND drug_category = 'CCB'
          AND (category_known OR category_normalized_stock IS NOT NULL)
    ) OR EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 12 AND reporting_month = DATE '2026-09-01' AND drug_category = 'Diuretic'
          AND (NOT category_known OR category_normalized_stock IS DISTINCT FROM 0)
    ) THEN
        RAISE EXCEPTION 'after: blank strength is not unknown, or explicit 0 is not known 0';
    END IF;

    -- All row: only facilities with a number; reporting_n of cohort_n.
    FOR r IN
        SELECT * FROM (VALUES
            ('CCB',      200::numeric / 140,   1),
            ('ARB',      148::numeric / 66.6,  2),
            ('Diuretic', 12::numeric / 10.8,   2)
        ) AS e(drug_category, expected, reporting_n)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', NULL) a
            WHERE a.drug_category = r.drug_category
              AND abs(a.category_patient_days - r.expected) < 0.000001
              AND a.reporting_n = r.reporting_n
              AND a.cohort_n = 4
        ) THEN
            RAISE EXCEPTION 'after: All % is not % over % of 4', r.drug_category, r.expected, r.reporting_n;
        END IF;
    END LOOP;
    IF (
        SELECT json_agg(a ORDER BY drug_category)::text
        FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', 2) a
    ) IS DISTINCT FROM (
        SELECT json_agg(a ORDER BY drug_category)::text
        FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', NULL) a
    ) OR (
        SELECT json_agg(a ORDER BY drug_category)::text
        FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', 0) a
    ) IS DISTINCT FROM (
        SELECT json_agg(a ORDER BY drug_category)::text
        FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', NULL) a
    ) THEN
        RAISE EXCEPTION 'after: district or 0 scope differs from all';
    END IF;
    IF EXISTS (SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', 3)) THEN
        RAISE EXCEPTION 'after: a district without cohort facilities returned an All row';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', 12) a
        WHERE a.drug_category = 'ARB' AND abs(a.category_patient_days - 2.5) < 0.000001
          AND a.reporting_n = 1 AND a.cohort_n = 1
    ) OR NOT EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days_all(DATE '2026-09-01', 12) a
        WHERE a.drug_category = 'CCB' AND a.category_patient_days IS NULL AND a.reporting_n = 0
    ) THEN
        RAISE EXCEPTION 'after: facility-scope All row is wrong';
    END IF;

    -- The matrix copies the view and the All function.
    SELECT matrix INTO v_all
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'All';
    IF abs((v_all->>'CCB Patient days')::numeric - 200::numeric / 140) >= 0.000001
       OR abs((v_all->>'ARB Patient days')::numeric - 148::numeric / 66.6) >= 0.000001
       OR abs((v_all->>'Diuretic Patient days')::numeric - 12::numeric / 10.8) >= 0.000001 THEN
        RAISE EXCEPTION 'after: matrix All row is %', v_all;
    END IF;
    SELECT matrix INTO v_row
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'PHC 12';
    IF (v_row->>'CCB Patient days')::numeric IS DISTINCT FROM -1
       OR v_row->>'Amlodipine 10 mg' IS DISTINCT FROM chr(8212)
       OR abs((v_row->>'ARB Patient days')::numeric - 2.5) >= 0.000001
       OR (v_row->>'Diuretic Patient days')::numeric IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'after: PHC 12 matrix row is %', v_row;
    END IF;
    SELECT matrix INTO v_row
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'PHC 14';
    IF (v_row->>'CCB Patient days')::numeric IS DISTINCT FROM -1
       OR v_row->>'Amlodipine 10 mg' IS DISTINCT FROM chr(8212) THEN
        RAISE EXCEPTION 'after: PHC 14 (missing strength row) matrix row is %', v_row;
    END IF;
    SELECT matrix INTO v_row
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'PHC 13';
    IF v_row->>'CCB Patient days' IS NOT NULL OR v_row->>'Amlodipine 5 mg' IS DISTINCT FROM '?' THEN
        RAISE EXCEPTION 'after: PHC 13 (no submission) matrix row is %', v_row;
    END IF;
    IF (SELECT COUNT(*) FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 0)) <> 5
       OR NOT EXISTS (
           SELECT 1 FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 0)
           WHERE matrix->>'Facility' = 'All'
       ) THEN
        RAISE EXCEPTION 'after: matrix scope 0 does not behave as all';
    END IF;
    SELECT string_agg(matrix->>'Facility', ',' ORDER BY matrix->>'Facility') INTO v_text
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 2);
    IF v_text IS DISTINCT FROM 'PHC 11,PHC 12,PHC 13,PHC 14' THEN
        RAISE EXCEPTION 'after: district matrix rows are %', v_text;
    END IF;
END $$;
SQL

echo "--- cohort overlap check (a node and its descendant)"
sql <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM drug_stock_form_cohort_overlap) THEN
        RAISE EXCEPTION 'fixture cohort overlaps';
    END IF;
END $$;
BEGIN;
INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (111), (2);
DO $$
BEGIN
    IF (
        SELECT string_agg(ancestor_id || '>' || descendant_id, ',' ORDER BY ancestor_id, descendant_id)
        FROM drug_stock_form_cohort_overlap
    ) IS DISTINCT FROM '2>11,2>12,2>13,2>14,2>111,11>111' THEN
        RAISE EXCEPTION 'overlap view returned %', (
            SELECT string_agg(ancestor_id || '>' || descendant_id, ',' ORDER BY ancestor_id, descendant_id)
            FROM drug_stock_form_cohort_overlap);
    END IF;
END $$;
ROLLBACK;
SQL
echo "overlap view lists ancestor/descendant pairs and is empty for the fixture cohort"

echo "--- re-apply 0.6.6_to_0.6.7 with rows"
dump_state > "$BEFORE_STATE"
HIST_BEFORE="$(sql -tA -c "SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission_history")"
apply_file "$FIX"
dump_state > "$AFTER_STATE"
HIST_AFTER="$(sql -tA -c "SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission_history")"
if ! diff -u "$BEFORE_STATE" "$AFTER_STATE" || [[ "$HIST_BEFORE" != "$HIST_AFTER" ]]; then
    echo "re-applying 0.6.6_to_0.6.7 changed rows (history $HIST_BEFORE -> $HIST_AFTER)" >&2
    exit 1
fi
echo "re-apply kept $HIST_AFTER history rows and every stored row"

echo "--- privileges"
# drug_stock_pull_apply runs inside the definer save_drug_stock_entry: without pg_temp last, a
# caller's temp table would be searched first.
BAD_PATH="$(sql -tA -c "SELECT string_agg(p.oid::regprocedure::text, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname IN ('drug_stock_pull_apply', 'drug_stock_on_hand_matrix') AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%pg_temp')")"
if [[ -n "$BAD_PATH" ]]; then
    echo "search_path without pg_temp last: $BAD_PATH" >&2
    exit 1
fi
echo "drug_stock_pull_apply and drug_stock_on_hand_matrix search_path ends in pg_temp"

expect_denied() {
    local label="$1" role="$2" statement="$3" out status
    set +e
    out="$(sql -c "SET ROLE $role; $statement" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        echo "$label succeeded" >&2
        exit 1
    fi
    if [[ "$out" != *"permission denied"* && "$out" != *"must be heart360tk"* ]]; then
        echo "$label failed for another reason: $out" >&2
        exit 1
    fi
    echo "$label refused"
}

sql <<'SQL'
GRANT USAGE ON SCHEMA heart360tk_schema TO heart360tk_cached, heart360tk_reader, grafana;
GRANT USAGE ON SCHEMA heart360tk_reporting TO heart360tk_cached, heart360tk_reader, grafana;
GRANT SELECT ON heart360tk_schema.org_units TO heart360tk_cached, heart360tk_reader;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_descendant_ids(integer) TO heart360tk_cached, heart360tk_reader;
SQL
for role in heart360tk_cached heart360tk_reader grafana; do
    expect_denied "$role history insert" "$role" \
        "INSERT INTO heart360tk_schema.drug_stock_submission_history (org_unit_id, reporting_month, rxnorm_code, country_code, programme_code, pulled_at) VALUES (11, DATE '2026-09-01', '329528', 'India', 'IHCI', now());"
    expect_denied "$role pull apply" "$role" \
        "SELECT * FROM heart360tk_schema.drug_stock_pull_apply('[]'::jsonb);"
done
for role in heart360tk_cached heart360tk_reader; do
    count="$(sql -tA -c "SET ROLE $role; SELECT COUNT(*) FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL);")"
    if [[ "$count" != "5" ]]; then
        echo "$role matrix returned $count rows" >&2
        exit 1
    fi
    echo "$role reads the matrix (5 rows)"
done
sql -tA -c "SET ROLE heart360tk_reader; SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission_history;" >/dev/null
echo "heart360tk_reader reads history"
expect_denied "grafana history read" grafana "SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission_history;"

python3 - "$TABLES" <<'PY'
import sys
lines = [line.strip() for line in open(sys.argv[1]).read().splitlines()]
prev = lines.index(r"\ir migrations/0.6.5_to_0.6.6.sql")
mine = lines.index(r"\ir migrations/0.6.6_to_0.6.7.sql")
if mine != prev + 1:
    raise SystemExit(f"include order is line {prev + 1} then line {mine + 1}")
print("include line follows 0.6.5_to_0.6.6.sql")
PY

rm -f "$BEFORE_STATE" "$AFTER_STATE"
echo "drug stock fixes verified"
