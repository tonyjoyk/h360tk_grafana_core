#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION_11="$ROOT/pg_init_scripts/migrations/0.5.1_to_0.5.2.sql"
MIGRATION_12="$ROOT/pg_init_scripts/migrations/0.5.2_to_0.5.3.sql"
MIGRATION_13="$ROOT/pg_init_scripts/migrations/0.5.3_to_0.5.4.sql"
MIGRATION_21="$ROOT/pg_init_scripts/migrations/0.5.4_to_0.5.5.sql"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
DB_NAME="${DRUG_STOCK_PATIENT_DAYS_VERIFY_DB:-drug_stock_patient_days_verify}"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$MIGRATION_11" "$MIGRATION_12" "$MIGRATION_13" "$MIGRATION_21" "$TABLES"; do
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

cleanup() {
    drop_db || true
}

trap cleanup EXIT

drop_db
"${PSQL[@]}" -d postgres -v ON_ERROR_STOP=1 <<SQL
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

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
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
CREATE TABLE heart360tk_reporting.heart360_patients_registered (
    ref_month date,
    org_unit_id integer,
    cumulative_number_of_patients numeric,
    nb_new_patients numeric
);
CREATE TABLE heart360tk_reporting.heart360_patients_under_care (
    ref_month date,
    org_unit_id integer,
    cumulative_number_of_patients numeric,
    nb_patients_under_care numeric
);
SQL

echo "apply 1.1"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_11" >/dev/null
echo "apply 1.2"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_12" >/dev/null
echo "apply 1.3"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_13" >/dev/null
echo "apply 2.1"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_21" >/dev/null
echo "apply 2.1 again"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_21" >/dev/null

python3 - "$TABLES" <<'PY'
import sys
text = open(sys.argv[1]).read()
start = text.index("-- VIEW 1: HEART360_PATIENTS_REGISTERED")
end = text.index("-- VIEW 2: HEART360_PATIENTS_UNDER_CARE")
view = text[start:end]
needles = [
    "LOWER(patient_status) <> 'dead'",
    "diagnosis_code = 'I10'",
    "CUMULATIVE_NUMBER_OF_PATIENTS",
    "REF_MONTH",
    "org_unit_id",
    "NB_NEW_PATIENTS",
]
missing = [needle for needle in needles if needle not in view]
if missing:
    raise SystemExit("registered view is missing: " + ", ".join(missing))
if "UNDER_CARE" in view or "encounters" in view.lower():
    raise SystemExit("registered view grain includes under-care or encounters")
print("registered SQL grain: heart360tk_reporting.HEART360_PATIENTS_REGISTERED (ref_month, org_unit_id, cumulative_number_of_patients) sourced from heart360tk_schema.HEART360_PATIENTS_REGISTERED; patients not dead; diagnosis I10; cumulative through ref_month")
PY

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (11, 'Alpha Facility', 3, NULL),
    (12, 'Beta Facility', 3, NULL),
    (14, 'Zero Patients', 3, NULL),
    (15, 'Missing Patients', 3, NULL),
    (99, 'Outside Cohort', 3, NULL);

INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (11), (12), (14), (15);

INSERT INTO heart360tk_reporting.heart360_patients_registered (
    ref_month, org_unit_id, cumulative_number_of_patients, nb_new_patients
) VALUES
    (DATE '2026-09-01', 11, 100, 4),
    (DATE '2026-09-01', 12, 80, 1),
    (DATE '2026-09-01', 14, 0, 0),
    (DATE '2026-07-01', 11, 90, 2);

INSERT INTO heart360tk_reporting.heart360_patients_under_care (
    ref_month, org_unit_id, cumulative_number_of_patients, nb_patients_under_care
) VALUES
    (DATE '2026-09-01', 11, 1, 7);

INSERT INTO drug_stock_submission (
    org_unit_id, reporting_month, rxnorm_code, country_code, programme_code,
    in_stock, submitted_at, pulled_at
) VALUES
    (11, DATE '2026-09-01', '329528', 'India', 'IHCI', 100, NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (11, DATE '2026-09-01', '329526', 'India', 'IHCI', 50,  NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (11, DATE '2026-09-01', '316764', 'India', 'IHCI', NULL, NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (11, DATE '2026-09-01', '316765', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '329528', 'India', 'IHCI', 100, NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (15, DATE '2026-09-01', '329528', 'India', 'IHCI', 100, NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (99, DATE '2026-09-01', '329528', 'India', 'IHCI', 5,   NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (99, DATE '2026-07-01', '329528', 'India', 'IHCI', 5,   NULL, TIMESTAMPTZ '2026-07-20T00:00:00Z');

DO $$
DECLARE
    v_columns text;
    v_def text;
    v_days numeric;
    v_amlo5 numeric;
    v_amlo10 numeric;
    v_rows int;
    v_present int;
    v_coeff text;
BEGIN
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_reporting'
      AND table_name = 'drug_stock_patient_days';
    IF v_columns IS DISTINCT FROM
        'org_unit_id,facility_name,reporting_month,drug_category,rxnorm_code,drug_name,dosage,submission_present,in_stock,dose_factor,patients_n,load_factor,category_coeff,normalized_stock,category_patient_days'
    THEN
        RAISE EXCEPTION 'patient-days columns are [%]', v_columns;
    END IF;

    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'heart360tk_schema'
      AND table_name = 'coeff_config';
    IF v_columns IS DISTINCT FROM
        'country_code,programme_code,drug_category,category_coeff,load_factor'
    THEN
        RAISE EXCEPTION 'coeff_config columns are [%]', v_columns;
    END IF;

    SELECT string_agg(drug_category || '=' || category_coeff::text || '/' || load_factor::text, ',' ORDER BY drug_category)
    INTO v_coeff
    FROM coeff_config
    WHERE country_code = 'India' AND programme_code = 'IHCI';
    IF v_coeff IS DISTINCT FROM 'ARB=0.37/1.0,CCB=1.4/1.0,Diuretic=0.06/1.0' THEN
        RAISE EXCEPTION 'India/IHCI coefficients are [%]', v_coeff;
    END IF;

    IF EXISTS (
        SELECT 1 FROM protocol_drugs
        WHERE (rxnorm_code, dose_factor) IN (
            ('329528', 1), ('329526', 2), ('316764', 1),
            ('316765', 2), ('331132', 1), ('197499', 2)
        )
        HAVING COUNT(*) <> 6
    ) OR (
        SELECT COUNT(*) FROM protocol_drugs
        WHERE country_code = 'India' AND programme_code = 'IHCI'
          AND (rxnorm_code, dose_factor) IN (
              ('329528', 1), ('329526', 2), ('316764', 1),
              ('316765', 2), ('331132', 1), ('197499', 2)
          )
    ) <> 6 THEN
        RAISE EXCEPTION 'dose factors are not the rxnorm map';
    END IF;

    SELECT pg_get_viewdef('heart360tk_reporting.drug_stock_patient_days'::regclass, true)
    INTO v_def;
    IF v_def ILIKE '%under_care%' THEN
        RAISE EXCEPTION 'patient-days view reads under-care';
    END IF;
    IF v_def NOT ILIKE '%heart360tk_reporting%'
       OR v_def NOT ILIKE '%heart360_patients_registered%'
       OR v_def NOT ILIKE '%cumulative_number_of_patients%'
       OR v_def NOT ILIKE '%deploy_setting%'
       OR v_def NOT ILIKE '%coeff_config%'
       OR v_def NOT ILIKE '%active_stock_tracked_drugs%' THEN
        RAISE EXCEPTION 'patient-days view does not join registered N, deploy_setting, and coeff_config';
    END IF;
    IF v_def ILIKE '%heart360tk_schema%heart360_patients_registered%' THEN
        RAISE EXCEPTION 'patient-days view reads the schema registered view directly';
    END IF;

    SELECT COUNT(*) INTO v_rows FROM heart360tk_reporting.drug_stock_patient_days;
    IF v_rows <> 48 THEN
        RAISE EXCEPTION 'expected 48 patient-days rows, found %', v_rows;
    END IF;

    IF EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 99
    ) THEN
        RAISE EXCEPTION 'a facility outside the cohort appeared';
    END IF;

    SELECT COUNT(*) INTO v_present
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE submission_present;
    IF v_present <> 18 THEN
        RAISE EXCEPTION 'submission_present true count is %', v_present;
    END IF;

    IF EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 12 AND submission_present
    ) OR EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE reporting_month = DATE '2026-07-01' AND submission_present
    ) THEN
        RAISE EXCEPTION 'a cohort facility with no submission was marked present';
    END IF;

    IF EXISTS (
        SELECT 1 FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11
          AND reporting_month = DATE '2026-09-01'
          AND NOT submission_present
    ) THEN
        RAISE EXCEPTION 'Alpha Facility September lost submission_present';
    END IF;

    SELECT normalized_stock, category_patient_days
    INTO v_amlo5, v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = 11
      AND reporting_month = DATE '2026-09-01'
      AND rxnorm_code = '329528';
    SELECT normalized_stock INTO v_amlo10
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = 11
      AND reporting_month = DATE '2026-09-01'
      AND rxnorm_code = '329526';

    IF v_amlo5 IS DISTINCT FROM 100 OR v_amlo10 IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'normalized stock is % and %, expected 100 and 100', v_amlo5, v_amlo10;
    END IF;
    IF abs(v_days - (200::numeric / 140)) >= 0.001 THEN
        RAISE EXCEPTION 'category_patient_days % is not within 0.001 of %', v_days, (200::numeric / 140);
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11
          AND reporting_month = DATE '2026-09-01'
          AND drug_category = 'CCB'
          AND category_patient_days IS DISTINCT FROM v_days
    ) THEN
        RAISE EXCEPTION 'CCB rows do not share category_patient_days';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11
          AND reporting_month = DATE '2026-09-01'
          AND rxnorm_code = '316764'
          AND (in_stock IS NOT NULL OR normalized_stock IS NOT NULL OR NOT submission_present)
    ) THEN
        RAISE EXCEPTION 'blank Telmisartan 40 mg did not stay null';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11
          AND reporting_month = DATE '2026-09-01'
          AND rxnorm_code = '316765'
          AND (in_stock IS DISTINCT FROM 0 OR normalized_stock IS DISTINCT FROM 0)
    ) THEN
        RAISE EXCEPTION 'explicit zero Telmisartan 80 mg did not stay 0';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11
          AND reporting_month = DATE '2026-09-01'
          AND drug_category = 'ARB'
          AND category_patient_days IS DISTINCT FROM 0
    ) THEN
        RAISE EXCEPTION 'explicit zero did not contribute 0 to the ARB sum';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 11
          AND reporting_month = DATE '2026-09-01'
          AND drug_category = 'Diuretic'
          AND (in_stock IS NOT NULL OR normalized_stock IS NOT NULL OR category_patient_days IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'an all-null category did not stay null';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 12
          AND reporting_month = DATE '2026-09-01'
          AND (
              submission_present
              OR in_stock IS NOT NULL
              OR patients_n IS DISTINCT FROM 80
              OR category_patient_days IS NOT NULL
          )
    ) THEN
        RAISE EXCEPTION 'Beta Facility did not stay unreported with registered N 80';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id IN (14, 15)
          AND reporting_month = DATE '2026-09-01'
          AND drug_category = 'CCB'
          AND category_patient_days IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'patients_n null or 0 produced category_patient_days';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 14
          AND reporting_month = DATE '2026-09-01'
          AND patients_n IS DISTINCT FROM 0
    ) OR EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = 15
          AND reporting_month = DATE '2026-09-01'
          AND patients_n IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'zero and missing registered N were not preserved';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE reporting_month = DATE '2026-07-01'
          AND org_unit_id = 11
          AND (patients_n IS DISTINCT FROM 90 OR category_patient_days IS NOT NULL OR submission_present)
    ) THEN
        RAISE EXCEPTION 'July used the wrong registered month or treated a missing report as stock';
    END IF;
END $$;
SQL

echo "golden inputs: amlo5=100 dose_factor=1, amlo10=50 dose_factor=2, normalized_sum=200, patients_n=100, load_factor=1.0, category_coeff=1.4"
echo "expected category_patient_days 1.428571"
STORED="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -c \
    "SELECT category_patient_days::text FROM heart360tk_reporting.drug_stock_patient_days WHERE org_unit_id = 11 AND reporting_month = DATE '2026-09-01' AND rxnorm_code = '329528';")"
echo "stored category_patient_days ${STORED}"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;
BEGIN;
UPDATE protocol_drugs
SET dose_factor = 3
WHERE country_code = 'India' AND programme_code = 'IHCI' AND rxnorm_code = '329526';
DO $$
DECLARE
    v_norm numeric;
    v_days numeric;
BEGIN
    SELECT normalized_stock, category_patient_days
    INTO v_norm, v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = 11
      AND reporting_month = DATE '2026-09-01'
      AND rxnorm_code = '329526';
    IF v_norm IS DISTINCT FROM 150 OR abs(v_days - (250::numeric / 140)) >= 0.001 THEN
        RAISE EXCEPTION 'dose_factor change did not flow into the view: normalized % days %', v_norm, v_days;
    END IF;
END $$;
ROLLBACK;

BEGIN;
UPDATE coeff_config
SET category_coeff = 2.8
WHERE country_code = 'India' AND programme_code = 'IHCI' AND drug_category = 'CCB';
DO $$
DECLARE
    v_days numeric;
BEGIN
    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = 11
      AND reporting_month = DATE '2026-09-01'
      AND rxnorm_code = '329528';
    IF abs(v_days - (200::numeric / 280)) >= 0.001 THEN
        RAISE EXCEPTION 'coeff_config change did not flow into the view: %', v_days;
    END IF;
END $$;
ROLLBACK;

BEGIN;
INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
VALUES ('Testland', 'DEMO', 'ATTACC');
INSERT INTO protocol_drugs (
    country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked, dose_factor
) VALUES (
    'Testland', 'DEMO', 'Amlodipine', '5 mg', '329528', 'CCB', TRUE, 1
);
INSERT INTO coeff_config (
    country_code, programme_code, drug_category, category_coeff, load_factor
) VALUES (
    'Testland', 'DEMO', 'CCB', 2.8, 1.0
);
UPDATE deploy_setting
SET country_code = 'Testland', programme_code = 'DEMO'
WHERE setting_name = 'active_programme';
DO $$
DECLARE
    v_rows int;
BEGIN
    SELECT COUNT(*) INTO v_rows FROM heart360tk_reporting.drug_stock_patient_days;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'inactive programme submissions still produced % rows', v_rows;
    END IF;
END $$;
INSERT INTO drug_stock_submission (
    org_unit_id, reporting_month, rxnorm_code, country_code, programme_code,
    in_stock, submitted_at, pulled_at
) VALUES (
    11, DATE '2026-08-01', '329528', 'Testland', 'DEMO', 100, NULL, TIMESTAMPTZ '2026-08-20T00:00:00Z'
);
INSERT INTO heart360tk_reporting.heart360_patients_registered (
    ref_month, org_unit_id, cumulative_number_of_patients, nb_new_patients
) VALUES (
    DATE '2026-08-01', 11, 100, 1
);
DO $$
DECLARE
    v_rows int;
    v_drugs int;
    v_days numeric;
    v_coeff numeric;
BEGIN
    SELECT COUNT(*), COUNT(DISTINCT rxnorm_code)
    INTO v_rows, v_drugs
    FROM heart360tk_reporting.drug_stock_patient_days;
    SELECT category_patient_days, category_coeff
    INTO v_days, v_coeff
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = 11 AND rxnorm_code = '329528';
    IF v_rows <> 4 OR v_drugs <> 1 OR v_coeff IS DISTINCT FROM 2.8
       OR abs(v_days - (100::numeric / 280)) >= 0.001 THEN
        RAISE EXCEPTION 'active programme did not select drugs and coefficients: rows % drugs % coeff % days %',
            v_rows, v_drugs, v_coeff, v_days;
    END IF;
END $$;
ROLLBACK;
SQL

echo "apply 2.1 with rows"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_21" >/dev/null
RESTORED="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -c \
    "SELECT category_patient_days::text FROM heart360tk_reporting.drug_stock_patient_days WHERE org_unit_id = 11 AND reporting_month = DATE '2026-09-01' AND rxnorm_code = '329528';")"
if [[ "$RESTORED" != "$STORED" ]]; then
    echo "reapplying 2.1 changed category_patient_days from ${STORED} to ${RESTORED}" >&2
    exit 1
fi
echo "reapplied category_patient_days ${RESTORED}"

echo "cached reader"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
    "GRANT USAGE ON SCHEMA heart360tk_reporting TO heart360tk_cached; SET ROLE heart360tk_cached; SELECT COUNT(*) FROM heart360tk_reporting.drug_stock_patient_days;" >/dev/null
set +e
CACHED_WRITE="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
    "GRANT USAGE ON SCHEMA heart360tk_schema TO heart360tk_cached; SET ROLE heart360tk_cached; INSERT INTO heart360tk_schema.drug_stock_submission (org_unit_id, reporting_month, rxnorm_code, country_code, programme_code, in_stock, submitted_at, pulled_at) VALUES (11, DATE '2026-09-01', '329528', 'India', 'IHCI', 1, NULL, TIMESTAMPTZ '2026-09-21T00:00:00Z');" 2>&1)"
CACHED_STATUS=$?
set -e
if [[ $CACHED_STATUS -eq 0 ]]; then
    echo "heart360tk_cached wrote drug_stock_submission" >&2
    exit 1
fi
if [[ "$CACHED_WRITE" != *"permission denied"* ]]; then
    echo "cached write failed for a different reason" >&2
    printf '%s\n' "$CACHED_WRITE" >&2
    exit 1
fi

python3 - "$TABLES" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
third = next(i for i, line in enumerate(lines) if line.strip() == r"\ir migrations/0.5.3_to_0.5.4.sql")
fourth = next(i for i, line in enumerate(lines) if line.strip() == r"\ir migrations/0.5.4_to_0.5.5.sql")
if fourth != third + 1:
    raise SystemExit(f"include order is line {third + 1} then line {fourth + 1}")
print("include line follows 0.5.3_to_0.5.4.sql")
PY

if grep -E -n 'BEGIN PRIVATE KEY|client_email|service_account' "$MIGRATION_21" "$TABLES"; then
    echo "credential-like text is present" >&2
    exit 1
fi

echo "drug stock patient days verified"
