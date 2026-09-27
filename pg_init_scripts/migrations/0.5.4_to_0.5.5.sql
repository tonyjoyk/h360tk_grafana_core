BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- Patient-Days reads Latest Wins rows already stored on
-- drug_stock_submission (org_unit_id, reporting_month, rxnorm_code).
-- N is heart360tk_reporting.HEART360_PATIENTS_REGISTERED.cumulative_number_of_patients
-- on org_unit_id and ref_month. That table is the copy of
-- heart360tk_schema.HEART360_PATIENTS_REGISTERED: patients who are not dead,
-- with diagnosis I10, cumulative through ref_month. Under-care is not read.
-- deploy_setting active_programme selects both active_stock_tracked_drugs and
-- coeff_config. category_patient_days = sum(in_stock * dose_factor)
-- / (patients_n * load_factor * category_coeff).

ALTER TABLE protocol_drugs
    ADD COLUMN IF NOT EXISTS dose_factor NUMERIC;

UPDATE protocol_drugs
SET dose_factor = 1
WHERE dose_factor IS NULL;

ALTER TABLE protocol_drugs
    ALTER COLUMN dose_factor SET DEFAULT 1;

ALTER TABLE protocol_drugs
    ALTER COLUMN dose_factor SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'protocol_drugs_dose_factor_positive'
          AND conrelid = 'heart360tk_schema.protocol_drugs'::regclass
    ) THEN
        ALTER TABLE protocol_drugs
            ADD CONSTRAINT protocol_drugs_dose_factor_positive
            CHECK (dose_factor > 0);
    END IF;
END $$;

UPDATE protocol_drugs
SET dose_factor = CASE rxnorm_code
    WHEN '329528' THEN 1
    WHEN '329526' THEN 2
    WHEN '316764' THEN 1
    WHEN '316765' THEN 2
    WHEN '331132' THEN 1
    WHEN '197499' THEN 2
    ELSE dose_factor
END
WHERE rxnorm_code IN ('329528', '329526', '316764', '316765', '331132', '197499');

CREATE TABLE IF NOT EXISTS coeff_config (
    country_code   VARCHAR(64) NOT NULL,
    programme_code VARCHAR(64) NOT NULL,
    drug_category  VARCHAR(64) NOT NULL,
    category_coeff NUMERIC     NOT NULL,
    load_factor    NUMERIC     NOT NULL DEFAULT 1.0,
    PRIMARY KEY (country_code, programme_code, drug_category),
    CONSTRAINT coeff_config_programme_fkey
        FOREIGN KEY (country_code, programme_code)
        REFERENCES programme_protocols (country_code, programme_code)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT coeff_config_drug_category_check
        CHECK (drug_category IN ('CCB', 'ARB', 'Diuretic', 'Other')),
    CONSTRAINT coeff_config_category_coeff_positive
        CHECK (category_coeff > 0),
    CONSTRAINT coeff_config_load_factor_positive
        CHECK (load_factor > 0)
);

-- India/IHCI AATTCC. Amlo 1.4, Telmi 0.37, Chlor 0.06. Load factor default 1.0.
INSERT INTO coeff_config (
    country_code, programme_code, drug_category, category_coeff, load_factor
) VALUES
    ('India', 'IHCI', 'CCB',      1.4,  1.0),
    ('India', 'IHCI', 'ARB',      0.37, 1.0),
    ('India', 'IHCI', 'Diuretic', 0.06, 1.0)
ON CONFLICT (country_code, programme_code, drug_category) DO UPDATE
    SET category_coeff = EXCLUDED.category_coeff,
        load_factor    = EXCLUDED.load_factor;

CREATE OR REPLACE VIEW heart360tk_reporting.drug_stock_patient_days AS
WITH active AS (
    SELECT
        s.country_code,
        s.programme_code,
        d.drug_category,
        d.rxnorm_code,
        d.drug_name,
        d.dosage,
        p.dose_factor,
        c.load_factor,
        c.category_coeff
    FROM deploy_setting s
    JOIN active_stock_tracked_drugs d
      ON d.country_code = s.country_code
     AND d.programme_code = s.programme_code
    JOIN protocol_drugs p
      ON p.country_code = d.country_code
     AND p.programme_code = d.programme_code
     AND p.rxnorm_code = d.rxnorm_code
    LEFT JOIN coeff_config c
      ON c.country_code = s.country_code
     AND c.programme_code = s.programme_code
     AND c.drug_category = d.drug_category
    WHERE s.setting_name = 'active_programme'
),
months AS (
    SELECT DISTINCT sub.reporting_month
    FROM drug_stock_submission sub
    JOIN deploy_setting s
      ON s.setting_name = 'active_programme'
     AND s.country_code = sub.country_code
     AND s.programme_code = sub.programme_code
),
reported AS (
    SELECT sub.org_unit_id, sub.reporting_month
    FROM drug_stock_submission sub
    GROUP BY sub.org_unit_id, sub.reporting_month
),
base AS (
    SELECT
        cohort.org_unit_id,
        ou.name AS facility_name,
        months.reporting_month,
        active.drug_category,
        active.rxnorm_code,
        active.drug_name,
        active.dosage,
        (reported.org_unit_id IS NOT NULL) AS submission_present,
        sub.in_stock,
        active.dose_factor,
        reg.cumulative_number_of_patients::numeric AS patients_n,
        active.load_factor,
        active.category_coeff,
        CASE
            WHEN sub.in_stock IS NULL THEN NULL
            ELSE sub.in_stock * active.dose_factor
        END AS normalized_stock
    FROM drug_stock_form_cohort cohort
    JOIN org_units ou
      ON ou.id = cohort.org_unit_id
    CROSS JOIN months
    CROSS JOIN active
    LEFT JOIN reported
      ON reported.org_unit_id = cohort.org_unit_id
     AND reported.reporting_month = months.reporting_month
    LEFT JOIN drug_stock_submission sub
      ON sub.org_unit_id = cohort.org_unit_id
     AND sub.reporting_month = months.reporting_month
     AND sub.rxnorm_code = active.rxnorm_code
     AND sub.country_code = active.country_code
     AND sub.programme_code = active.programme_code
    LEFT JOIN heart360tk_reporting.heart360_patients_registered reg
      ON reg.org_unit_id = cohort.org_unit_id
     AND reg.ref_month = months.reporting_month
)
SELECT
    org_unit_id,
    facility_name,
    reporting_month,
    drug_category,
    rxnorm_code,
    drug_name,
    dosage,
    submission_present,
    in_stock,
    dose_factor,
    patients_n,
    load_factor,
    category_coeff,
    normalized_stock,
    CASE
        WHEN patients_n IS NULL OR patients_n = 0 THEN NULL
        WHEN load_factor IS NULL OR category_coeff IS NULL THEN NULL
        WHEN load_factor = 0 OR category_coeff = 0 THEN NULL
        WHEN category_normalized_stock IS NULL THEN NULL
        ELSE category_normalized_stock / (patients_n * load_factor * category_coeff)
    END AS category_patient_days
FROM (
    SELECT
        org_unit_id,
        facility_name,
        reporting_month,
        drug_category,
        rxnorm_code,
        drug_name,
        dosage,
        submission_present,
        in_stock,
        dose_factor,
        patients_n,
        load_factor,
        category_coeff,
        normalized_stock,
        SUM(normalized_stock) OVER (
            PARTITION BY org_unit_id, reporting_month, drug_category
        ) AS category_normalized_stock
    FROM base
) scored;

COMMENT ON VIEW heart360tk_reporting.drug_stock_patient_days IS
    'Patient-Days = sum(in_stock * dose_factor) / (registered cumulative_number_of_patients * load_factor * category_coeff). Null in_stock stays null. patients_n null or 0 yields null.';

REVOKE ALL ON TABLE coeff_config FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana') THEN
        EXECUTE 'REVOKE ALL ON TABLE heart360tk_schema.coeff_config FROM grafana';
        EXECUTE 'GRANT SELECT ON heart360tk_reporting.drug_stock_patient_days TO grafana';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_cached') THEN
        EXECUTE 'GRANT SELECT ON heart360tk_reporting.drug_stock_patient_days TO heart360tk_cached';
    END IF;
END $$;

COMMIT;
