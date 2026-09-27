#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION_11="$ROOT/pg_init_scripts/migrations/0.5.1_to_0.5.2.sql"
MIGRATION_12="$ROOT/pg_init_scripts/migrations/0.5.2_to_0.5.3.sql"
MIGRATION_13="$ROOT/pg_init_scripts/migrations/0.5.3_to_0.5.4.sql"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
PULL="$ROOT/drug_stock/pull/pull.py"
FIXTURE="$ROOT/drug_stock/pull/fixture_long_rows.json"
CONTRACT="$ROOT/drug_stock/pull/env.contract.json"
DB_NAME="${DRUG_STOCK_PULL_VERIFY_DB:-drug_stock_pull_verify}"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$MIGRATION_11" "$MIGRATION_12" "$MIGRATION_13" "$TABLES" "$PULL" "$FIXTURE" "$CONTRACT"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

choose_psql() {
    local mode="${DRUG_STOCK_PSQL_MODE:-auto}"
    if [[ "$mode" == "sudo" || "$mode" == "auto" ]]; then
        if sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
            PSQL=(sudo -n -u postgres psql)
            DRUG_STOCK_PSQL_MODE=sudo
            echo "psql mode: sudo -u postgres"
            return
        fi
        if [[ "$mode" == "sudo" ]]; then
            echo "verifier-blocked: sudo -u postgres psql failed" >&2
            exit 1
        fi
    fi
    if [[ "$mode" == "local" || "$mode" == "auto" ]]; then
        if psql -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
            PSQL=(psql)
            DRUG_STOCK_PSQL_MODE=local
            echo "psql mode: local"
            return
        fi
    fi
    echo "verifier-blocked: neither sudo -u postgres nor local psql can connect" >&2
    exit 1
}

choose_psql
export DRUG_STOCK_PSQL_MODE

drop_db() {
    "${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null
    "${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c \
        "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
}

cleanup() {
    drop_db || true
    "${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS grafana;" >/dev/null || true
}

trap cleanup EXIT

drop_db
"${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 <<SQL
DROP ROLE IF EXISTS grafana;
DROP ROLE IF EXISTS heart360tk;
CREATE ROLE heart360tk LOGIN;
CREATE ROLE grafana LOGIN;
CREATE DATABASE ${DB_NAME} OWNER heart360tk;
SQL

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
CREATE SCHEMA heart360tk_schema AUTHORIZATION heart360tk;
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
CREATE TABLE org_units (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    level       INTEGER NOT NULL,
    parent_id   INTEGER REFERENCES org_units(id)
);
SQL

echo "apply 1.1"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_11" >/dev/null
echo "apply 1.2"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_12" >/dev/null
echo "apply 1.3"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_13" >/dev/null
echo "apply 1.3 again"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_13" >/dev/null

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;
INSERT INTO org_units (id, name, level, parent_id) VALUES (11, 'Alpha Facility', 3, NULL);

DO $$
DECLARE
    v_columns text;
    v_pk text;
    v_long int;
BEGIN
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_schema'
      AND table_name = 'drug_stock_submission';
    IF v_columns IS DISTINCT FROM
        'org_unit_id,reporting_month,rxnorm_code,country_code,programme_code,in_stock,submitted_at,pulled_at'
    THEN
        RAISE EXCEPTION 'submission columns are [%]', v_columns;
    END IF;

    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_schema'
      AND table_name = 'drug_stock_submission_reject';
    IF v_columns IS DISTINCT FROM
        'org_unit_id,reporting_month,drug_code,in_stock,submitted_at,reason,pulled_at'
    THEN
        RAISE EXCEPTION 'reject columns are [%]', v_columns;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'heart360tk_schema'
          AND table_name = 'drug_stock_submission'
          AND column_name = 'in_stock'
          AND is_nullable <> 'YES'
    ) OR EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'heart360tk_schema'
          AND table_name = 'drug_stock_submission'
          AND column_name = 'pulled_at'
          AND is_nullable <> 'NO'
    ) THEN
        RAISE EXCEPTION 'in_stock must be nullable and pulled_at must be required';
    END IF;

    SELECT string_agg(a.attname, ',' ORDER BY u.ord)
    INTO v_pk
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS u(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = u.attnum
    WHERE c.conrelid = 'heart360tk_schema.drug_stock_submission'::regclass
      AND c.contype = 'p';
    IF v_pk IS DISTINCT FROM 'org_unit_id,reporting_month,rxnorm_code' THEN
        RAISE EXCEPTION 'submission primary key is [%]', v_pk;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class ref ON ref.oid = c.confrelid
        WHERE c.conrelid = 'heart360tk_schema.drug_stock_submission'::regclass
          AND c.contype = 'f'
          AND ref.relname = 'org_units'
    ) THEN
        RAISE EXCEPTION 'submission does not reference org_units';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class ref ON ref.oid = c.confrelid
        WHERE c.conrelid = 'heart360tk_schema.drug_stock_submission'::regclass
          AND c.contype = 'f'
          AND ref.relname = 'protocol_drugs'
    ) THEN
        RAISE EXCEPTION 'submission does not reference protocol_drugs';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'heart360tk_schema.drug_stock_submission_reject'::regclass
          AND contype = 'f'
    ) THEN
        RAISE EXCEPTION 'reject table has a foreign key';
    END IF;

    SELECT COUNT(*) INTO v_long
    FROM drug_stock_form_long_rows('{"facility":11,"reporting_month":"2026-09"}'::jsonb);
    IF v_long <> 6 THEN
        RAISE EXCEPTION 'form long rows returned %', v_long;
    END IF;
END $$;
SQL

pull_env() {
    env -u DRUG_STOCK_FIXTURE_PATH \
        -u DRUG_STOCK_SHEET_ID \
        -u DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS \
        -u DRUG_STOCK_SHEET_RANGE \
        DRUG_STOCK_PSQL_MODE="$DRUG_STOCK_PSQL_MODE" \
        DRUG_STOCK_PULL_DB="$DB_NAME" \
        "$@" \
        python3 "$PULL"
}

expect_fail() {
    local label="$1"
    local needle="$2"
    shift 2
    local out status
    set +e
    out="$("$@" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        echo "$label exited 0" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if [[ "$out" != *"$needle"* ]]; then
        echo "$label did not report $needle" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

expect_ok() {
    local label="$1"
    local needle="$2"
    shift 2
    local out status
    set +e
    out="$("$@" 2>&1)"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
        echo "$label exited $status" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if [[ "$out" != *"$needle"* ]]; then
        echo "$label did not report $needle" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

submission_count() {
    "${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -c \
        "SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission;"
}

echo "no source"
expect_fail "unconfigured pull" "no drug stock source configured" pull_env >/dev/null
if [[ "$(submission_count)" != "0" ]]; then
    echo "unconfigured pull wrote submission rows" >&2
    exit 1
fi

echo "missing fixture"
expect_fail "missing fixture" "fixture not found" \
    pull_env DRUG_STOCK_FIXTURE_PATH="$ROOT/drug_stock/pull/no-such-fixture.json" >/dev/null
if [[ "$(submission_count)" != "0" ]]; then
    echo "missing fixture wrote submission rows" >&2
    exit 1
fi

EMPTY_SA="$(mktemp)"
printf '%s\n' '{}' > "$EMPTY_SA"
echo "invalid service account"
expect_fail "invalid service account" "service account file is not valid" \
    pull_env DRUG_STOCK_SHEET_ID=missing DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS="$EMPTY_SA" >/dev/null
if [[ "$(submission_count)" != "0" ]]; then
    echo "invalid service account wrote submission rows" >&2
    exit 1
fi

echo "fixture pull"
expect_ok "fixture pull" "accepted=3 rejected=2" \
    pull_env \
        DRUG_STOCK_FIXTURE_PATH="$FIXTURE" \
        DRUG_STOCK_SHEET_ID=missing \
        DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS="$ROOT/drug_stock/pull/no-such-sa.json"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM drug_stock_submission) <> 3 THEN
        RAISE EXCEPTION 'expected 3 submission rows';
    END IF;
    IF EXISTS (SELECT 1 FROM drug_stock_submission WHERE org_unit_id = 999) THEN
        RAISE EXCEPTION 'unknown org_unit entered stock';
    END IF;
    IF EXISTS (SELECT 1 FROM drug_stock_submission WHERE rxnorm_code = '999999') THEN
        RAISE EXCEPTION 'inactive drug entered stock';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '329528'
          AND (
              in_stock IS NOT NULL
              OR reporting_month IS DISTINCT FROM DATE '2026-09-01'
              OR submitted_at IS DISTINCT FROM TIMESTAMPTZ '2026-09-20T01:00:00Z'
              OR country_code IS DISTINCT FROM 'India'
              OR programme_code IS DISTINCT FROM 'IHCI'
          )
    ) THEN
        RAISE EXCEPTION 'blank in_stock row was not stored';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '329526'
          AND (
              in_stock IS DISTINCT FROM 0
              OR submitted_at IS NOT NULL
              OR country_code IS DISTINCT FROM 'India'
              OR programme_code IS DISTINCT FROM 'IHCI'
          )
    ) THEN
        RAISE EXCEPTION 'text 0 was not stored as 0';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '316764'
          AND in_stock IS NOT NULL
    ) THEN
        RAISE EXCEPTION '? was not stored as null';
    END IF;
    IF (SELECT COUNT(*) FROM drug_stock_submission WHERE in_stock = 0) <> 1 THEN
        RAISE EXCEPTION 'zero stock count drifted';
    END IF;
    IF (SELECT COUNT(*) FROM drug_stock_submission WHERE in_stock IS NULL) <> 2 THEN
        RAISE EXCEPTION 'null stock count drifted';
    END IF;
    IF (
        SELECT COUNT(*) FROM drug_stock_submission_reject
        WHERE reason = 'unknown_org_unit'
          AND org_unit_id = '999'
          AND drug_code = '329528'
          AND in_stock = '3'
    ) <> 1 THEN
        RAISE EXCEPTION 'unknown org_unit was not quarantined';
    END IF;
    IF (
        SELECT COUNT(*) FROM drug_stock_submission_reject
        WHERE reason = 'drug_not_active'
          AND org_unit_id = '11'
          AND drug_code = '999999'
          AND in_stock = '4'
    ) <> 1 THEN
        RAISE EXCEPTION 'inactive drug was not quarantined';
    END IF;
    IF EXISTS (SELECT 1 FROM drug_stock_submission WHERE pulled_at IS NULL)
       OR EXISTS (SELECT 1 FROM drug_stock_submission_reject WHERE pulled_at IS NULL) THEN
        RAISE EXCEPTION 'pulled_at was null';
    END IF;
END $$;
SQL

echo "repeat fixture"
expect_ok "repeat fixture" "accepted=3 rejected=2" \
    pull_env DRUG_STOCK_FIXTURE_PATH="$FIXTURE"
reject_count="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -c \
    "SELECT COUNT(*) FROM heart360tk_schema.drug_stock_submission_reject;")"
if [[ "$reject_count" != "2" ]]; then
    echo "repeat fixture changed the reject count to $reject_count" >&2
    exit 1
fi

SECOND="$(mktemp)"
cat > "$SECOND" <<'JSON'
[
  {
    "org_unit_id": "11",
    "reporting_month": "2026-09-01",
    "drug_code": "329528",
    "in_stock": "8",
    "submitted_at": "2026-09-27T10:15:00Z"
  }
]
JSON

sleep 0.2
echo "latest wins"
expect_ok "latest wins" "accepted=1 rejected=0" \
    pull_env DRUG_STOCK_FIXTURE_PATH="$SECOND"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM drug_stock_submission) <> 3 THEN
        RAISE EXCEPTION 'latest wins inserted an extra row';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '329528'
          AND (
              in_stock IS DISTINCT FROM 8
              OR submitted_at IS DISTINCT FROM TIMESTAMPTZ '2026-09-27T10:15:00Z'
          )
    ) THEN
        RAISE EXCEPTION 'latest wins did not replace in_stock and submitted_at';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '329526'
          AND (in_stock IS DISTINCT FROM 0 OR submitted_at IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'latest wins changed a key that was not in the pull';
    END IF;
    IF (
        SELECT pulled_at FROM drug_stock_submission WHERE rxnorm_code = '329528'
    ) <= (
        SELECT pulled_at FROM drug_stock_submission WHERE rxnorm_code = '329526'
    ) THEN
        RAISE EXCEPTION 'latest wins did not replace pulled_at';
    END IF;
END $$;
SQL

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;
INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
VALUES ('Testland', 'DEMO', 'AATTCC');
INSERT INTO protocol_drugs (
    country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked
) VALUES (
    'Testland', 'DEMO', 'Amlodipine', '5 mg', '329528', 'CCB', TRUE
);
UPDATE deploy_setting
SET country_code = 'Testland', programme_code = 'DEMO'
WHERE setting_name = 'active_programme';
SQL

THIRD="$(mktemp)"
cat > "$THIRD" <<'JSON'
[
  {
    "org_unit_id": "11",
    "reporting_month": "2026-09-01",
    "drug_code": "329528",
    "in_stock": "2",
    "submitted_at": "2026-09-28T08:00:00Z"
  }
]
JSON

echo "programme stamp"
expect_ok "programme stamp" "accepted=1 rejected=0" \
    pull_env DRUG_STOCK_FIXTURE_PATH="$THIRD"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '329528'
          AND (
              country_code IS DISTINCT FROM 'Testland'
              OR programme_code IS DISTINCT FROM 'DEMO'
              OR in_stock IS DISTINCT FROM 2
              OR submitted_at IS DISTINCT FROM TIMESTAMPTZ '2026-09-28T08:00:00Z'
          )
    ) THEN
        RAISE EXCEPTION 'programme columns were not taken from active_programme';
    END IF;
    IF EXISTS (
        SELECT 1 FROM drug_stock_submission
        WHERE rxnorm_code = '329526'
          AND (country_code IS DISTINCT FROM 'India' OR programme_code IS DISTINCT FROM 'IHCI')
    ) THEN
        RAISE EXCEPTION 'untouched key changed programme';
    END IF;
END $$;
SQL

dump_state() {
    "${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -F $'\t' -c \
        "SELECT org_unit_id::text, reporting_month::text, rxnorm_code, country_code, programme_code, COALESCE(in_stock::text, '<null>'), COALESCE(submitted_at::text, '<null>'), pulled_at::text FROM heart360tk_schema.drug_stock_submission ORDER BY 1, 2, 3;"
    echo '---'
    "${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -F $'\t' -c \
        "SELECT COALESCE(org_unit_id, '<null>'), COALESCE(reporting_month, '<null>'), COALESCE(drug_code, '<null>'), COALESCE(in_stock, '<null>'), COALESCE(submitted_at, '<null>'), reason, pulled_at::text FROM heart360tk_schema.drug_stock_submission_reject ORDER BY 1, 2, 3, 6;"
}

SNAPSHOT="$(mktemp)"
dump_state > "$SNAPSHOT"

echo "apply 1.3 with rows"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_13" >/dev/null
AFTER="$(mktemp)"
dump_state > "$AFTER"
if ! diff -u "$SNAPSHOT" "$AFTER" >/dev/null; then
    echo "reapplying 1.3 changed stored rows" >&2
    diff -u "$SNAPSHOT" "$AFTER" >&2 || true
    exit 1
fi

echo "failed fixture"
expect_fail "failed fixture" "fixture not found" \
    pull_env DRUG_STOCK_FIXTURE_PATH="$ROOT/drug_stock/pull/no-such-fixture.json" >/dev/null
dump_state > "$AFTER"
if ! diff -u "$SNAPSHOT" "$AFTER" >/dev/null; then
    echo "missing fixture changed stored rows" >&2
    diff -u "$SNAPSHOT" "$AFTER" >&2 || true
    exit 1
fi

BAD_JSON="$(mktemp)"
printf '%s\n' '{' > "$BAD_JSON"
echo "invalid fixture"
expect_fail "invalid fixture" "fixture is not valid JSON" \
    pull_env DRUG_STOCK_FIXTURE_PATH="$BAD_JSON" >/dev/null
dump_state > "$AFTER"
if ! diff -u "$SNAPSHOT" "$AFTER" >/dev/null; then
    echo "invalid fixture changed stored rows" >&2
    diff -u "$SNAPSHOT" "$AFTER" >&2 || true
    exit 1
fi

echo "failed service account"
expect_fail "failed service account" "service account file is not valid" \
    pull_env DRUG_STOCK_SHEET_ID=missing DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS="$EMPTY_SA" >/dev/null
dump_state > "$AFTER"
if ! diff -u "$SNAPSHOT" "$AFTER" >/dev/null; then
    echo "invalid service account changed stored rows" >&2
    diff -u "$SNAPSHOT" "$AFTER" >&2 || true
    exit 1
fi

echo "sheet id only"
expect_fail "sheet id only" "sheet pull needs DRUG_STOCK_SHEET_ID and DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS" \
    pull_env DRUG_STOCK_SHEET_ID=missing >/dev/null
dump_state > "$AFTER"
if ! diff -u "$SNAPSHOT" "$AFTER" >/dev/null; then
    echo "sheet id only changed stored rows" >&2
    diff -u "$SNAPSHOT" "$AFTER" >&2 || true
    exit 1
fi

echo "grafana insert"
set +e
GRAFANA_OUT="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
    "GRANT USAGE ON SCHEMA heart360tk_schema TO grafana; SET ROLE grafana; INSERT INTO heart360tk_schema.drug_stock_submission (org_unit_id, reporting_month, rxnorm_code, country_code, programme_code, in_stock, submitted_at, pulled_at) VALUES (11, DATE '2026-09-01', '329528', 'Testland', 'DEMO', 1, NULL, TIMESTAMPTZ '2026-01-01T00:00:00Z');" 2>&1)"
GRAFANA_STATUS=$?
set -e
if [[ $GRAFANA_STATUS -eq 0 ]]; then
    echo "grafana inserted into drug_stock_submission" >&2
    exit 1
fi
if [[ "$GRAFANA_OUT" != *"permission denied"* ]]; then
    echo "grafana insert failed for a different reason" >&2
    printf '%s\n' "$GRAFANA_OUT" >&2
    exit 1
fi
printf '%s\n' "$GRAFANA_OUT"

echo "grafana function"
set +e
GRAFANA_FN="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
    "SET ROLE grafana; SELECT * FROM heart360tk_schema.drug_stock_pull_apply('[{\"org_unit_id\":\"11\",\"reporting_month\":\"2026-09-01\",\"drug_code\":\"329528\",\"in_stock\":\"1\"}]'::jsonb);" 2>&1)"
GRAFANA_FN_STATUS=$?
set -e
if [[ $GRAFANA_FN_STATUS -eq 0 ]]; then
    echo "grafana executed drug_stock_pull_apply" >&2
    exit 1
fi
if [[ "$GRAFANA_FN" != *"permission denied"* && "$GRAFANA_FN" != *"must be heart360tk"* ]]; then
    echo "grafana function call failed for a different reason" >&2
    printf '%s\n' "$GRAFANA_FN" >&2
    exit 1
fi

dump_state > "$AFTER"
if ! diff -u "$SNAPSHOT" "$AFTER" >/dev/null; then
    echo "grafana attempt changed stored rows" >&2
    diff -u "$SNAPSHOT" "$AFTER" >&2 || true
    exit 1
fi

python3 - "$PULL" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("drug_stock_pull", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
rows = mod.rows_from_sheet_values([
    ["org_unit_id", "reporting_month", "drug_code", "in_stock", "submitted_at"],
    ["11", "2026-09-18", "329528", "", "2026-09-20T01:00:00Z"],
    ["", "", "", "", ""],
    ["12", "2026-08", "329526", "0"],
])
expected = [
    {
        "org_unit_id": "11",
        "reporting_month": "2026-09-18",
        "drug_code": "329528",
        "in_stock": "",
        "submitted_at": "2026-09-20T01:00:00Z",
    },
    {
        "org_unit_id": "12",
        "reporting_month": "2026-08",
        "drug_code": "329526",
        "in_stock": "0",
        "submitted_at": "",
    },
]
if rows != expected:
    raise SystemExit(f"sheet values parsed as {rows}")
print("sheet values parsed")
PY

if grep -E -n 'BEGIN PRIVATE KEY' "$MIGRATION_13" "$PULL" "$FIXTURE" "$CONTRACT" "$TABLES"; then
    echo "credential-like text is present" >&2
    exit 1
fi

python3 - "$TABLES" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
second = next(i for i, line in enumerate(lines) if line.strip() == r"\ir migrations/0.5.2_to_0.5.3.sql")
third = next(i for i, line in enumerate(lines) if line.strip() == r"\ir migrations/0.5.3_to_0.5.4.sql")
if third != second + 1:
    raise SystemExit(f"include order is line {second + 1} then line {third + 1}")
print("include line follows 0.5.2_to_0.5.3.sql")
PY

rm -f "$EMPTY_SA" "$SECOND" "$THIRD" "$BAD_JSON" "$SNAPSHOT" "$AFTER"
echo "drug stock pull verified"
