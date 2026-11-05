BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

CREATE TABLE IF NOT EXISTS programme_protocols (
    country_code   VARCHAR(64) NOT NULL,
    programme_code VARCHAR(64) NOT NULL,
    protocol_code  VARCHAR(16) NOT NULL,
    PRIMARY KEY (country_code, programme_code),
    CONSTRAINT programme_protocols_protocol_code_check
        CHECK (protocol_code IN ('AATTCC', 'ATTACC'))
);

CREATE TABLE IF NOT EXISTS protocol_drugs (
    country_code   VARCHAR(64)  NOT NULL,
    programme_code VARCHAR(64)  NOT NULL,
    drug_name      VARCHAR(255) NOT NULL,
    dosage         VARCHAR(64)  NOT NULL,
    rxnorm_code    VARCHAR(64)  NOT NULL,
    drug_category  VARCHAR(64)  NOT NULL,
    stock_tracked  BOOLEAN      NOT NULL,
    PRIMARY KEY (country_code, programme_code, rxnorm_code),
    CONSTRAINT protocol_drugs_programme_fkey
        FOREIGN KEY (country_code, programme_code)
        REFERENCES programme_protocols (country_code, programme_code)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT protocol_drugs_drug_category_check
        CHECK (drug_category IN ('CCB', 'ARB', 'Diuretic', 'Other'))
);

CREATE TABLE IF NOT EXISTS deploy_setting (
    setting_name   VARCHAR(64) PRIMARY KEY,
    country_code   VARCHAR(64) NOT NULL,
    programme_code VARCHAR(64) NOT NULL,
    CONSTRAINT deploy_setting_programme_fkey
        FOREIGN KEY (country_code, programme_code)
        REFERENCES programme_protocols (country_code, programme_code)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT deploy_setting_active_programme_only
        CHECK (setting_name = 'active_programme')
);

-- India/IHCI is AATTCC. The WHO IHCI pharmacist guide uses amlodipine 1.4,
-- telmisartan 0.37, and chlorthalidone 0.06 for AATTCC, and 1.12, 0.65, and
-- 0.06 for ATTACC. simple-server drug_stock_config.yml gives the AATTCC pair
-- to 10 Indian states and the ATTACC pair to 8.
INSERT INTO programme_protocols (country_code, programme_code, protocol_code)
VALUES ('India', 'IHCI', 'AATTCC')
ON CONFLICT (country_code, programme_code) DO UPDATE
    SET protocol_code = EXCLUDED.protocol_code;

INSERT INTO protocol_drugs (
    country_code, programme_code, drug_name, dosage, rxnorm_code, drug_category, stock_tracked
) VALUES
    ('India', 'IHCI', 'Amlodipine',      '5 mg',    '329528', 'CCB',      TRUE),
    ('India', 'IHCI', 'Amlodipine',      '10 mg',   '329526', 'CCB',      TRUE),
    ('India', 'IHCI', 'Telmisartan',     '40 mg',   '316764', 'ARB',      TRUE),
    ('India', 'IHCI', 'Telmisartan',     '80 mg',   '316765', 'ARB',      TRUE),
    ('India', 'IHCI', 'Chlorthalidone',  '12.5 mg', '331132', 'Diuretic', TRUE),
    ('India', 'IHCI', 'Chlorthalidone',  '25 mg',   '197499', 'Diuretic', TRUE)
ON CONFLICT (country_code, programme_code, rxnorm_code) DO UPDATE
    SET drug_name     = EXCLUDED.drug_name,
        dosage        = EXCLUDED.dosage,
        drug_category = EXCLUDED.drug_category,
        stock_tracked = EXCLUDED.stock_tracked;

INSERT INTO deploy_setting (setting_name, country_code, programme_code)
VALUES ('active_programme', 'India', 'IHCI')
ON CONFLICT (setting_name) DO UPDATE
    SET country_code   = EXCLUDED.country_code,
        programme_code = EXCLUDED.programme_code;

DO $$
BEGIN
    ALTER TABLE protocol_drugs
        ADD CONSTRAINT protocol_drugs_drug_category_check
        CHECK (drug_category IN ('CCB', 'ARB', 'Diuretic', 'Other'));
EXCEPTION
    WHEN duplicate_object THEN
        NULL;
END $$;

CREATE OR REPLACE VIEW active_stock_tracked_drugs AS
SELECT
    d.country_code,
    d.programme_code,
    p.protocol_code,
    d.drug_name,
    d.dosage,
    d.rxnorm_code,
    d.drug_category,
    d.stock_tracked
FROM deploy_setting s
JOIN programme_protocols p
  ON p.country_code = s.country_code
 AND p.programme_code = s.programme_code
JOIN protocol_drugs d
  ON d.country_code = s.country_code
 AND d.programme_code = s.programme_code
WHERE s.setting_name = 'active_programme'
  AND d.stock_tracked;

COMMIT;
