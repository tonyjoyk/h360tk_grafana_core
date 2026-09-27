#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATION_11="$ROOT/pg_init_scripts/migrations/0.5.1_to_0.5.2.sql"
MIGRATION_12="$ROOT/pg_init_scripts/migrations/0.5.2_to_0.5.3.sql"
MIGRATION_13="$ROOT/pg_init_scripts/migrations/0.5.3_to_0.5.4.sql"
MIGRATION_21="$ROOT/pg_init_scripts/migrations/0.5.4_to_0.5.5.sql"
MIGRATION_23="$ROOT/pg_init_scripts/migrations/0.5.5_to_0.5.6.sql"
DASHBOARD="$ROOT/grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.drug.stock.json"
DB_NAME="${DRUG_STOCK_ON_HAND_VERIFY_DB:-drug_stock_on_hand_verify}"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$MIGRATION_11" "$MIGRATION_12" "$MIGRATION_13" "$MIGRATION_21" "$MIGRATION_23" "$DASHBOARD"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

git -C "$ROOT" diff --exit-code -- \
    "grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension.program.json" \
    "grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.diabetes.program.json" \
    "grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.overdue.patients.json" \
    "grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.home.json"
echo "baseline dashboards unchanged"

python3 - "$DASHBOARD" <<'PY'
import json
import sys
doc = json.load(open(sys.argv[1]))
assert doc["uid"] == "heart360_drug_stock"
panels = [p for p in doc["panels"] if p.get("id") == 10]
assert len(panels) == 1, panels
panel = panels[0]
assert panel["type"] == "table", panel["type"]
assert panel["title"] == "Stock on hand"
assert "drug_stock_on_hand_matrix" in panel["targets"][0]["rawSql"]
assert "NULLIF('${org_unit}', '')::integer" in panel["targets"][0]["rawSql"]
assert "dose_factor" not in panel["targets"][0]["rawSql"]
assert panel["options"]["frozenColumns"]["left"] == 1
assert panel["options"]["sortBy"][0]["displayName"] == "Facility"
blob = json.dumps(panel, ensure_ascii=False)
for color in ("#E02F44", "#FF9830", "#F2CC0C", "#56A64B", "#EFEFEF"):
    assert color in blob, color
assert "\u2014" in blob
names = [item["name"] for item in doc["templating"]["list"]]
assert names == ["reporting_month", "org_unit"], names
org = doc["templating"]["list"][1]
assert org["hide"] == 2
assert org["type"] == "textbox"
titles = [p.get("title") for p in doc["panels"]]
assert "Drug consumption" not in titles
assert "Download Report" not in blob
print("dashboard panel 10 is the stock matrix table")
PY

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
    if [[ "$mode" == "docker" || "$mode" == "auto" ]]; then
        if docker exec postgres psql -U "${DRUG_STOCK_PSQL_USER:-h360tk_root}" -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
            PSQL=(docker exec -i postgres psql -U "${DRUG_STOCK_PSQL_USER:-h360tk_root}")
            echo "psql mode: docker exec postgres"
            return
        fi
    fi
    echo "verifier-blocked: neither sudo -u postgres, local psql, nor docker exec postgres can connect" >&2
    exit 1
}

choose_psql

apply_file() {
    local db="$1"
    local file="$2"
    if [[ "${PSQL[0]}" == "docker" ]]; then
        docker exec -i postgres psql -U "${DRUG_STOCK_PSQL_USER:-h360tk_root}" -d "$db" -v ON_ERROR_STOP=1 < "$file"
    else
        "${PSQL[@]}" -d "$db" -v ON_ERROR_STOP=1 -f "$file"
    fi
}

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

echo "apply 1.1"
apply_file "$DB_NAME" "$MIGRATION_11" >/dev/null
echo "apply 1.2"
apply_file "$DB_NAME" "$MIGRATION_12" >/dev/null
echo "apply 1.3"
apply_file "$DB_NAME" "$MIGRATION_13" >/dev/null
echo "apply 2.1"
apply_file "$DB_NAME" "$MIGRATION_21" >/dev/null
echo "apply 2.3"
apply_file "$DB_NAME" "$MIGRATION_23" >/dev/null
echo "apply 2.3 again"
apply_file "$DB_NAME" "$MIGRATION_23" >/dev/null

"${PSQL[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES
    (1, 'Seed State', 1, NULL),
    (2, 'Seed District', 2, 1),
    (3, 'Empty District', 2, 1),
    (11, 'Blank Facility', 3, 2),
    (12, 'Golden Facility', 3, 2),
    (13, 'Missing Facility', 3, 2),
    (14, 'Zero Facility', 3, 2),
    (99, 'Outside Cohort', 3, 2);

INSERT INTO drug_stock_form_cohort (org_unit_id) VALUES (11), (12), (13), (14);

INSERT INTO heart360tk_reporting.heart360_patients_registered (
    ref_month, org_unit_id, cumulative_number_of_patients, nb_new_patients
) VALUES
    (DATE '2026-09-01', 11, 50, 1),
    (DATE '2026-09-01', 12, 100, 4),
    (DATE '2026-09-01', 13, 80, 1),
    (DATE '2026-09-01', 14, 10, 1);

INSERT INTO drug_stock_submission (
    org_unit_id, reporting_month, rxnorm_code, country_code, programme_code,
    in_stock, submitted_at, pulled_at
) VALUES
    (11, DATE '2026-09-01', '329528', 'India', 'IHCI', NULL, NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (12, DATE '2026-09-01', '329528', 'India', 'IHCI', 100,  NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (12, DATE '2026-09-01', '329526', 'India', 'IHCI', 50,   NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (12, DATE '2026-09-01', '316764', 'India', 'IHCI', 1665, NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (12, DATE '2026-09-01', '316765', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (12, DATE '2026-09-01', '331132', 'India', 'IHCI', 450,  NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (12, DATE '2026-09-01', '197499', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '329528', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '329526', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '316764', 'India', 'IHCI', 333,  NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '316765', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '331132', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (14, DATE '2026-09-01', '197499', 'India', 'IHCI', 0,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z'),
    (99, DATE '2026-09-01', '329528', 'India', 'IHCI', 5,    NULL, TIMESTAMPTZ '2026-09-20T00:00:00Z');

DO $$
DECLARE
    v_def text;
    v_golden json;
    v_missing json;
    v_blank json;
    v_zero json;
    v_all json;
    v_text text;
    v_pos int;
    v_prev int;
    v_key text;
    v_days numeric;
    v_view numeric;
    v_count int;
    v_names text;
    v_keys text[] := ARRAY[
        'Facility',
        'Amlodipine 5 mg',
        'Amlodipine 10 mg',
        'CCB Patient days',
        'Telmisartan 40 mg',
        'Telmisartan 80 mg',
        'ARB Patient days',
        'Chlorthalidone 12.5 mg',
        'Chlorthalidone 25 mg',
        'Diuretic Patient days'
    ];
BEGIN
    SELECT pg_get_functiondef('heart360tk_reporting.drug_stock_on_hand_matrix(date, integer)'::regprocedure)
    INTO v_def;
    IF v_def ILIKE '%dose_factor%' OR v_def ILIKE '%in_stock *%' THEN
        RAISE EXCEPTION 'matrix function recomputes patient days';
    END IF;
    IF v_def NOT ILIKE '%drug_stock_patient_days%'
       OR v_def NOT ILIKE '%get_descendant_ids%' THEN
        RAISE EXCEPTION 'matrix function does not read the view and descendants';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL);
    IF v_count <> 5 THEN
        RAISE EXCEPTION 'nationwide row count is %', v_count;
    END IF;

    SELECT matrix INTO v_golden
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'Golden Facility';
    SELECT matrix INTO v_missing
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'Missing Facility';
    SELECT matrix INTO v_blank
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'Blank Facility';
    SELECT matrix INTO v_zero
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'Zero Facility';
    SELECT matrix INTO v_all
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
    WHERE matrix->>'Facility' = 'All';

    IF v_golden IS NULL OR v_missing IS NULL OR v_blank IS NULL OR v_zero IS NULL OR v_all IS NULL THEN
        RAISE EXCEPTION 'a seeded display row is missing';
    END IF;

    v_text := v_golden::text;
    v_prev := 0;
    FOREACH v_key IN ARRAY v_keys LOOP
        v_pos := strpos(v_text, '"' || v_key || '"');
        IF v_pos = 0 OR v_pos <= v_prev THEN
            RAISE EXCEPTION 'column order broke at % in %', v_key, v_text;
        END IF;
        v_prev := v_pos;
    END LOOP;
    IF strpos(v_text, 'Other') <> 0 THEN
        RAISE EXCEPTION 'empty Other category was not hidden: %', v_text;
    END IF;

    IF v_golden->>'Amlodipine 5 mg' IS DISTINCT FROM '100'
       OR v_golden->>'Amlodipine 10 mg' IS DISTINCT FROM '50'
       OR v_golden->>'Telmisartan 40 mg' IS DISTINCT FROM '1665'
       OR v_golden->>'Telmisartan 80 mg' IS DISTINCT FROM '0'
       OR v_golden->>'Chlorthalidone 12.5 mg' IS DISTINCT FROM '450'
       OR v_golden->>'Chlorthalidone 25 mg' IS DISTINCT FROM '0' THEN
        RAISE EXCEPTION 'golden stock cells are %', v_golden;
    END IF;

    v_days := (v_golden->>'CCB Patient days')::numeric;
    SELECT MAX(category_patient_days) INTO v_view
    FROM heart360tk_reporting.drug_stock_patient_days
    WHERE org_unit_id = 12
      AND reporting_month = DATE '2026-09-01'
      AND drug_category = 'CCB';
    IF v_days IS DISTINCT FROM v_view THEN
        RAISE EXCEPTION 'golden CCB patient days % is not the view value %', v_days, v_view;
    END IF;
    IF abs(v_days - (200::numeric / 140)) >= 0.001 THEN
        RAISE EXCEPTION 'golden CCB patient days % is not about 1.43', v_days;
    END IF;
    IF abs((v_golden->>'ARB Patient days')::numeric - 45) >= 0.001 THEN
        RAISE EXCEPTION 'golden ARB patient days is %', v_golden->>'ARB Patient days';
    END IF;
    IF abs((v_golden->>'Diuretic Patient days')::numeric - 75) >= 0.001 THEN
        RAISE EXCEPTION 'golden diuretic patient days is %', v_golden->>'Diuretic Patient days';
    END IF;

    IF v_missing->>'Amlodipine 5 mg' IS DISTINCT FROM '?'
       OR v_missing->>'Amlodipine 10 mg' IS DISTINCT FROM '?'
       OR v_missing->>'Telmisartan 40 mg' IS DISTINCT FROM '?'
       OR v_missing->>'Telmisartan 80 mg' IS DISTINCT FROM '?'
       OR v_missing->>'Chlorthalidone 12.5 mg' IS DISTINCT FROM '?'
       OR v_missing->>'Chlorthalidone 25 mg' IS DISTINCT FROM '?'
       OR NOT (v_missing::jsonb ? 'CCB Patient days')
       OR NOT (v_missing::jsonb ? 'ARB Patient days')
       OR NOT (v_missing::jsonb ? 'Diuretic Patient days')
       OR v_missing->>'CCB Patient days' IS NOT NULL
       OR v_missing->>'ARB Patient days' IS NOT NULL
       OR v_missing->>'Diuretic Patient days' IS NOT NULL
       OR v_missing::text LIKE '%"0"%' THEN
        RAISE EXCEPTION 'missing facility showed a number: %', v_missing;
    END IF;
    IF (
        SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_golden::jsonb) AS k
    ) IS DISTINCT FROM (
        SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_missing::jsonb) AS k
    ) OR (
        SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_golden::jsonb) AS k
    ) IS DISTINCT FROM (
        SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_all::jsonb) AS k
    ) THEN
        RAISE EXCEPTION 'display rows do not share columns';
    END IF;

    IF v_blank->>'Amlodipine 5 mg' IS DISTINCT FROM chr(8212)
       OR v_blank->>'Telmisartan 80 mg' IS DISTINCT FROM chr(8212)
       OR v_blank->>'Chlorthalidone 25 mg' IS DISTINCT FROM chr(8212)
       OR (v_blank->>'CCB Patient days')::numeric IS DISTINCT FROM -1
       OR v_blank::text LIKE '%"?"%' THEN
        RAISE EXCEPTION 'blank facility cells are %', v_blank;
    END IF;

    IF v_zero->>'Amlodipine 5 mg' IS DISTINCT FROM '0'
       OR v_zero->>'Amlodipine 10 mg' IS DISTINCT FROM '0'
       OR v_zero->>'Telmisartan 40 mg' IS DISTINCT FROM '333'
       OR v_zero->>'Telmisartan 80 mg' IS DISTINCT FROM '0'
       OR (v_zero->>'CCB Patient days')::numeric IS DISTINCT FROM 0
       OR abs((v_zero->>'ARB Patient days')::numeric - 90) >= 0.001 THEN
        RAISE EXCEPTION 'zero facility cells are %', v_zero;
    END IF;

    IF v_all->>'Amlodipine 5 mg' IS DISTINCT FROM '100'
       OR v_all->>'Amlodipine 10 mg' IS DISTINCT FROM '50'
       OR v_all->>'Telmisartan 40 mg' IS DISTINCT FROM '1998'
       OR v_all->>'Telmisartan 80 mg' IS DISTINCT FROM '0'
       OR v_all->>'Chlorthalidone 12.5 mg' IS DISTINCT FROM '450'
       OR v_all->>'Chlorthalidone 25 mg' IS DISTINCT FROM '0'
       OR abs((v_all->>'CCB Patient days')::numeric - (200::numeric / 336)) >= 0.001
       OR abs((v_all->>'ARB Patient days')::numeric - 22.5) >= 0.001
       OR abs((v_all->>'Diuretic Patient days')::numeric - 31.25) >= 0.001 THEN
        RAISE EXCEPTION 'All row is %', v_all;
    END IF;

    SELECT string_agg(matrix->>'Facility', ',' ORDER BY matrix->>'Facility')
    INTO v_names
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 12);
    IF v_names IS DISTINCT FROM 'Golden Facility' THEN
        RAISE EXCEPTION 'facility scope returned %', v_names;
    END IF;

    SELECT string_agg(matrix->>'Facility', ',' ORDER BY matrix->>'Facility')
    INTO v_names
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 14);
    IF v_names IS DISTINCT FROM 'Zero Facility' THEN
        RAISE EXCEPTION 'descendant self scope returned %', v_names;
    END IF;

    SELECT string_agg(matrix->>'Facility', ',' ORDER BY matrix->>'Facility')
    INTO v_names
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 2);
    IF v_names IS DISTINCT FROM 'Blank Facility,Golden Facility,Missing Facility,Zero Facility' THEN
        RAISE EXCEPTION 'district scope returned %', v_names;
    END IF;

    SELECT string_agg(matrix->>'Facility', ',' ORDER BY matrix->>'Facility')
    INTO v_names
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 1);
    IF v_names IS DISTINCT FROM 'Blank Facility,Golden Facility,Missing Facility,Zero Facility' THEN
        RAISE EXCEPTION 'state scope returned %', v_names;
    END IF;

    SELECT matrix->>'Facility' INTO v_text
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 3);
    IF v_text IS DISTINCT FROM 'No facilities for this location.' THEN
        RAISE EXCEPTION 'empty location copy is %', v_text;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL)
        WHERE matrix::text LIKE '%Outside Cohort%'
    ) THEN
        RAISE EXCEPTION 'a facility outside the cohort appeared';
    END IF;
END $$;

GRANT USAGE ON SCHEMA heart360tk_schema TO heart360tk_cached;
GRANT USAGE ON SCHEMA heart360tk_reporting TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.org_units TO heart360tk_cached;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_descendant_ids(integer) TO heart360tk_cached;

SET ROLE heart360tk_cached;
DO $$
DECLARE
    v_count int;
    v_copy text;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', NULL);
    IF v_count <> 5 THEN
        RAISE EXCEPTION 'cached nationwide count is %', v_count;
    END IF;
    SELECT matrix->>'Facility' INTO v_copy
    FROM heart360tk_reporting.drug_stock_on_hand_matrix(DATE '2026-09-01', 3);
    IF v_copy IS DISTINCT FROM 'No facilities for this location.' THEN
        RAISE EXCEPTION 'cached empty location copy is %', v_copy;
    END IF;
END $$;
RESET ROLE;
SQL

echo "cached reader sees 5 nationwide rows"
echo "golden CCB patient days is the view value 200/140"
echo "All CCB patient days is 200/336"
