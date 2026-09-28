#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION_11="$ROOT/pg_init_scripts/migrations/0.5.1_to_0.5.2.sql"
MIGRATION_12="$ROOT/pg_init_scripts/migrations/0.5.2_to_0.5.3.sql"
MIGRATION_13="$ROOT/pg_init_scripts/migrations/0.5.3_to_0.5.4.sql"
MIGRATION_21="$ROOT/pg_init_scripts/migrations/0.5.4_to_0.5.5.sql"
SEED="$ROOT/pg_init_scripts/03_drug_stock_demo_seed.sql"
DB_NAME="${DRUG_STOCK_DEMO_SEED_VERIFY_DB:-drug_stock_demo_seed_verify}"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$MIGRATION_11" "$MIGRATION_12" "$MIGRATION_13" "$MIGRATION_21" "$SEED"; do
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

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
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
CREATE UNIQUE INDEX org_units_unique_root
    ON org_units(name, level) WHERE parent_id IS NULL;
CREATE UNIQUE INDEX org_units_unique_child
    ON org_units(name, level, parent_id) WHERE parent_id IS NOT NULL;
CREATE OR REPLACE FUNCTION upsert_org_unit(p_name VARCHAR, p_level INTEGER, p_parent_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF p_parent_id IS NULL THEN
        INSERT INTO org_units (name, level, parent_id)
        VALUES (p_name, p_level, NULL)
        ON CONFLICT (name, level) WHERE parent_id IS NULL
        DO NOTHING;
        SELECT ou.id INTO v_id FROM org_units ou
        WHERE ou.name = p_name AND ou.level = p_level AND ou.parent_id IS NULL;
    ELSE
        INSERT INTO org_units (name, level, parent_id)
        VALUES (p_name, p_level, p_parent_id)
        ON CONFLICT (name, level, parent_id) WHERE parent_id IS NOT NULL
        DO NOTHING;
        SELECT ou.id INTO v_id FROM org_units ou
        WHERE ou.name = p_name AND ou.level = p_level AND ou.parent_id = p_parent_id;
    END IF;
    RETURN v_id;
END;
$$;
CREATE TABLE patients (
    patient_id          bigint PRIMARY KEY,
    patient_name        VARCHAR(255),
    patient_status      VARCHAR(10) NOT NULL CHECK (patient_status IN ('DEAD', 'ALIVE')),
    registration_date   TIMESTAMP NOT NULL,
    org_unit_id         INTEGER REFERENCES org_units(id)
);
CREATE TABLE patient_diagnoses (
    id BIGSERIAL PRIMARY KEY,
    patient_id BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    diagnosis_code VARCHAR(10) NOT NULL,
    UNIQUE(patient_id, diagnosis_code),
    CHECK (diagnosis_code IN ('I10', 'E11'))
);
CREATE TABLE heart360tk_reporting.heart360_patients_registered (
    ref_month date,
    org_unit_id integer,
    cumulative_number_of_patients numeric,
    nb_new_patients numeric
);
SQL

echo "apply protocol drugs"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_11" >/dev/null
echo "apply form cohort"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_12" >/dev/null
echo "apply pull"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_13" >/dev/null
echo "apply patient-days"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$MIGRATION_21" >/dev/null

echo "apply demo seed"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$SEED" >/dev/null
echo "apply demo seed again"
"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$SEED" >/dev/null

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema, heart360tk_reporting;
DO $$
DECLARE
    v_month date := date_trunc('month', current_date)::date;
    v_riverside integer;
    v_hillside integer;
    v_market integer;
    v_blank integer;
    v_silent integer;
    v_north integer;
    v_south integer;
    v_state integer;
    v_days numeric;
    v_patients integer;
    v_submissions integer;
    v_registered integer;
BEGIN
    SELECT id INTO v_state FROM org_units WHERE name = 'Demo State' AND parent_id IS NULL;
    SELECT id INTO v_north FROM org_units WHERE name = 'Demo North District' AND parent_id = v_state;
    SELECT id INTO v_south FROM org_units WHERE name = 'Demo South District' AND parent_id = v_state;
    SELECT id INTO v_riverside FROM org_units WHERE name = 'Demo Riverside Clinic' AND parent_id = v_north;
    SELECT id INTO v_blank FROM org_units WHERE name = 'Demo Blank Ward' AND parent_id = v_north;
    SELECT id INTO v_silent FROM org_units WHERE name = 'Demo Silent Camp' AND parent_id = v_north;
    SELECT id INTO v_hillside FROM org_units WHERE name = 'Demo Hillside PHC' AND parent_id = v_south;
    SELECT id INTO v_market FROM org_units WHERE name = 'Demo Market UPHC' AND parent_id = v_south;

    IF v_riverside IS NULL OR v_blank IS NULL OR v_silent IS NULL
       OR v_hillside IS NULL OR v_market IS NULL THEN
        RAISE EXCEPTION 'demo org tree is missing a facility';
    END IF;

    IF (SELECT count(*) FROM drug_stock_form_cohort
        WHERE org_unit_id IN (v_riverside, v_blank, v_silent, v_hillside, v_market)) <> 5 THEN
        RAISE EXCEPTION 'demo cohort is not the five Demo facilities';
    END IF;

    SELECT count(*) INTO v_patients FROM patients
    WHERE patient_id BETWEEN 910000001 AND 910000305;
    IF v_patients <> 305 THEN
        RAISE EXCEPTION 'demo patient count %, expected 305', v_patients;
    END IF;

    IF (SELECT count(*) FROM patients p
        JOIN patient_diagnoses d ON d.patient_id = p.patient_id AND d.diagnosis_code = 'I10'
        WHERE p.patient_status = 'ALIVE'
          AND p.org_unit_id = v_riverside) <> 100 THEN
        RAISE EXCEPTION 'Riverside does not have 100 alive I10 patients';
    END IF;

    SELECT count(*) INTO v_submissions FROM drug_stock_submission
    WHERE org_unit_id IN (v_riverside, v_blank, v_hillside, v_market);
    IF v_submissions <> 144 THEN
        RAISE EXCEPTION 'demo submission rows %, expected 144', v_submissions;
    END IF;

    IF EXISTS (
        SELECT 1 FROM drug_stock_submission WHERE org_unit_id = v_silent
    ) THEN
        RAISE EXCEPTION 'Silent Camp has a submission';
    END IF;

    SELECT count(*) INTO v_registered
    FROM heart360tk_reporting.heart360_patients_registered
    WHERE org_unit_id IN (v_riverside, v_blank, v_silent, v_hillside, v_market);
    IF v_registered <> 30 THEN
        RAISE EXCEPTION 'demo registered rows %, expected 30', v_registered;
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_riverside
      AND reporting_month = v_month
      AND rxnorm_code = '329528';
    IF v_days IS NULL OR abs(v_days - (200::numeric / 140)) >= 0.0000001 THEN
        RAISE EXCEPTION 'Riverside CCB patient-days %, expected 200/140', v_days;
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_riverside
      AND reporting_month = v_month
      AND rxnorm_code = '316764';
    IF v_days IS DISTINCT FROM 75 THEN
        RAISE EXCEPTION 'Riverside ARB patient-days %, expected 75', v_days;
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_riverside
      AND reporting_month = v_month
      AND rxnorm_code = '331132';
    IF v_days IS DISTINCT FROM 90 THEN
        RAISE EXCEPTION 'Riverside Diuretic patient-days %, expected 90', v_days;
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_hillside
      AND reporting_month = v_month
      AND drug_category = 'CCB'
    LIMIT 1;
    IF v_days IS DISTINCT FROM 90 THEN
        RAISE EXCEPTION 'Hillside CCB patient-days %, expected 90', v_days;
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_hillside
      AND reporting_month = v_month
      AND drug_category = 'ARB'
    LIMIT 1;
    IF v_days IS DISTINCT FROM 45 THEN
        RAISE EXCEPTION 'Hillside ARB patient-days %, expected 45', v_days;
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_hillside
      AND reporting_month = v_month
      AND drug_category = 'Diuretic'
    LIMIT 1;
    IF v_days IS DISTINCT FROM 10 THEN
        RAISE EXCEPTION 'Hillside Diuretic patient-days %, expected 10', v_days;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = v_market
          AND reporting_month = v_month
          AND (in_stock IS DISTINCT FROM 0 OR category_patient_days IS DISTINCT FROM 0 OR NOT submission_present)
    ) THEN
        RAISE EXCEPTION 'Market UPHC is not an explicit zero submission';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = v_blank
          AND reporting_month = v_month
          AND drug_category = 'ARB'
          AND (in_stock IS NOT NULL OR category_patient_days IS NOT NULL OR NOT submission_present)
    ) THEN
        RAISE EXCEPTION 'Blank Ward ARB is not a submitted blank';
    END IF;

    SELECT category_patient_days INTO v_days
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = v_blank
      AND reporting_month = v_month
      AND drug_category = 'CCB'
    LIMIT 1;
    IF v_days IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'Blank Ward CCB patient-days %, expected 5', v_days;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = v_silent
          AND reporting_month = v_month
          AND (submission_present OR in_stock IS NOT NULL OR category_patient_days IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'Silent Camp does not read as a missing report';
    END IF;

    IF (
        SELECT count(DISTINCT reporting_month)
        FROM heart360tk_reporting.drug_stock_patient_days
        WHERE org_unit_id = v_riverside
    ) <> 6 THEN
        RAISE EXCEPTION 'Riverside does not cover the six picker months';
    END IF;
END $$;
SQL

MONTH="$("${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tA -c \
    "SELECT date_trunc('month', current_date)::date;")"
echo "picker month ${MONTH}"

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c \
"SELECT facility_name, drug_category,
        CASE
            WHEN NOT submission_present THEN '?'
            WHEN in_stock IS NULL THEN chr(8212)
            ELSE to_char(in_stock, 'FM999999990.########')
        END AS in_stock,
        category_patient_days
 FROM heart360tk_reporting.drug_stock_patient_days
 WHERE reporting_month = date_trunc('month', current_date)::date
   AND rxnorm_code IN ('329528', '316764', '331132')
 ORDER BY facility_name, drug_category;"

echo "demo seed verified"
