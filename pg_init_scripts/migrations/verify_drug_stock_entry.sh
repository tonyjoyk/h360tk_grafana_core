#!/bin/bash
# Verifies 0.6.14_to_0.6.15 (story 3.5, AD-16, AD-19, AD-21) on a scratch database:
# save_drug_stock_entry writes through drug_stock_pull_apply, so
#   - Latest Wins: a form save replaces an older submission and stays behind a newer one;
#   - every accepted save adds a drug_stock_submission_history row;
#   - blank stays unknown (NULL) and 0 stays zero;
#   - a drug that is not a protocol drug and strength, a repeat, a fraction, a negative or a
#     number over 1,000,000 is rejected and not written;
#   - no access, a place above facility level, a place outside the cohort and a future month
#     are refused and write nothing;
#   - submitted_by is the email (or the login), submitted_at is now();
#   - h360_api can execute it; heart360tk_reader and PUBLIC cannot; the function is a
#     SECURITY DEFINER owned by heart360tk with a pinned search_path;
#   - the migration re-runs cleanly.
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_drug_stock_entry.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATIONS="$ROOT/pg_init_scripts/migrations"
CHAIN=(
    "$MIGRATIONS/0.6.0_to_0.6.1.sql"
    "$MIGRATIONS/0.6.1_to_0.6.2.sql"
    "$MIGRATIONS/0.6.2_to_0.6.3.sql"
    "$MIGRATIONS/0.6.3_to_0.6.4.sql"
    "$MIGRATIONS/0.6.4_to_0.6.5.sql"
    "$MIGRATIONS/0.6.6_to_0.6.7.sql"
)
SECURITY="$MIGRATIONS/0.6.5_to_0.6.6.sql"
MIGRATION="$MIGRATIONS/0.6.14_to_0.6.15.sql"
DB_NAME="${DRUG_STOCK_ENTRY_VERIFY_DB:-drug_stock_entry_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$TABLES" "${CHAIN[@]}" "$SECURITY" "$MIGRATION"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

if ! grep -q '\\ir migrations/0.6.14_to_0.6.15.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.14_to_0.6.15.sql" >&2
    exit 1
fi

if ! "${PSQL_CMD[@]}" -d postgres -X -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
    echo "verifier-blocked: '$PSQL' cannot connect" >&2
    exit 1
fi

psql_admin() { "${PSQL_CMD[@]}" -d postgres -X -v ON_ERROR_STOP=1 -q "$@"; }
psql_db()    { "${PSQL_CMD[@]}" -d "$DB_NAME" -X -v ON_ERROR_STOP=1 -q "$@"; }

apply_file() {
    local out
    if ! out="$(psql_db < "$1" 2>&1)"; then
        printf '%s\n' "$out" >&2
        exit 1
    fi
}

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
    FOREACH r IN ARRAY ARRAY['heart360tk', 'grafana', 'heart360tk_cached', 'heart360tk_reader', 'h360_api'] LOOP
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
ALTER DEFAULT PRIVILEGES FOR ROLE heart360tk REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
SQL

echo "apply core tables (01_heart360_tables.sql up to the reporting tables)"
if ! core_out="$(sed -n '1,/^CREATE INDEX IF NOT EXISTS idx_import_facility_mapping_leaf_node_key/p' "$TABLES" | psql_db 2>&1)"; then
    echo "$core_out" >&2
    exit 1
fi

echo "apply drug stock chain 0.6.0..0.6.5, 0.6.6_to_0.6.7"
for f in "${CHAIN[@]}"; do
    apply_file "$f"
done

# h360_access_allows exactly as 0.6.5_to_0.6.6 defines it. The rest of that migration
# alters cluster roles, so only the function is taken.
echo "apply h360_access_allows from 0.6.5_to_0.6.6"
if ! access_out="$( { echo 'SET ROLE heart360tk; SET search_path TO heart360tk_schema;'; \
    sed -n '/^CREATE OR REPLACE FUNCTION h360_access_allows(/,/^GRANT EXECUTE ON FUNCTION h360_access_allows/p' "$SECURITY"; } \
    | psql_db 2>&1)"; then
    echo "$access_out" >&2
    exit 1
fi

echo "apply 0.6.14_to_0.6.15"
apply_file "$MIGRATION"
echo "apply 0.6.14_to_0.6.15 again (idempotent)"
apply_file "$MIGRATION"

# ---------------------------------------------------------------------------
# Fixture
#   100 Region > 200 District > 301 Fac A (cohort, > 401 Sub A1), 302 Fac B (cohort),
#                               303 Fac C (not in the cohort)
# Protocol drugs: the India IHCI seed of 0.6.0_to_0.6.1 (329528 Amlodipine 5 mg, ...).
# Fac A 2026-10: an older submission (2026-10-08) for 329528 = 40 and 316764 = 70.
# Fac A 2026-09: a newer submission dated 2999-01-01 for 329528 = 9 (stands in for a row
#                that is newer than the form save).
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
INSERT INTO org_units (id, name, level, parent_id) VALUES
    (100, 'Fixture Region', 1, NULL),
    (200, 'Fixture District', 2, 100),
    (301, 'Fac A', 3, 200), (302, 'Fac B', 3, 200), (303, 'Fac C', 3, 200),
    (401, 'Sub A1', 4, 301);
INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (301), (302);
SELECT * FROM drug_stock_pull_apply('[
  {"org_unit_id":"301","reporting_month":"2026-10","drug_code":"329528","in_stock":"40",
   "submitted_at":"2026-10-08T09:00:00Z","submitted_by":"form@example.org","sheet_row":"2"},
  {"org_unit_id":"301","reporting_month":"2026-10","drug_code":"316764","in_stock":"70",
   "submitted_at":"2026-10-08T09:00:00Z","submitted_by":"form@example.org","sheet_row":"2"},
  {"org_unit_id":"301","reporting_month":"2026-09","drug_code":"329528","in_stock":"9",
   "submitted_at":"2999-01-01T00:00:00Z","submitted_by":"future@example.org","sheet_row":"3"}
]'::jsonb);
SQL

echo "assert save_drug_stock_entry"
psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    TEAM_A   constant text[] := ARRAY['heart360tk_facility_view_patients_fac_a'];
    TEAM_DST constant text[] := ARRAY['heart360tk_district_view_aggregated_fixture_district'];
    v_res    jsonb;
    v_hist   bigint;
    v_hist2  bigint;
    v_sub    bigint;
    v_rej    bigint;
    v_row    record;
    v_def    record;
BEGIN
    -- Definition: definer, owner heart360tk, pinned search_path.
    SELECT p.prosecdef, pg_get_userbyid(p.proowner) AS owner, p.proconfig
      INTO v_def
      FROM pg_proc p
     WHERE p.oid = 'heart360tk_schema.save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb)'::regprocedure;
    IF NOT v_def.prosecdef OR v_def.owner <> 'heart360tk'
       OR NOT ('search_path=heart360tk_schema, pg_temp' = ANY (v_def.proconfig)) THEN
        RAISE EXCEPTION 'definition: secdef=% owner=% config=%', v_def.prosecdef, v_def.owner, v_def.proconfig;
    END IF;

    -- Grants: h360_api only.
    IF NOT has_function_privilege('h360_api',
        'heart360tk_schema.save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'h360_api cannot execute save_drug_stock_entry';
    END IF;
    IF has_function_privilege('heart360tk_reader',
        'heart360tk_schema.save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'heart360tk_reader can execute save_drug_stock_entry';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
        WHERE p.oid = 'heart360tk_schema.save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb)'::regprocedure
          AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'PUBLIC can execute save_drug_stock_entry';
    END IF;

    SELECT count(*) INTO v_hist FROM drug_stock_submission_history;
    SELECT count(*) INTO v_rej FROM drug_stock_submission_reject;

    -- Refusals write nothing.
    v_res := save_drug_stock_entry('nurse.b', NULL, false, ARRAY['heart360tk_facility_view_patients_fac_b'],
        301, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'no access: %', v_res; END IF;
    v_res := save_drug_stock_entry('nobody', NULL, false, ARRAY[]::text[],
        301, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'no teams: %', v_res; END IF;
    v_res := save_drug_stock_entry('dist', NULL, false, TEAM_DST,
        200, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'not_facility' THEN RAISE EXCEPTION 'district: %', v_res; END IF;
    v_res := save_drug_stock_entry('nurse.a', NULL, false, TEAM_A,
        401, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'not_facility' THEN RAISE EXCEPTION 'sub-facility: %', v_res; END IF;
    v_res := save_drug_stock_entry('dist', NULL, false, TEAM_DST,
        303, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'not_facility' THEN RAISE EXCEPTION 'not in cohort: %', v_res; END IF;
    v_res := save_drug_stock_entry('admin', NULL, true, ARRAY[]::text[],
        999, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'missing place: %', v_res; END IF;
    v_res := save_drug_stock_entry('nurse.a', NULL, false, TEAM_A,
        301, (date_trunc('month', now()) + interval '1 month')::date, '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'bad_month' THEN RAISE EXCEPTION 'future month: %', v_res; END IF;
    v_res := save_drug_stock_entry('nurse.a', NULL, false, TEAM_A,
        301, '2026-10-15', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'bad_month' THEN RAISE EXCEPTION 'mid month: %', v_res; END IF;
    v_res := save_drug_stock_entry('nurse.a', NULL, false, TEAM_A, 301, '2026-10-01', '[]');
    IF v_res->>'error' IS DISTINCT FROM 'bad_request' THEN RAISE EXCEPTION 'empty: %', v_res; END IF;
    v_res := save_drug_stock_entry(' ', NULL, false, TEAM_A, 301, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
    IF v_res->>'error' IS DISTINCT FROM 'bad_request' THEN RAISE EXCEPTION 'no login: %', v_res; END IF;

    SELECT count(*) INTO v_hist2 FROM drug_stock_submission_history;
    IF v_hist2 <> v_hist THEN RAISE EXCEPTION 'a refusal wrote % history rows', v_hist2 - v_hist; END IF;

    -- Latest Wins over the older submission; blank stays unknown, 0 stays zero; bad entries rejected.
    v_res := save_drug_stock_entry('nurse.a', ' Nurse.A@Example.ORG ', false, TEAM_A, 301, '2026-10-01', '[
        {"drug_code":"329528","stock":123},
        {"drug_code":"316764","stock":null},
        {"drug_code":"331132","stock":0},
        {"drug_code":"197499"},
        {"drug_code":"999999","stock":5},
        {"drug_code":"329528","stock":7},
        {"drug_code":"316765","stock":1.5},
        {"drug_code":"329526","stock":-1},
        {"drug_code":"329526","stock":1000001},
        {"drug_code":"329526","stock":"12"}
    ]');
    IF v_res->>'ok' <> 'true'
       OR (v_res->>'accepted')::int <> 4 OR (v_res->>'rejected')::int <> 6
       OR (v_res->>'stored')::int <> 4 OR (v_res->>'kept_newer')::int <> 0 THEN
        RAISE EXCEPTION 'save counts: %', v_res;
    END IF;
    IF NOT (v_res->'rejects' @> '[{"drug_code":"999999","reason":"not_protocol_drug"},
                                  {"drug_code":"329528","reason":"repeated_drug"},
                                  {"drug_code":"316765","reason":"invalid_stock"}]') THEN
        RAISE EXCEPTION 'rejects: %', v_res->'rejects';
    END IF;

    FOR v_row IN
        SELECT * FROM (VALUES ('329528', 123::numeric), ('316764', NULL), ('331132', 0), ('197499', NULL)) AS e(code, want)
    LOOP
        SELECT count(*) INTO v_sub
        FROM drug_stock_submission s
        WHERE s.org_unit_id = 301 AND s.reporting_month = '2026-10-01' AND s.rxnorm_code = v_row.code
          AND s.in_stock IS NOT DISTINCT FROM v_row.want
          AND s.submitted_by = 'nurse.a@example.org'
          AND s.submitted_at = now()
          AND s.sheet_row IS NULL;
        IF v_sub <> 1 THEN
            RAISE EXCEPTION 'current row for % is not % by nurse.a@example.org at now()', v_row.code, v_row.want;
        END IF;
    END LOOP;

    SELECT count(*) INTO v_hist2 FROM drug_stock_submission_history;
    IF v_hist2 <> v_hist + 4 THEN RAISE EXCEPTION 'history grew by %, want 4', v_hist2 - v_hist; END IF;
    -- The older 2026-10-08 rows stay in history.
    IF NOT EXISTS (SELECT 1 FROM drug_stock_submission_history h
                   WHERE h.org_unit_id = 301 AND h.rxnorm_code = '329528' AND h.in_stock = 40) THEN
        RAISE EXCEPTION 'older history row is gone';
    END IF;
    -- Rejected entries are not written anywhere.
    IF (SELECT count(*) FROM drug_stock_submission_reject) <> v_rej THEN
        RAISE EXCEPTION 'rejected form entries reached drug_stock_submission_reject';
    END IF;
    IF EXISTS (SELECT 1 FROM drug_stock_submission WHERE org_unit_id = 301 AND rxnorm_code IN ('316765', '329526')) THEN
        RAISE EXCEPTION 'an invalid stock was stored';
    END IF;

    -- A newer submission stays; the form row goes to history only.
    v_res := save_drug_stock_entry('nurse.a', NULL, false, TEAM_A, 301, '2026-09-01',
        '[{"drug_code":"329528","stock":55}]');
    IF (v_res->>'accepted')::int <> 1 OR (v_res->>'stored')::int <> 0 OR (v_res->>'kept_newer')::int <> 1 THEN
        RAISE EXCEPTION 'newer kept counts: %', v_res;
    END IF;
    IF (SELECT in_stock FROM drug_stock_submission
        WHERE org_unit_id = 301 AND reporting_month = '2026-09-01' AND rxnorm_code = '329528') <> 9 THEN
        RAISE EXCEPTION 'the newer submission was replaced';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM drug_stock_submission_history h
                   WHERE h.org_unit_id = 301 AND h.reporting_month = '2026-09-01'
                     AND h.in_stock = 55 AND h.submitted_by = 'nurse.a') THEN
        RAISE EXCEPTION 'older form save missing from history, or submitted_by is not the login';
    END IF;

    -- An _ALL team at facility level or above may save; an admin may save.
    v_res := save_drug_stock_entry('all', NULL, false, ARRAY['heart360tk_district_view_patients_ALL'],
        302, '2026-10-01', '[{"drug_code":"329528","stock":3}]');
    IF v_res->>'ok' <> 'true' THEN RAISE EXCEPTION '_ALL team: %', v_res; END IF;
    v_res := save_drug_stock_entry('admin', NULL, true, ARRAY[]::text[],
        302, '2026-10-01', '[{"drug_code":"329528","stock":4}]');
    IF v_res->>'ok' <> 'true' OR (v_res->>'stored')::int <> 1 THEN RAISE EXCEPTION 'admin: %', v_res; END IF;
END $$;
SQL

echo "assert heart360tk_reader cannot execute"
if out="$(psql_db 2>&1 <<'SQL'
SET ROLE heart360tk_reader;
SELECT heart360tk_schema.save_drug_stock_entry('x', NULL, true, ARRAY[]::text[], 301, '2026-10-01', '[{"drug_code":"329528","stock":1}]');
SQL
)"; then
    echo "heart360tk_reader executed save_drug_stock_entry" >&2
    exit 1
elif ! grep -q 'permission denied' <<< "$out"; then
    echo "unexpected error for heart360tk_reader: $out" >&2
    exit 1
fi

echo "assert h360_api can execute"
psql_db >/dev/null <<'SQL'
SET ROLE h360_api;
SELECT heart360tk_schema.save_drug_stock_entry('nurse.a', NULL, false,
    ARRAY['heart360tk_facility_view_patients_fac_a'], 301, '2026-08-01', '[{"drug_code":"329528","stock":2}]');
SQL

echo "PASS verify_drug_stock_entry"
