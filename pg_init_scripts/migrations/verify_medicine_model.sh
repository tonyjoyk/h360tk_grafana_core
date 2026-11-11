#!/bin/bash
# Verifies 0.6.7_to_0.6.8 (medicine model): medicines seed, parse_obat, the
# prescription trigger, htn_ladder_steps, visit_step,
# patient_cvd_history, grants and idempotence, against hand-checked fixtures
# (CLINICAL-RULES.md sections 3 to 6).
#
# PSQL defaults to `sudo -u postgres psql`. The demo stack uses:
#   bash -c 'source scripts/h360_env.sh; PSQL=scripts/h360_psql pg_init_scripts/migrations/verify_medicine_model.sh'
# SQL is sent on stdin, so the files need not exist inside a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLES="$ROOT/pg_init_scripts/01_heart360_tables.sql"
MIGRATION_PROTOCOL="$ROOT/pg_init_scripts/migrations/0.6.0_to_0.6.1.sql"
MIGRATION="$ROOT/pg_init_scripts/migrations/0.6.7_to_0.6.8.sql"
DB_NAME="${MEDICINE_MODEL_VERIFY_DB:-medicine_model_verify}"
PSQL="${PSQL:-sudo -u postgres psql}"
read -r -a PSQL_CMD <<< "$PSQL"

if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "verifier-blocked: database name must be a simple identifier" >&2
    exit 1
fi

for required in "$TABLES" "$MIGRATION_PROTOCOL" "$MIGRATION"; do
    if [[ ! -f "$required" ]]; then
        echo "missing file: $required" >&2
        exit 1
    fi
done

if ! grep -q '\\ir migrations/0.6.7_to_0.6.8.sql' "$TABLES"; then
    echo "01_heart360_tables.sql does not include migrations/0.6.7_to_0.6.8.sql" >&2
    exit 1
fi

if ! "${PSQL_CMD[@]}" -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
    echo "verifier-blocked: '$PSQL' cannot connect" >&2
    exit 1
fi

psql_admin() { "${PSQL_CMD[@]}" -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql_db()    { "${PSQL_CMD[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q "$@"; }

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
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk') THEN
        CREATE ROLE heart360tk LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_cached') THEN
        CREATE ROLE heart360tk_cached LOGIN;
    END IF;
END \$\$;
CREATE DATABASE ${DB_NAME} OWNER heart360tk;
SQL

psql_db <<SQL
CREATE SCHEMA heart360tk_schema AUTHORIZATION heart360tk;
CREATE SCHEMA heart360tk_reporting AUTHORIZATION heart360tk;
SQL

echo "apply core tables (01_heart360_tables.sql up to the helper functions)"
sed -n '1,/HELPER FUNCTIONS FOR DYNAMIC HIERARCHY/p' "$TABLES" | psql_db >/dev/null
echo "apply 0.6.0_to_0.6.1 (protocol_drugs)"
psql_db < "$MIGRATION_PROTOCOL" >/dev/null
echo "apply 0.6.7_to_0.6.8"
psql_db < "$MIGRATION" >/dev/null

# ---------------------------------------------------------------------------
# Catalogue, ladder and parser cases (no encounters needed)
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET search_path TO heart360tk_schema;

DO $$
DECLARE
    v_n INT;
    v_bad TEXT;
BEGIN
    SELECT count(*) INTO v_n FROM medicines;
    IF v_n < 60 THEN
        RAISE EXCEPTION 'medicines has % rows, expected at least 60', v_n;
    END IF;

    SELECT string_agg(drug_name || ':' || htn_role || ':' || COALESCE(ladder_class, '-') || ':'
                      || start_mg_day || '/' || full_mg_day || ':' || COALESCE(stock_category, '-'), ', '
                      ORDER BY drug_name)
    INTO v_bad
    FROM medicines WHERE htn_role = 'protocol';
    IF v_bad IS DISTINCT FROM
       'Amlodipine:protocol:CCB:5/10:CCB, Chlorthalidone:protocol:THIAZIDE:12.5/25:Diuretic, '
       'Hydrochlorothiazide:protocol:THIAZIDE:12.5/25:-, Lisinopril:protocol:RAAS:10/20:-, '
       'Telmisartan:protocol:RAAS:40/80:ARB' THEN
        RAISE EXCEPTION 'protocol medicines are %', v_bad;
    END IF;

    SELECT string_agg(drug_name, ', ' ORDER BY drug_name) INTO v_bad FROM medicines WHERE is_statin;
    IF v_bad IS DISTINCT FROM 'Atorvastatin, Rosuvastatin, Simvastatin' THEN
        RAISE EXCEPTION 'statins are %', v_bad;
    END IF;

    SELECT count(*) INTO v_n FROM medicines WHERE htn_role = 'non_protocol';
    IF v_n <> 29 THEN
        RAISE EXCEPTION 'non_protocol medicines: %, expected 29', v_n;
    END IF;

    -- AD-23: every protocol_drugs row names a medicine with the same stock category.
    SELECT string_agg(d.drug_name || ' ' || d.dosage, ', ') INTO v_bad
    FROM protocol_drugs d
    LEFT JOIN medicines m ON m.drug_name = d.drug_name
    WHERE d.drug_category IS DISTINCT FROM m.stock_category;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'protocol_drugs.drug_category <> medicines.stock_category for %', v_bad;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'protocol_drugs_drug_name_fkey') THEN
        RAISE EXCEPTION 'protocol_drugs_drug_name_fkey missing';
    END IF;

    SELECT string_agg(step_no || ':(' || ccb_level || ',' || raas_level || ',' || thz_level || ') ' || label, ' | '
                      ORDER BY step_no)
    INTO v_bad FROM htn_ladder_steps;
    IF v_bad IS DISTINCT FROM
       '1:(1,0,0) 1 medicine, starting dose | 2:(2,0,0) 1 medicine, full dose | '
       '3:(2,1,0) 2 medicines, one at full dose | 4:(2,2,0) 2 medicines, both at full dose | '
       '5:(2,2,1) 3 medicines, third at starting dose | 6:(2,2,2) 3 medicines, all at full dose' THEN
        RAISE EXCEPTION 'ladder is %', v_bad;
    END IF;
END $$;

-- FK blocks a protocol drug that is not in the catalogue.
DO $$
BEGIN
    INSERT INTO protocol_drugs (country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked)
    VALUES ('India', 'IHCI', 'Xyzapril', '10 mg', 'fk-probe', 'Other', FALSE);
    RAISE EXCEPTION 'FK accepted protocol drug Xyzapril';
EXCEPTION
    WHEN foreign_key_violation THEN NULL;
END $$;

-- CLINICAL-RULES section 3 parser table, plus the Obat format edge cases.
CREATE TEMP TABLE parse_expected (
    case_no INT, input TEXT, line_no INT, drug_name TEXT, strength_mg NUMERIC,
    doses_per_day NUMERIC, tablets_per_dose NUMERIC, daily_mg NUMERIC, parse_status TEXT
);
INSERT INTO parse_expected VALUES
    (1,  'Lisinopril 10 mg - 1 x 2 Tablet Sehari', 1, 'Lisinopril', 10, 1, 2, 20, 'ok'),
    (2,  'Amlodipine 5 mg - 1 x 1 Tablet Sehari; Hydrochlorothiazide 12,5 mg - 1 x 1 Tablet Sehari', 1, 'Amlodipine', 5, 1, 1, 5, 'ok'),
    (2,  NULL, 2, 'Hydrochlorothiazide', 12.5, 1, 1, 12.5, 'ok'),
    (3,  'amlodipin 10 mg - 1 x 1 tab', 1, 'Amlodipine', 10, 1, 1, 10, 'ok'),
    (4,  'Captopril 25 mg - 2 x ½ Tablet Sehari', 1, 'Captopril', 25, 2, 0.5, 25, 'ok'),
    (5,  'Atorvastatin 20 mg - 1 x 1 Tablet Sehari | Metformin 500 mg - 2 x 1 Tablet Sehari', 1, 'Atorvastatin', 20, 1, 1, 20, 'ok'),
    (5,  NULL, 2, 'Metformin', 500, 2, 1, 1000, 'ok'),
    (6,  'Xyzapril 10 mg - 1 x 1 Tablet Sehari', 1, NULL, 10, 1, 1, 10, 'unknown_drug'),
    (7,  'Obat herbal 2 x sehari', 1, NULL, NULL, NULL, NULL, NULL, 'unparsed'),
    -- blank strength
    (9,  'Amlodipine - 1 x 1 Tablet Sehari', 1, NULL, NULL, NULL, NULL, NULL, 'unparsed'),
    (10, 'Amlodipine mg - 1 x 1 Tablet Sehari', 1, NULL, NULL, NULL, NULL, NULL, 'unparsed'),
    -- case, spacing, 1/2, Kapsul, CRLF lines, empty pieces between separators
    (11, '  LISINOPRIL 10MG-1X2 TABLET SEHARI  ', 1, 'Lisinopril', 10, 1, 2, 20, 'ok'),
    (12, 'Telmisartan 40 mg - 1 x 1/2 Kapsul', 1, 'Telmisartan', 40, 1, 0.5, 20, 'ok'),
    (13, E'Amlodipine 10 mg - 1 x 1 Tablet Sehari\r\nHCTZ 25 mg - 1 x 1 Tablet Sehari;;\n', 1, 'Amlodipine', 10, 1, 1, 10, 'ok'),
    (13, NULL, 2, 'Hydrochlorothiazide', 25, 1, 1, 25, 'ok'),
    (14, 'Asam mefenamat 500 mg - 3 x 1 Kaplet Sehari', 1, 'Asam mefenamat', 500, 3, 1, 1500, 'ok'),
    (15, 'Amlodipine 10 mcg - 1 x 1 Tablet Sehari', 1, NULL, NULL, NULL, NULL, NULL, 'unparsed');

DO $$
DECLARE
    v_case RECORD;
    v_diff TEXT;
    v_n INT;
BEGIN
    FOR v_case IN SELECT case_no, input FROM parse_expected WHERE input IS NOT NULL ORDER BY case_no LOOP
        SELECT string_agg(format('%s', x), ' ; ') INTO v_diff
        FROM (
            (SELECT e.line_no, e.drug_name, e.strength_mg, e.doses_per_day, e.tablets_per_dose, e.daily_mg, e.parse_status
             FROM parse_expected e WHERE e.case_no = v_case.case_no
             EXCEPT
             SELECT p.line_no, p.drug_name, p.strength_mg, p.doses_per_day, p.tablets_per_dose, p.daily_mg, p.parse_status
             FROM parse_obat(v_case.input) p)
            UNION ALL
            (SELECT p.line_no, p.drug_name, p.strength_mg, p.doses_per_day, p.tablets_per_dose, p.daily_mg, p.parse_status
             FROM parse_obat(v_case.input) p
             EXCEPT
             SELECT e.line_no, e.drug_name, e.strength_mg, e.doses_per_day, e.tablets_per_dose, e.daily_mg, e.parse_status
             FROM parse_expected e WHERE e.case_no = v_case.case_no)
        ) x;
        IF v_diff IS NOT NULL THEN
            RAISE EXCEPTION 'parse_obat case % (%): differs %', v_case.case_no, v_case.input, v_diff;
        END IF;
    END LOOP;

    SELECT count(*) INTO v_n FROM parse_obat('');
    IF v_n <> 0 THEN RAISE EXCEPTION 'empty string gave % lines', v_n; END IF;
    SELECT count(*) INTO v_n FROM parse_obat(NULL);
    IF v_n <> 0 THEN RAISE EXCEPTION 'NULL gave % lines', v_n; END IF;
    SELECT count(*) INTO v_n FROM parse_obat(' ; | ');
    IF v_n <> 0 THEN RAISE EXCEPTION 'separators only gave % lines', v_n; END IF;

    IF (SELECT raw_line FROM parse_obat('Obat herbal 2 x sehari')) IS DISTINCT FROM 'Obat herbal 2 x sehari' THEN
        RAISE EXCEPTION 'unparsed line lost raw_line';
    END IF;
    IF (SELECT parsed_name FROM parse_obat('Xyzapril 10 mg - 1 x 1 Tablet Sehari')) IS DISTINCT FROM 'xyzapril' THEN
        RAISE EXCEPTION 'unknown_drug line lost parsed_name';
    END IF;
END $$;
SQL
echo "catalogue, ladder and parse_obat cases passed"

# ---------------------------------------------------------------------------
# Classifier fixtures: one encounter per case
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

INSERT INTO org_units (id, name, level, parent_id) VALUES (1, 'Fixture PHC', 3, NULL);
INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, birth_date, org_unit_id)
SELECT 1000 + g, 'Fixture ' || g, 'ALIVE', '2026-01-01', '1970-01-01', 1 FROM generate_series(1, 40) g;
INSERT INTO encounters (id, patient_id, encounter_date, org_unit_id)
SELECT g, 1000 + g, '2026-09-01'::timestamp + g * interval '1 hour', 1 FROM generate_series(1, 40) g;

CREATE TABLE fixture_expected (
    encounter_id BIGINT PRIMARY KEY,
    label        TEXT,
    obat_raw     TEXT,
    bucket       TEXT,
    step_no      INT,
    reason       TEXT,
    n_htn_drugs  INT,
    dose_units   NUMERIC,
    on_statin    BOOLEAN
);
INSERT INTO fixture_expected VALUES
    -- every ladder step
    (1,  'step 1: amlodipine 5',
         'Amlodipine 5 mg - 1 x 1 Tablet Sehari',
         'Step 1', 1, 'on_ladder', 1, 0.5, FALSE),
    (2,  'step 2: amlodipine 10 (alias)',
         'amlodipin 10 mg - 1 x 1 tab',
         'Step 2', 2, 'on_ladder', 1, 1.0, FALSE),
    (3,  'step 3: amlodipine 10 + lisinopril 10',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari',
         'Step 3', 3, 'on_ladder', 2, 1.5, FALSE),
    (4,  'step 3: amlodipine 10 + telmisartan 40 (ARB)',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Telmisartan 40 mg - 1 x 1 Tablet Sehari',
         'Step 3', 3, 'on_ladder', 2, 1.5, FALSE),
    (5,  'step 4: amlodipine 10 + lisinopril 10 x 2 (newline)',
         E'Amlodipine 10 mg - 1 x 1 Tablet Sehari\nLisinopril 10 mg - 1 x 2 Tablet Sehari',
         'Step 4', 4, 'on_ladder', 2, 2.0, FALSE),
    (6,  'step 5: amlodipine 10 + telmisartan 80 + HCTZ 12,5 (pipe)',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari | Telmisartan 80 mg - 1 x 1 Tablet Sehari | Hydrochlorothiazide 12,5 mg - 1 x 1 Tablet Sehari',
         'Step 5', 5, 'on_ladder', 3, 2.5, FALSE),
    (7,  'step 6: amlodipine 10 + lisinopril 20 + chlorthalidone 25',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Chlorthalidone 25 mg - 1 x 1 Tablet Sehari',
         'Step 6', 6, 'on_ladder', 3, 3.0, FALSE),
    -- summing lines of the same drug (A67)
    (8,  'sum: amlodipine 5 + amlodipine 5 = 10 -> step 2',
         'Amlodipine 5 mg - 1 x 1 Tablet Sehari; Amlodipine 5 mg - 1 x 1 Tablet Sehari',
         'Step 2', 2, 'on_ladder', 1, 1.0, FALSE),
    (9,  'sum: step 4 + HCTZ 12.5 twice = 25 -> step 6',
         E'Amlodipine 10 mg - 1 x 1 Tablet Sehari\nTelmisartan 80 mg - 1 x 1 Tablet Sehari\nHCTZ 12.5 mg - 1 x 1 Tablet Sehari\nhct 12.5 mg - 1 x 1 Tablet Sehari',
         'Step 6', 6, 'on_ladder', 3, 3.0, FALSE),
    -- Other Protocol
    (10, 'other: lisinopril 10 alone (0,1,0)',
         'Lisinopril 10 mg - 1 x 1 Tablet Sehari',
         'Other Protocol', NULL, 'off_ladder', 1, 0.5, FALSE),
    (11, 'other: amlodipine 5 + lisinopril 10 (1,1,0)',
         'Amlodipine 5 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari',
         'Other Protocol', NULL, 'off_ladder', 2, 1.0, FALSE),
    (12, 'other: two RAAS drugs (lisinopril 20 + telmisartan 80)',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Telmisartan 80 mg - 1 x 1 Tablet Sehari',
         'Other Protocol', NULL, 'two_drugs_one_class', 3, 3.0, FALSE),
    (13, 'other: two thiazides (HCTZ + chlorthalidone)',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Hydrochlorothiazide 25 mg - 1 x 1 Tablet Sehari; Chlorthalidone 12.5 mg - 1 x 1 Tablet Sehari',
         'Other Protocol', NULL, 'two_drugs_one_class', 4, 3.5, FALSE),
    (14, 'other: amlodipine 2.5 below start',
         'Amlodipine 2,5 mg - 1 x 1 Tablet Sehari',
         'Other Protocol', NULL, 'below_start_dose', 1, 0.25, FALSE),
    (15, 'other: amlodipine 5 x ½ = 2.5 below start',
         'Amlodipine 5 mg - 1 x ½ Tablet Sehari',
         'Other Protocol', NULL, 'below_start_dose', 1, 0.25, FALSE),
    (16, 'other: amlodipine 10 + lisinopril 5 below start',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 5 mg - 1 x 1 Tablet Sehari',
         'Other Protocol', NULL, 'below_start_dose', 2, 1.25, FALSE),
    -- Non-Protocol
    (17, 'non-protocol: losartan 50',
         'Losartan 50 mg - 1 x 1 Tablet Sehari',
         'Non-Protocol', NULL, 'non_protocol_drug', 1, 0.5, FALSE),
    (18, 'non-protocol: amlodipine 10 + captopril 25 x 2 x ½',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Captopril 25 mg - 2 x ½ Tablet Sehari',
         'Non-Protocol', NULL, 'non_protocol_drug', 2, 1 + 25::numeric / 150, FALSE),
    (19, 'non-protocol wins over an unreadable line',
         'Bisoprolol 5 mg - 1 x 1 Tablet Sehari; Obat herbal 2 x sehari',
         'Non-Protocol', NULL, 'non_protocol_drug', 1, 0.5, FALSE),
    -- Unrecognized
    (20, 'unreadable: Obat herbal',
         'Obat herbal 2 x sehari',
         'Unrecognized', NULL, 'unreadable', 0, 0, FALSE),
    (21, 'unreadable: unknown drug Xyzapril',
         'Xyzapril 10 mg - 1 x 1 Tablet Sehari',
         'Unrecognized', NULL, 'unreadable', 0, 0, FALSE),
    (22, 'unreadable: blank strength',
         'Amlodipine - 1 x 1 Tablet Sehari',
         'Unrecognized', NULL, 'unreadable', 0, 0, FALSE),
    (23, 'unreadable: step 2 line + an unparsed line',
         'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Amlodipine 1 x 1',
         'Unrecognized', NULL, 'unreadable', 1, 1.0, FALSE),
    (24, 'no_prescription: encounter without a prescriptions row',
         NULL,
         'Unrecognized', NULL, 'no_prescription', 0, 0, NULL),
    (25, 'no_htn_medicine: metformin only',
         'Metformin 500 mg - 2 x 1 Tablet Sehari',
         'Unrecognized', NULL, 'no_htn_medicine', 0, 0, FALSE),
    (26, 'no_htn_medicine: atorvastatin + metformin (on statin)',
         'Atorvastatin 20 mg - 1 x 1 Tablet Sehari | Metformin 500 mg - 2 x 1 Tablet Sehari',
         'Unrecognized', NULL, 'no_htn_medicine', 0, 0, TRUE),
    (27, 'no_htn_medicine: empty Obat cell',
         '',
         'Unrecognized', NULL, 'no_htn_medicine', 0, 0, FALSE),
    -- statins and non-HTN lines are ignored for the bucket
    (28, 'step 1 + simvastatin + metformin',
         'Amlodipine 5 mg - 1 x 1 Tablet Sehari; Simvastatin 20 mg - 1 x 1 Tablet Sehari; Metformin 500 mg - 1 x 1 Tablet Sehari',
         'Step 1', 1, 'on_ladder', 1, 0.5, TRUE),
    (29, 'step 4 + rosuvastatin (Kapsul, upper case)',
         'AMLODIPINE 10 MG - 1 X 1 TABLET SEHARI; TELMISARTAN 40 MG - 2 X 1 TABLET SEHARI; ROSUVASTATIN 10 MG - 1 X 1 KAPSUL',
         'Step 4', 4, 'on_ladder', 2, 2.0, TRUE),
    (30, 'full dose above ladder: amlodipine 15 -> step 2',
         'Amlodipine 5 mg - 3 x 1 Tablet Sehari',
         'Step 2', 2, 'on_ladder', 1, 1.5, FALSE);

INSERT INTO prescriptions (encounter_id, obat_raw, source)
SELECT encounter_id, obat_raw, 'fixture' FROM fixture_expected WHERE obat_raw IS NOT NULL
ON CONFLICT (encounter_id) DO NOTHING;
SQL

check_classifier() {
    psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_diff TEXT;
    v_n INT;
BEGIN
    SELECT string_agg(format('enc %s (%s): expected %s/%s/%s/%s/%s/%s got %s/%s/%s/%s/%s/%s',
                             f.encounter_id, f.label,
                             f.bucket, f.step_no, f.reason, f.n_htn_drugs, f.dose_units, f.on_statin,
                             v.bucket, v.step_no, v.reason, v.n_htn_drugs, v.dose_units, v.on_statin), E'\n'
                      ORDER BY f.encounter_id)
    INTO v_diff
    FROM fixture_expected f
    LEFT JOIN visit_step v ON v.encounter_id = f.encounter_id
    WHERE v.encounter_id IS NULL
       OR v.bucket IS DISTINCT FROM f.bucket
       OR v.step_no IS DISTINCT FROM f.step_no
       OR v.reason IS DISTINCT FROM f.reason
       OR v.n_htn_drugs IS DISTINCT FROM f.n_htn_drugs
       OR v.dose_units IS DISTINCT FROM f.dose_units
       OR v.on_statin IS DISTINCT FROM f.on_statin;
    IF v_diff IS NOT NULL THEN
        RAISE EXCEPTION E'visit_step mismatches:\n%', v_diff;
    END IF;

    -- bucket_order and the step label contract
    IF EXISTS (
        SELECT 1 FROM visit_step v
        WHERE v.bucket_order IS DISTINCT FROM CASE
                WHEN v.step_no IS NOT NULL THEN v.step_no
                WHEN v.bucket = 'Other Protocol' THEN 7
                WHEN v.bucket = 'Non-Protocol' THEN 8
                ELSE 9 END
           OR (v.step_no IS NOT NULL) <> (v.bucket LIKE 'Step %')
    ) THEN
        RAISE EXCEPTION 'bucket_order or step_no inconsistent with bucket';
    END IF;

    -- every bucket the spine lists is covered by the fixture
    SELECT count(DISTINCT bucket) INTO v_n FROM visit_step WHERE encounter_id <= 30;
    IF v_n <> 9 THEN
        RAISE EXCEPTION 'fixture covers % of 9 buckets', v_n;
    END IF;

    -- visit_step carries patient, date and org unit from encounters
    IF EXISTS (
        SELECT 1 FROM visit_step v JOIN encounters e ON e.id = v.encounter_id
        WHERE (v.patient_id, v.encounter_date, v.org_unit_id) IS DISTINCT FROM (e.patient_id, e.encounter_date, e.org_unit_id)
    ) OR (SELECT count(*) FROM visit_step) <> (SELECT count(*) FROM encounters) THEN
        RAISE EXCEPTION 'visit_step is not one row per encounter';
    END IF;
END $$;
SQL
}

check_classifier
echo "classifier fixtures passed"

psql_db <<'SQL'
SET search_path TO heart360tk_schema;
\pset footer off
SELECT v.encounter_id AS enc, f.label, v.bucket, v.step_no, v.reason, v.n_htn_drugs AS n_htn,
       round(v.dose_units, 3) AS dose_units, v.on_statin,
       '(' || v.ccb_level || ',' || v.raas_level || ',' || v.thz_level || ')' AS levels
FROM visit_step v JOIN fixture_expected f USING (encounter_id)
ORDER BY v.encounter_id;
SQL

# ---------------------------------------------------------------------------
# Trigger behaviour: update re-parses, delete cascades, lines match parse_obat
# ---------------------------------------------------------------------------
psql_db <<'SQL'
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    v_n INT;
    v_bucket TEXT;
BEGIN
    SELECT count(*) INTO v_n FROM prescription_lines WHERE encounter_id = 13;
    IF v_n <> 4 THEN RAISE EXCEPTION 'encounter 13 has % lines, expected 4', v_n; END IF;

    IF EXISTS (
        SELECT 1 FROM prescriptions p
        CROSS JOIN LATERAL parse_obat(p.obat_raw) x
        LEFT JOIN prescription_lines l ON l.encounter_id = p.encounter_id AND l.line_no = x.line_no
        WHERE (l.raw_line, l.drug_name, l.daily_mg, l.parse_status)
              IS DISTINCT FROM (x.raw_line, x.drug_name, x.daily_mg, x.parse_status)
    ) OR (SELECT count(*) FROM prescription_lines)
         <> (SELECT count(*) FROM prescriptions p CROSS JOIN LATERAL parse_obat(p.obat_raw) x) THEN
        RAISE EXCEPTION 'stored prescription_lines differ from parse_obat';
    END IF;

    UPDATE prescriptions SET obat_raw = 'Amlodipine 10 mg - 1 x 1 Tablet Sehari' WHERE encounter_id = 13;
    SELECT count(*) INTO v_n FROM prescription_lines WHERE encounter_id = 13;
    SELECT bucket INTO v_bucket FROM visit_step WHERE encounter_id = 13;
    IF v_n <> 1 OR v_bucket <> 'Step 2' THEN
        RAISE EXCEPTION 'update did not re-parse: % lines, %', v_n, v_bucket;
    END IF;

    INSERT INTO prescriptions (encounter_id, obat_raw) VALUES (13, 'Losartan 50 mg - 1 x 1 Tablet Sehari')
    ON CONFLICT (encounter_id) DO NOTHING;
    SELECT bucket INTO v_bucket FROM visit_step WHERE encounter_id = 13;
    IF v_bucket <> 'Step 2' THEN
        RAISE EXCEPTION 'ON CONFLICT DO NOTHING changed encounter 13 to %', v_bucket;
    END IF;

    UPDATE prescriptions p SET obat_raw = f.obat_raw FROM fixture_expected f
    WHERE f.encounter_id = p.encounter_id AND p.encounter_id = 13;

    INSERT INTO prescriptions (encounter_id, obat_raw) VALUES (40, 'Amlodipine 5 mg - 1 x 1 Tablet Sehari');
    IF (SELECT source FROM prescriptions WHERE encounter_id = 40) <> 'demo' THEN
        RAISE EXCEPTION 'source default is not demo';
    END IF;
    DELETE FROM encounters WHERE id = 40;
    IF EXISTS (SELECT 1 FROM prescriptions WHERE encounter_id = 40)
       OR EXISTS (SELECT 1 FROM prescription_lines WHERE encounter_id = 40) THEN
        RAISE EXCEPTION 'deleting an encounter left prescription rows';
    END IF;

    BEGIN
        INSERT INTO prescriptions (encounter_id, obat_raw) VALUES (999999, 'Amlodipine 5 mg - 1 x 1');
        RAISE EXCEPTION 'prescription accepted a missing encounter';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
END $$;

-- patient_cvd_history
INSERT INTO patient_cvd_history (patient_id, event_type, event_date) VALUES
    (1001, 'MI', '2025-03-01'), (1002, 'STROKE', '2024-11-15')
ON CONFLICT DO NOTHING;
INSERT INTO patient_cvd_history (patient_id, event_type, event_date) VALUES (1001, 'MI', '2025-03-01')
ON CONFLICT DO NOTHING;
DO $$
BEGIN
    IF (SELECT count(*) FROM patient_cvd_history) <> 2 THEN
        RAISE EXCEPTION 'patient_cvd_history ON CONFLICT DO NOTHING duplicated a row';
    END IF;
    BEGIN
        INSERT INTO patient_cvd_history (patient_id, event_type, event_date) VALUES (1003, 'ANGINA', '2025-01-01');
        RAISE EXCEPTION 'patient_cvd_history accepted ANGINA';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END $$;
SQL
echo "trigger, cascade and patient_cvd_history checks passed"

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------
psql_db <<'SQL'
DO $$
DECLARE
    v_obj TEXT;
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'heart360tk_cached'] LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role);
        FOREACH v_obj IN ARRAY ARRAY['medicines', 'htn_ladder_steps', 'prescriptions', 'prescription_lines',
                                     'patient_cvd_history', 'visit_step'] LOOP
            IF NOT has_table_privilege(v_role, 'heart360tk_schema.' || v_obj, 'SELECT') THEN
                RAISE EXCEPTION '% lacks SELECT on %', v_role, v_obj;
            END IF;
            IF has_table_privilege(v_role, 'heart360tk_schema.' || v_obj, 'INSERT, UPDATE, DELETE, TRUNCATE') THEN
                RAISE EXCEPTION '% can write %', v_role, v_obj;
            END IF;
        END LOOP;
    END LOOP;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader')
       AND NOT has_function_privilege('heart360tk_reader', 'heart360tk_schema.parse_obat(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'heart360tk_reader lacks EXECUTE on parse_obat';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'heart360tk_schema'
          AND p.proname IN ('parse_obat', 'prescriptions_parse_trigger')
          AND (p.prosecdef
               OR pg_get_userbyid(p.proowner) <> 'heart360tk'
               OR has_function_privilege('public', p.oid, 'EXECUTE')
               OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=heart360tk_schema, pg_temp'))
    ) THEN
        RAISE EXCEPTION 'a medicine-model function is definer, not owned by heart360tk, executable by PUBLIC or has no pinned search_path';
    END IF;

    IF EXISTS (
        SELECT 1 FROM unnest(ARRAY['medicines', 'htn_ladder_steps', 'prescriptions', 'prescription_lines',
                                   'patient_cvd_history', 'visit_step']) t
        WHERE has_table_privilege('public', 'heart360tk_schema.' || t, 'SELECT')
           OR (SELECT pg_get_userbyid(c.relowner) FROM pg_class c
               WHERE c.oid = ('heart360tk_schema.' || t)::regclass) <> 'heart360tk'
    ) THEN
        RAISE EXCEPTION 'a medicine-model relation is readable by PUBLIC or not owned by heart360tk';
    END IF;
END $$;
SQL
echo "privilege checks passed"

# ---------------------------------------------------------------------------
# Idempotence: a second apply keeps data, re-parses and gives the same buckets
# ---------------------------------------------------------------------------
psql_db <<'SQL' >/dev/null
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
CREATE TABLE before_counts AS
SELECT (SELECT count(*) FROM medicines) AS medicines_n,
       (SELECT count(*) FROM htn_ladder_steps) AS ladder_n,
       (SELECT count(*) FROM prescriptions) AS prescriptions_n,
       (SELECT count(*) FROM prescription_lines) AS lines_n,
       (SELECT count(*) FROM patient_cvd_history) AS cvd_n;
-- A tuned seed row that the re-apply must keep (ON CONFLICT DO NOTHING).
UPDATE htn_ladder_steps SET label = 'tuned' WHERE step_no = 1;
-- A catalogue addition is picked up by re-parsing (the re-apply re-parses every cell).
INSERT INTO medicines (drug_name, aliases, drug_class, htn_role) VALUES ('Xyzapril', ARRAY['xyzapril'], 'ACE inhibitor', 'not_htn');
UPDATE prescriptions SET obat_raw = obat_raw WHERE encounter_id = 21;
SQL
if [[ "$(psql_db -tA -c "SELECT parse_status FROM heart360tk_schema.prescription_lines WHERE encounter_id = 21")" != "ok" ]]; then
    echo "catalogue addition was not picked up by the re-parse" >&2
    exit 1
fi
psql_db -c "SET ROLE heart360tk; DELETE FROM heart360tk_schema.prescription_lines WHERE encounter_id = 21; DELETE FROM heart360tk_schema.medicines WHERE drug_name = 'Xyzapril';" >/dev/null

echo "apply 0.6.7_to_0.6.8 again"
psql_db < "$MIGRATION" >/dev/null

psql_db <<'SQL'
SET search_path TO heart360tk_schema;
DO $$
DECLARE
    b RECORD;
BEGIN
    SELECT * INTO b FROM before_counts;
    IF (SELECT count(*) FROM medicines) <> b.medicines_n
       OR (SELECT count(*) FROM htn_ladder_steps) <> b.ladder_n
       OR (SELECT count(*) FROM prescriptions) <> b.prescriptions_n
       OR (SELECT count(*) FROM prescription_lines) <> b.lines_n
       OR (SELECT count(*) FROM patient_cvd_history) <> b.cvd_n THEN
        RAISE EXCEPTION 'second apply changed row counts';
    END IF;
    IF (SELECT label FROM htn_ladder_steps WHERE step_no = 1) <> 'tuned' THEN
        RAISE EXCEPTION 'second apply reset a tuned ladder row';
    END IF;
    UPDATE htn_ladder_steps SET label = '1 medicine, starting dose' WHERE step_no = 1;
    IF (SELECT count(*) FROM pg_constraint WHERE conname = 'protocol_drugs_drug_name_fkey') <> 1 THEN
        RAISE EXCEPTION 'second apply duplicated the protocol_drugs FK';
    END IF;
END $$;
SQL
check_classifier
echo "second apply is idempotent and classifier fixtures still pass"

echo "medicine model verified"
