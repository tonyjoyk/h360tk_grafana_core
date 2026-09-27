#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION_11="$ROOT/pg_init_scripts/migrations/0.5.1_to_0.5.2.sql"
MIGRATION_12="$ROOT/pg_init_scripts/migrations/0.5.2_to_0.5.3.sql"
SPEC="$ROOT/drug_stock/form/form_field_spec.json"
SHEET_MAP="$ROOT/drug_stock/form/wide_to_long.json"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
DB_NAME="${DRUG_STOCK_FORM_VERIFY_DB:-drug_stock_form_cohort_verify}"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$MIGRATION_11" "$MIGRATION_12" "$SPEC" "$SHEET_MAP" "$TABLES"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

choose_psql() {
    local mode="${DRUG_STOCK_PSQL_MODE:-auto}"
    if [[ "$mode" == "sudo" || "$mode" == "auto" ]]; then
        if sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
            PSQL=(sudo -u postgres psql)
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
            echo "psql mode: local"
            return
        fi
    fi
    echo "verifier-blocked: neither sudo -u postgres nor local psql can connect" >&2
    exit 1
}

choose_psql

drop_db() {
    "${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null
    "${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c \
        "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
}

drop_db
"${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 <<SQL
DROP ROLE IF EXISTS heart360tk;
CREATE ROLE heart360tk LOGIN;
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

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (1, 'State', 1, NULL),
    (2, 'North District', 2, 1),
    (3, 'South District', 2, 1);
INSERT INTO org_units (id, name, level, parent_id) VALUES
    (11, 'Alpha Facility', 3, 2),
    (12, 'Alpha Facility', 3, 3),
    (10, 'Zeta Facility', 3, 2),
    (13, 'Beta Facility', 3, 2),
    (20, 'Community Site', 4, 11);

INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (10), (11), (12);
SQL

echo "export"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
    "SELECT id, name FROM heart360tk_schema.drug_stock_form_facility_export;"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
DECLARE
    r RECORD;
    v_lines TEXT := '';
    v_columns TEXT;
    v_codes TEXT;
BEGIN
    IF (
        SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'heart360tk_schema'
          AND table_name = 'drug_stock_form_cohort'
    ) IS DISTINCT FROM 'org_unit_id' THEN
        RAISE EXCEPTION 'drug_stock_form_cohort columns are not org_unit_id only';
    END IF;

    IF (
        SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'heart360tk_schema'
          AND table_name = 'drug_stock_form_facility_export'
    ) IS DISTINCT FROM 'id,name' THEN
        RAISE EXCEPTION 'facility export columns are not id, name';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class ref ON ref.oid = c.confrelid
        WHERE c.conrelid = 'heart360tk_schema.drug_stock_form_cohort'::regclass
          AND c.contype = 'f'
          AND ref.relname = 'org_units'
    ) THEN
        RAISE EXCEPTION 'cohort does not reference org_units';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'heart360tk_schema'
          AND table_name IN ('drug_stock_form_cohort', 'org_units')
          AND column_name IN ('received', 'consumption', 'size')
    ) THEN
        RAISE EXCEPTION 'received, consumption, or size column is present';
    END IF;

    FOR r IN
        SELECT id, name FROM drug_stock_form_facility_export
    LOOP
        v_lines := v_lines || r.id::text || '|' || r.name || E'\n';
    END LOOP;

    IF v_lines IS DISTINCT FROM E'11|Alpha Facility\n12|Alpha Facility\n10|Zeta Facility\n' THEN
        RAISE EXCEPTION 'export was [%]', v_lines;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM drug_stock_form_facility_export e
        JOIN org_units ou ON ou.id = e.id
        WHERE e.name IS DISTINCT FROM ou.name
    ) THEN
        RAISE EXCEPTION 'export name is not org_units.name';
    END IF;

    SELECT string_agg(rxnorm_code, ',' ORDER BY rxnorm_code)
    INTO v_codes
    FROM active_stock_tracked_drugs;

    IF v_codes IS DISTINCT FROM '197499,316764,316765,329526,329528,331132' THEN
        RAISE EXCEPTION 'active rxnorm codes are [%]', v_codes;
    END IF;

    CREATE TEMP TABLE long_probe AS
    SELECT *
    FROM drug_stock_form_long_rows('{"facility":11,"reporting_month":"2026-09-01"}'::jsonb)
    WHERE false;

    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_columns
    FROM information_schema.columns
    WHERE table_name = 'long_probe';

    IF v_columns IS DISTINCT FROM 'org_unit_id,reporting_month,drug_code,in_stock,submitted_at' THEN
        RAISE EXCEPTION 'long row columns are [%]', v_columns;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'long_probe'
          AND column_name IN ('received', 'consumption')
    ) THEN
        RAISE EXCEPTION 'long row has a received or consumption column';
    END IF;
END $$;

DO $$
BEGIN
    INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (999999);
    RAISE EXCEPTION 'cohort accepted an org_unit_id that is not in org_units';
EXCEPTION
    WHEN foreign_key_violation THEN
        NULL;
END $$;
SQL

echo "long rows"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

SELECT org_unit_id, reporting_month, drug_code, in_stock, submitted_at
FROM drug_stock_form_long_rows('{
  "facility": 11,
  "reporting_month": "2026-09-18",
  "submitted_at": "2026-09-27T10:15:00Z",
  "329528": "",
  "329526": 0,
  "316764": "4",
  "316765": null,
  "331132": "  ",
  "197499": "0",
  "received": 9,
  "consumption": 3
}'::jsonb);

DO $$
DECLARE
    r RECORD;
    v_lines TEXT := '';
    v_count INT;
    v_filled INT;
    v_month DATE;
    v_submitted INT;
BEGIN
    FOR r IN
        SELECT org_unit_id, reporting_month, drug_code, in_stock, submitted_at
        FROM drug_stock_form_long_rows('{
          "facility": 11,
          "reporting_month": "2026-09-18",
          "submitted_at": "2026-09-27T10:15:00Z",
          "329528": "",
          "329526": 0,
          "316764": "4",
          "316765": null,
          "331132": "  ",
          "197499": "0",
          "received": 9,
          "consumption": 3
        }'::jsonb)
        ORDER BY drug_code
    LOOP
        v_lines := v_lines
            || r.drug_code || '|'
            || coalesce(r.in_stock::text, '') || '|'
            || r.reporting_month::text || '|'
            || r.org_unit_id::text || '|'
            || to_char(r.submitted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            || E'\n';
    END LOOP;

    IF v_lines IS DISTINCT FROM
        E'197499|0|2026-09-01|11|2026-09-27T10:15:00Z\n'
        || E'316764|4|2026-09-01|11|2026-09-27T10:15:00Z\n'
        || E'316765||2026-09-01|11|2026-09-27T10:15:00Z\n'
        || E'329526|0|2026-09-01|11|2026-09-27T10:15:00Z\n'
        || E'329528||2026-09-01|11|2026-09-27T10:15:00Z\n'
        || E'331132||2026-09-01|11|2026-09-27T10:15:00Z\n'
    THEN
        RAISE EXCEPTION 'long rows were [%]', v_lines;
    END IF;

    SELECT COUNT(*), COUNT(in_stock), MIN(reporting_month), COUNT(submitted_at)
    INTO v_count, v_filled, v_month, v_submitted
    FROM drug_stock_form_long_rows('{"facility":"11","reporting_month":"2026-01"}'::jsonb);

    IF v_count <> 6 OR v_filled <> 0 OR v_month IS DISTINCT FROM DATE '2026-01-01' OR v_submitted <> 0 THEN
        RAISE EXCEPTION 'blank month row was count % filled % month % submitted %',
            v_count, v_filled, v_month, v_submitted;
    END IF;
END $$;

DO $$
BEGIN
    PERFORM 1
    FROM drug_stock_form_long_rows('{"facility":"Alpha Facility","reporting_month":"2026-09"}'::jsonb);
    RAISE EXCEPTION 'facility name was accepted';
EXCEPTION
    WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%org_units.id%' THEN
            RAISE;
        END IF;
END $$;

DO $$
BEGIN
    PERFORM 1
    FROM drug_stock_form_long_rows('{"facility":11,"reporting_month":"2026-09","329528":"abc"}'::jsonb);
    RAISE EXCEPTION 'non-numeric in_stock was accepted';
EXCEPTION
    WHEN invalid_text_representation THEN
        NULL;
END $$;

DO $$
BEGIN
    PERFORM 1
    FROM drug_stock_form_long_rows('{"facility":11}'::jsonb);
    RAISE EXCEPTION 'missing reporting_month was accepted';
EXCEPTION
    WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%reporting_month is required%' THEN
            RAISE;
        END IF;
END $$;
SQL

echo "apply 1.2 again"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_12" >/dev/null

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    r RECORD;
    v_lines TEXT := '';
BEGIN
    FOR r IN
        SELECT id, name FROM heart360tk_schema.drug_stock_form_facility_export
    LOOP
        v_lines := v_lines || r.id::text || '|' || r.name || E'\n';
    END LOOP;
    IF v_lines IS DISTINCT FROM E'11|Alpha Facility\n12|Alpha Facility\n10|Zeta Facility\n' THEN
        RAISE EXCEPTION 'second apply changed the export to [%]', v_lines;
    END IF;
END $$;
SQL

ACTIVE_TSV="$(mktemp)"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -F $'\t' -c \
"SELECT rxnorm_code, drug_name, dosage, drug_category FROM heart360tk_schema.active_stock_tracked_drugs ORDER BY rxnorm_code" \
> "$ACTIVE_TSV"

python3 - "$SPEC" "$SHEET_MAP" "$ACTIVE_TSV" <<'PY'
import json
import sys

spec = json.load(open(sys.argv[1]))
sheet = json.load(open(sys.argv[2]))
errors = []

confirmation = "Your stock report was received. You can close this form or submit another month."
if spec.get("success_confirmation") != confirmation:
    errors.append("success confirmation mismatch")
if spec.get("resubmit_allowed") is not True:
    errors.append("resubmit_allowed is not true")
if spec.get("drug_fields_from") != "heart360tk_schema.active_stock_tracked_drugs":
    errors.append("drug fields do not come from active_stock_tracked_drugs")
if spec.get("facility_options_from") != "heart360tk_schema.drug_stock_form_facility_export":
    errors.append("facility options do not come from the cohort export")

fields = spec.get("fields") or []
if len(fields) < 2:
    errors.append("facility and reporting month fields are missing")
else:
    facility, month = fields[0], fields[1]
    if (
        facility.get("key") != "facility"
        or facility.get("label") != "Facility"
        or facility.get("required") is not True
        or facility.get("value") != "org_units.id"
        or facility.get("choice_label") != "org_units.name"
    ):
        errors.append("facility field is not org_units.id with name as the label")
    if (
        month.get("key") != "reporting_month"
        or month.get("label") != "Reporting Month"
        or month.get("required") is not True
    ):
        errors.append("reporting month field is missing or optional")

banned = {"received", "consumption"}
if {field.get("key") for field in fields} & banned:
    errors.append("form has a received or consumption field")

rows = spec.get("in_stock_fields") or []
if len(rows) != 6:
    errors.append("expected one In-Stock field per stock-tracked drug")
for row in rows:
    code = row.get("rxnorm_code")
    if row.get("help") != "Leave blank if unknown":
        errors.append(f"help text for {code}")
    if row.get("blank_allowed") is not True or row.get("required") is not False:
        errors.append(f"blank In-Stock is not allowed for {code}")
    if row.get("input") != "number":
        errors.append(f"In-Stock input for {code} is not a number")
    label = str(row.get("label", ""))
    if not label.startswith("In-Stock "):
        errors.append(f"label for {code} is not an In-Stock field")
    if row.get("drug_name") not in label or row.get("dosage") not in label:
        errors.append(f"label for {code} omits the drug name or dosage")
    if code in banned:
        errors.append("in-stock field uses a received or consumption code")

db_rows = []
with open(sys.argv[3]) as handle:
    for line in handle:
        line = line.rstrip("\n")
        if line:
            db_rows.append(tuple(line.split("\t")))
spec_rows = sorted(
    (row["rxnorm_code"], row["drug_name"], row["dosage"], row["drug_category"])
    for row in rows
)
if spec_rows != sorted(db_rows):
    errors.append(f"form drug list {spec_rows} != active programme {sorted(db_rows)}")

columns = sheet.get("columns") or []
names = [column.get("name") for column in columns]
expected = ["org_unit_id", "reporting_month", "drug_code", "in_stock", "submitted_at"]
if names != expected:
    errors.append(f"long sheet columns are {names}")
else:
    by_name = {column["name"]: column for column in columns}
    if by_name["submitted_at"].get("required") is not False:
        errors.append("submitted_at is required")
    stock = by_name["in_stock"]
    if stock.get("blank_stays_blank") is not True or stock.get("zero_stays_zero") is not True:
        errors.append("in_stock does not keep blank distinct from 0")
    if by_name["org_unit_id"].get("from") != "facility":
        errors.append("org_unit_id does not come from facility")
    if by_name["drug_code"].get("rule") != "protocol_drugs.rxnorm_code":
        errors.append("drug_code is not rxnorm_code")
if set(names) & banned:
    errors.append("long sheet has a received or consumption column")
if "active_stock_tracked_drugs" not in sheet.get("unpivot", ""):
    errors.append("unpivot does not follow the active programme query")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("contract matches active programme")
PY
rm -f "$ACTIVE_TSV"

if grep -E -n 'private_key|service_account|sheet_id|BEGIN PRIVATE KEY|client_email' \
    "$SPEC" "$SHEET_MAP" "$MIGRATION_12"; then
    echo "credential-like text is present" >&2
    exit 1
fi

drop_db
"${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c \
    "CREATE DATABASE ${DB_NAME} OWNER heart360tk;" >/dev/null
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

echo "apply via \\ir"
INCLUDE_DIR="$(mktemp -d)"
chmod 755 "$INCLUDE_DIR"
cat > "$INCLUDE_DIR/01_include.sql" <<EOF
\\ir $MIGRATION_11
\\ir $MIGRATION_12
EOF
chmod 644 "$INCLUDE_DIR/01_include.sql"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$INCLUDE_DIR/01_include.sql" >/dev/null
rm -rf "$INCLUDE_DIR"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
    IF to_regclass('heart360tk_schema.drug_stock_form_cohort') IS NULL
       OR to_regclass('heart360tk_schema.drug_stock_form_facility_export') IS NULL
       OR NOT EXISTS (
            SELECT 1
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'heart360tk_schema'
              AND p.proname = 'drug_stock_form_long_rows'
       ) THEN
        RAISE EXCEPTION '\ir path did not create the form cohort contract';
    END IF;
END $$;
SQL

python3 - "$TABLES" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
first = next(i for i, line in enumerate(lines) if line.strip() == r"\ir migrations/0.5.1_to_0.5.2.sql")
second = next(i for i, line in enumerate(lines) if line.strip() == r"\ir migrations/0.5.2_to_0.5.3.sql")
if second != first + 1:
    raise SystemExit(f"include order is line {first + 1} then line {second + 1}")
print("include line follows 0.5.1_to_0.5.2.sql")
PY

drop_db
"${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS heart360tk;" >/dev/null

echo "drug stock form cohort verified"
