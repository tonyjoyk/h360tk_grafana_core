-- 0.6.7_to_0.6.8: medicine model: medicines, prescriptions, parse_obat, ladder, visit_step (AD-23 to AD-25)
--
-- medicines            the one medicine catalogue (AD-23). protocol_drugs.drug_name references it.
-- prescriptions        the Obat cell as received, one per encounter (AD-24).
-- prescription_lines   written only by the trg_prescriptions_parse_* triggers through parse_obat (AD-24).
-- htn_ladder_steps     the ladder as data (CR-1). Replace its rows to change the ladder.
-- visit_step           the only classifier (AD-25, CR-1). classify_visit_step is a thin wrapper.
-- patient_cvd_history  heart attack and stroke events for statin eligibility (CR-5).
--
-- Obat cell: lines are separated by ';', '|' or a newline. Each line is
-- '<drug> <strength> mg - <doses a day> x <tablets a dose> [Tablet|Tab|Kaplet|Kapsul|Capsule] [Sehari]',
-- e.g. 'Lisinopril 10 mg - 1 x 2 Tablet Sehari' = 20 mg a day.
-- Seeds insert raw text only:
--   INSERT INTO prescriptions (encounter_id, obat_raw, source) VALUES (...) ON CONFLICT (encounter_id) DO NOTHING;
-- Any UPDATE re-parses its rows; after a catalogue change: UPDATE prescriptions SET obat_raw = obat_raw;
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- medicines
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS medicines (
    drug_name      TEXT PRIMARY KEY,
    aliases        TEXT[]  NOT NULL,
    drug_class     TEXT    NOT NULL,
    ladder_class   TEXT    NULL,
    htn_role       TEXT    NOT NULL,
    is_statin      BOOLEAN NOT NULL DEFAULT FALSE,
    start_mg_day   NUMERIC NULL,
    full_mg_day    NUMERIC NULL,
    stock_category TEXT    NULL,
    CONSTRAINT medicines_ladder_class_check
        CHECK (ladder_class IN ('CCB', 'RAAS', 'THIAZIDE')),
    CONSTRAINT medicines_htn_role_check
        CHECK (htn_role IN ('protocol', 'non_protocol', 'not_htn')),
    CONSTRAINT medicines_protocol_complete
        CHECK (htn_role <> 'protocol'
               OR (ladder_class IS NOT NULL AND start_mg_day > 0 AND full_mg_day >= start_mg_day)),
    CONSTRAINT medicines_ladder_only_protocol
        CHECK (ladder_class IS NULL OR htn_role = 'protocol'),
    CONSTRAINT medicines_statin_not_htn
        CHECK (NOT is_statin OR htn_role = 'not_htn'),
    CONSTRAINT medicines_aliases_include_name
        CHECK (lower(drug_name) = ANY (aliases)),
    CONSTRAINT medicines_aliases_lowercase
        CHECK (array_to_string(aliases, '|') = lower(array_to_string(aliases, '|')))
);

CREATE INDEX IF NOT EXISTS idx_medicines_aliases ON medicines USING gin (aliases);

INSERT INTO medicines (
    drug_name, aliases, drug_class, ladder_class, htn_role, is_statin, start_mg_day, full_mg_day, stock_category
) VALUES
    -- Protocol (CR-1 ladder drugs)
    ('Amlodipine',          ARRAY['amlodipine', 'amlodipin', 'amlodipine besylate', 'amlodipin besilat'],
                            'CCB',           'CCB',      'protocol', FALSE, 5,    10,  'CCB'),
    ('Lisinopril',          ARRAY['lisinopril'],
                            'ACE inhibitor', 'RAAS',     'protocol', FALSE, 10,   20,  NULL),
    ('Telmisartan',         ARRAY['telmisartan'],
                            'ARB',           'RAAS',     'protocol', FALSE, 40,   80,  'ARB'),
    ('Hydrochlorothiazide', ARRAY['hydrochlorothiazide', 'hctz', 'hct', 'hidroklorotiazid'],
                            'Thiazide',      'THIAZIDE', 'protocol', FALSE, 12.5, 25,  NULL),
    ('Chlorthalidone',      ARRAY['chlorthalidone', 'chlortalidone', 'klortalidon'],
                            'Thiazide-like', 'THIAZIDE', 'protocol', FALSE, 12.5, 25,  'Diuretic'),
    -- Statins
    ('Atorvastatin',  ARRAY['atorvastatin', 'atorvastatin calcium', 'atorvastatin kalsium'],
                      'Statin', NULL, 'not_htn', TRUE, NULL, NULL, NULL),
    ('Simvastatin',   ARRAY['simvastatin'],
                      'Statin', NULL, 'not_htn', TRUE, NULL, NULL, NULL),
    ('Rosuvastatin',  ARRAY['rosuvastatin', 'rosuvastatin calcium', 'rosuvastatin kalsium'],
                      'Statin', NULL, 'not_htn', TRUE, NULL, NULL, NULL),
    -- Non-protocol HTN (start / full mg a day)
    ('Losartan',       ARRAY['losartan', 'losartan potassium', 'losartan kalium'],        'ARB', NULL, 'non_protocol', FALSE, 50,   100, NULL),
    ('Valsartan',      ARRAY['valsartan'],                                                'ARB', NULL, 'non_protocol', FALSE, 80,   160, NULL),
    ('Candesartan',    ARRAY['candesartan', 'kandesartan', 'candesartan cilexetil', 'kandesartan sileksetil'],
                                                                                          'ARB', NULL, 'non_protocol', FALSE, 8,    16,  NULL),
    ('Irbesartan',     ARRAY['irbesartan'],                                               'ARB', NULL, 'non_protocol', FALSE, 150,  300, NULL),
    ('Olmesartan',     ARRAY['olmesartan', 'olmesartan medoxomil'],                       'ARB', NULL, 'non_protocol', FALSE, 20,   40,  NULL),
    ('Captopril',      ARRAY['captopril', 'kaptopril'],                                   'ACE inhibitor', NULL, 'non_protocol', FALSE, 50,  150, NULL),
    ('Enalapril',      ARRAY['enalapril', 'enalapril maleate', 'enalapril maleat'],       'ACE inhibitor', NULL, 'non_protocol', FALSE, 5,   20,  NULL),
    ('Ramipril',       ARRAY['ramipril'],                                                 'ACE inhibitor', NULL, 'non_protocol', FALSE, 2.5, 10,  NULL),
    ('Perindopril',    ARRAY['perindopril', 'perindopril arginine', 'perindopril erbumine'],
                                                                                          'ACE inhibitor', NULL, 'non_protocol', FALSE, 4,   8,   NULL),
    ('Imidapril',      ARRAY['imidapril'],                                                'ACE inhibitor', NULL, 'non_protocol', FALSE, 5,   10,  NULL),
    ('Nifedipine',     ARRAY['nifedipine', 'nifedipin'],                                  'CCB', NULL, 'non_protocol', FALSE, 30,   60,  NULL),
    ('Felodipine',     ARRAY['felodipine', 'felodipin'],                                  'CCB', NULL, 'non_protocol', FALSE, 5,    10,  NULL),
    ('Lercanidipine',  ARRAY['lercanidipine', 'lerkanidipin'],                            'CCB', NULL, 'non_protocol', FALSE, 10,   20,  NULL),
    ('Nicardipine',    ARRAY['nicardipine', 'nikardipin'],                                'CCB', NULL, 'non_protocol', FALSE, 60,   120, NULL),
    ('Diltiazem',      ARRAY['diltiazem'],                                                'CCB, non-dihydropyridine', NULL, 'non_protocol', FALSE, 180, 360, NULL),
    ('Verapamil',      ARRAY['verapamil'],                                                'CCB, non-dihydropyridine', NULL, 'non_protocol', FALSE, 120, 240, NULL),
    ('Bisoprolol',     ARRAY['bisoprolol', 'bisoprolol fumarate', 'bisoprolol fumarat'],  'Beta blocker', NULL, 'non_protocol', FALSE, 5,    10,  NULL),
    ('Atenolol',       ARRAY['atenolol'],                                                 'Beta blocker', NULL, 'non_protocol', FALSE, 50,   100, NULL),
    ('Metoprolol',     ARRAY['metoprolol', 'metoprolol tartrate', 'metoprolol tartrat', 'metoprolol succinate'],
                                                                                          'Beta blocker', NULL, 'non_protocol', FALSE, 50,   100, NULL),
    ('Propranolol',    ARRAY['propranolol', 'propanolol'],                                'Beta blocker', NULL, 'non_protocol', FALSE, 80,   160, NULL),
    ('Carvedilol',     ARRAY['carvedilol', 'karvedilol'],                                 'Beta blocker', NULL, 'non_protocol', FALSE, 12.5, 50,  NULL),
    ('Furosemide',     ARRAY['furosemide', 'furosemid'],                                  'Loop diuretic', NULL, 'non_protocol', FALSE, 20,  80,  NULL),
    ('Spironolactone', ARRAY['spironolactone', 'spironolakton', 'spironolacton'],         'Potassium-sparing diuretic', NULL, 'non_protocol', FALSE, 25, 50, NULL),
    ('Indapamide',     ARRAY['indapamide', 'indapamid'],                                  'Thiazide-like', NULL, 'non_protocol', FALSE, 1.5, 2.5, NULL),
    ('Clonidine',      ARRAY['clonidine', 'klonidin'],                                    'Central alpha agonist', NULL, 'non_protocol', FALSE, 0.15, 0.6, NULL),
    ('Methyldopa',     ARRAY['methyldopa', 'metildopa'],                                  'Central alpha agonist', NULL, 'non_protocol', FALSE, 500, 1500, NULL),
    ('Hydralazine',    ARRAY['hydralazine', 'hidralazin'],                                'Vasodilator', NULL, 'non_protocol', FALSE, 50,   200, NULL),
    ('Prazosin',       ARRAY['prazosin'],                                                 'Alpha blocker', NULL, 'non_protocol', FALSE, 2,    10,  NULL),
    ('Doxazosin',      ARRAY['doxazosin', 'doksazosin'],                                  'Alpha blocker', NULL, 'non_protocol', FALSE, 1,    8,   NULL),
    -- Non-HTN (ignored by the classifier; listed so they are not unknown_drug)
    ('Metformin',          ARRAY['metformin', 'metformin hcl'],                         'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Glimepiride',        ARRAY['glimepiride', 'glimepirid'],                          'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Glibenclamide',      ARRAY['glibenclamide', 'glibenklamid'],                      'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Gliclazide',         ARRAY['gliclazide', 'gliklazid'],                            'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Glipizide',          ARRAY['glipizide', 'glipizid'],                              'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Acarbose',           ARRAY['acarbose', 'akarbosa'],                               'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Pioglitazone',       ARRAY['pioglitazone', 'pioglitazon'],                        'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Insulin',            ARRAY['insulin'],                                            'Antidiabetic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Aspirin',            ARRAY['aspirin', 'asam asetilsalisilat', 'asetosal'],        'Antiplatelet', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Clopidogrel',        ARRAY['clopidogrel', 'klopidogrel'],                         'Antiplatelet', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Paracetamol',        ARRAY['paracetamol', 'parasetamol', 'acetaminophen'],        'Analgesic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Ibuprofen',          ARRAY['ibuprofen'],                                          'Analgesic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Asam mefenamat',     ARRAY['asam mefenamat', 'mefenamic acid'],                   'Analgesic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Amoxicillin',        ARRAY['amoxicillin', 'amoksisilin', 'amoxicilin'],           'Antibiotic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Ciprofloxacin',      ARRAY['ciprofloxacin', 'siprofloksasin'],                    'Antibiotic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Omeprazole',         ARRAY['omeprazole', 'omeprazol'],                            'Proton pump inhibitor', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Lansoprazole',       ARRAY['lansoprazole', 'lansoprazol'],                        'Proton pump inhibitor', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Ranitidine',         ARRAY['ranitidine', 'ranitidin'],                            'H2 blocker', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Antasida',           ARRAY['antasida', 'antacid'],                                'Antacid', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Allopurinol',        ARRAY['allopurinol', 'alopurinol'],                          'Antigout', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Cetirizine',         ARRAY['cetirizine', 'setirizin'],                            'Antihistamine', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Chlorpheniramine',   ARRAY['chlorpheniramine', 'ctm', 'klorfeniramin', 'chlorpheniramine maleate'],
                                                                                        'Antihistamine', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Dexamethasone',      ARRAY['dexamethasone', 'deksametason'],                      'Corticosteroid', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Prednisone',         ARRAY['prednisone', 'prednison'],                            'Corticosteroid', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Ambroxol',           ARRAY['ambroxol', 'ambroksol'],                              'Mucolytic', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Vitamin B complex',  ARRAY['vitamin b complex', 'vitamin b kompleks'],            'Vitamin', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Asam folat',         ARRAY['asam folat', 'folic acid'],                           'Vitamin', NULL, 'not_htn', FALSE, NULL, NULL, NULL),
    ('Kalsium laktat',     ARRAY['kalsium laktat', 'calcium lactate'],                  'Mineral', NULL, 'not_htn', FALSE, NULL, NULL, NULL)
ON CONFLICT (drug_name) DO UPDATE
    SET aliases        = EXCLUDED.aliases,
        drug_class     = EXCLUDED.drug_class,
        ladder_class   = EXCLUDED.ladder_class,
        htn_role       = EXCLUDED.htn_role,
        is_statin      = EXCLUDED.is_statin,
        start_mg_day   = EXCLUDED.start_mg_day,
        full_mg_day    = EXCLUDED.full_mg_day,
        stock_category = EXCLUDED.stock_category;

-- An alias must name exactly one medicine, or parse_obat would pick one arbitrarily.
DO $$
DECLARE
    v_dupes TEXT;
BEGIN
    SELECT string_agg(alias, ', ' ORDER BY alias) INTO v_dupes
    FROM (
        SELECT a.alias
        FROM medicines m, unnest(m.aliases) AS a(alias)
        GROUP BY a.alias
        HAVING count(DISTINCT m.drug_name) > 1
    ) d;
    IF v_dupes IS NOT NULL THEN
        RAISE EXCEPTION 'medicines aliases name more than one medicine: %', v_dupes;
    END IF;
END $$;

-- protocol_drugs.drug_name references medicines (AD-23).
DO $$
DECLARE
    v_missing  TEXT;
    v_mismatch TEXT;
BEGIN
    SELECT string_agg(DISTINCT d.drug_name, ', ') INTO v_missing
    FROM protocol_drugs d
    LEFT JOIN medicines m ON m.drug_name = d.drug_name
    WHERE m.drug_name IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'protocol_drugs.drug_name not in medicines: %', v_missing;
    END IF;

    SELECT string_agg(DISTINCT d.drug_name || ' (' || d.drug_category || ' vs ' || COALESCE(m.stock_category, 'NULL') || ')', ', ')
    INTO v_mismatch
    FROM protocol_drugs d
    JOIN medicines m ON m.drug_name = d.drug_name
    WHERE d.drug_category IS DISTINCT FROM m.stock_category;
    IF v_mismatch IS NOT NULL THEN
        RAISE WARNING 'protocol_drugs.drug_category differs from medicines.stock_category: %', v_mismatch;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'protocol_drugs_drug_name_fkey'
          AND conrelid = 'heart360tk_schema.protocol_drugs'::regclass
    ) THEN
        ALTER TABLE protocol_drugs
            ADD CONSTRAINT protocol_drugs_drug_name_fkey
            FOREIGN KEY (drug_name) REFERENCES medicines (drug_name)
            ON UPDATE CASCADE ON DELETE RESTRICT;
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- htn_ladder_steps (CR-1)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS htn_ladder_steps (
    step_no    INTEGER NOT NULL,
    ccb_level  INTEGER NOT NULL,
    raas_level INTEGER NOT NULL,
    thz_level  INTEGER NOT NULL,
    label      TEXT    NOT NULL,
    PRIMARY KEY (ccb_level, raas_level, thz_level),
    CONSTRAINT htn_ladder_steps_step_no_check CHECK (step_no BETWEEN 1 AND 6),
    CONSTRAINT htn_ladder_steps_level_check
        CHECK (ccb_level BETWEEN 0 AND 2 AND raas_level BETWEEN 0 AND 2 AND thz_level BETWEEN 0 AND 2)
);

INSERT INTO htn_ladder_steps (step_no, ccb_level, raas_level, thz_level, label) VALUES
    (1, 1, 0, 0, '1 medicine, starting dose'),
    (2, 2, 0, 0, '1 medicine, full dose'),
    (3, 2, 1, 0, '2 medicines, one at full dose'),
    (4, 2, 2, 0, '2 medicines, both at full dose'),
    (5, 2, 2, 1, '3 medicines, third at starting dose'),
    (6, 2, 2, 2, '3 medicines, all at full dose')
ON CONFLICT (ccb_level, raas_level, thz_level) DO UPDATE
    SET step_no = EXCLUDED.step_no,
        label   = EXCLUDED.label;

-- ----------------------------------------------------------------------------
-- prescriptions and prescription_lines (AD-24)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prescriptions (
    encounter_id BIGINT PRIMARY KEY REFERENCES encounters (id) ON DELETE CASCADE,
    obat_raw     TEXT NOT NULL,
    source       TEXT NOT NULL DEFAULT 'demo'
);

CREATE TABLE IF NOT EXISTS prescription_lines (
    encounter_id     BIGINT  NOT NULL REFERENCES prescriptions (encounter_id) ON DELETE CASCADE ON UPDATE CASCADE,
    line_no          INTEGER NOT NULL,
    raw_line         TEXT    NOT NULL,
    parsed_name      TEXT    NULL,
    drug_name        TEXT    NULL REFERENCES medicines (drug_name) ON UPDATE CASCADE,
    strength_mg      NUMERIC NULL,
    doses_per_day    NUMERIC NULL,
    tablets_per_dose NUMERIC NULL,
    daily_mg         NUMERIC NULL,
    parse_status     TEXT    NOT NULL,
    PRIMARY KEY (encounter_id, line_no),
    CONSTRAINT prescription_lines_parse_status_check
        CHECK (parse_status IN ('ok', 'unknown_drug', 'unparsed')),
    CONSTRAINT prescription_lines_ok_has_drug
        CHECK ((parse_status = 'ok') = (drug_name IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_prescription_lines_drug_name ON prescription_lines (drug_name);

-- Splits an Obat cell into numbered lines and parses each one (CLINICAL-RULES section 3).
-- The name resolves through medicines.aliases; a parsed line with no match is
-- unknown_drug with its numbers kept; a line the grammar rejects is unparsed.
CREATE OR REPLACE FUNCTION parse_obat(p_obat text)
RETURNS TABLE (
    line_no          integer,
    raw_line         text,
    parsed_name      text,
    drug_name        text,
    strength_mg      numeric,
    doses_per_day    numeric,
    tablets_per_dose numeric,
    daily_mg         numeric,
    parse_status     text
)
LANGUAGE sql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
    WITH pieces AS (
        SELECT
            row_number() OVER (ORDER BY s.ord)::integer AS line_no,
            s.piece AS raw_line
        FROM regexp_split_to_table(COALESCE(p_obat, ''), '\s*(;|\||\n)\s*') WITH ORDINALITY AS s(piece, ord)
        WHERE btrim(s.piece) <> ''
    ),
    matched AS (
        SELECT
            p.line_no,
            p.raw_line,
            regexp_match(
                p.raw_line,
                '^\s*([a-z][a-z .-]*?)\s+([0-9]+(?:[.,][0-9]+)?)\s*mg\s*-\s*([0-9]+)\s*x\s*([0-9]+(?:[.,][0-9]+)?|½|1/2)\s*(?:tablet|tab|kaplet|kapsul|capsule)?\s*(?:sehari)?\s*$',
                'i'
            ) AS m
        FROM pieces p
    ),
    numbers AS (
        SELECT
            x.line_no,
            x.raw_line,
            regexp_replace(lower(btrim(x.m[1])), '\s+', ' ', 'g') AS parsed_name,
            replace(x.m[2], ',', '.')::numeric AS strength_mg,
            x.m[3]::numeric AS doses_per_day,
            CASE WHEN x.m[4] IN ('½', '1/2') THEN 0.5 ELSE replace(x.m[4], ',', '.')::numeric END AS tablets_per_dose,
            x.m IS NOT NULL AS parsed
        FROM matched x
    )
    SELECT
        n.line_no,
        n.raw_line,
        n.parsed_name,
        med.drug_name,
        n.strength_mg,
        n.doses_per_day,
        n.tablets_per_dose,
        n.strength_mg * n.doses_per_day * n.tablets_per_dose AS daily_mg,
        CASE
            WHEN NOT n.parsed THEN 'unparsed'
            WHEN med.drug_name IS NULL THEN 'unknown_drug'
            ELSE 'ok'
        END AS parse_status
    FROM numbers n
    LEFT JOIN LATERAL (
        SELECT md.drug_name
        FROM medicines md
        WHERE n.parsed_name = ANY (md.aliases)
        ORDER BY md.drug_name
        LIMIT 1
    ) med ON n.parsed
    ORDER BY n.line_no;
$$;

-- Statement-level with transition tables: a seed inserting 25k cells parses
-- them in one set-based INSERT. A row-level trigger keeps the plans (and FK
-- check plans) made while the tables were empty, so a bulk load turns quadratic.
-- PostgreSQL allows neither a column list nor two events on a trigger with
-- transition tables, so every UPDATE of prescriptions re-parses its rows.
CREATE OR REPLACE FUNCTION prescriptions_parse_trigger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = heart360tk_schema, pg_temp
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        DELETE FROM prescription_lines l
        USING new_rows n
        WHERE l.encounter_id = n.encounter_id;
    END IF;
    INSERT INTO prescription_lines (
        encounter_id, line_no, raw_line, parsed_name, drug_name,
        strength_mg, doses_per_day, tablets_per_dose, daily_mg, parse_status
    )
    SELECT
        n.encounter_id, p.line_no, p.raw_line, p.parsed_name, p.drug_name,
        p.strength_mg, p.doses_per_day, p.tablets_per_dose, p.daily_mg, p.parse_status
    FROM new_rows n
    CROSS JOIN LATERAL parse_obat(n.obat_raw) p;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_prescriptions_parse_insert
    AFTER INSERT ON prescriptions
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION prescriptions_parse_trigger();

CREATE OR REPLACE TRIGGER trg_prescriptions_parse_update
    AFTER UPDATE ON prescriptions
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION prescriptions_parse_trigger();

-- ----------------------------------------------------------------------------
-- visit_step: the only classifier (AD-25, CR-1)
-- ----------------------------------------------------------------------------
-- One row per encounter. The first six columns are the spine contract.
--   bucket       'Step 1' .. 'Step 6' | 'Other Protocol' | 'Non-Protocol' | 'Unrecognized'
--   step_no      1-6 for a Step bucket, else NULL
--   reason       on_ladder | off_ladder | two_drugs_one_class | below_start_dose
--                | non_protocol_drug | unreadable | no_htn_medicine | no_prescription
--   n_htn_drugs  distinct protocol + non-protocol drugs (0 without a prescription)
--   dose_units   sum over HTN drugs of daily_mg / full_mg_day (1.0 when full_mg_day is NULL)
--   bucket_order 1-6 steps, 7 Other Protocol, 8 Non-Protocol, 9 Unrecognized
--   on_statin    a line's drug is_statin; NULL when the encounter has no prescriptions row
--   *_level      class level used for the ladder: 0 absent, 1 start, 2 full,
--                -1 below start, -2 two drugs in the class
CREATE OR REPLACE VIEW visit_step AS
SELECT
    e.id                                        AS encounter_id,
    CASE
        WHEN r.reason IN ('no_prescription', 'unreadable', 'no_htn_medicine') THEN 'Unrecognized'
        WHEN r.reason = 'non_protocol_drug' THEN 'Non-Protocol'
        WHEN r.reason = 'on_ladder' THEN 'Step ' || s.step_no
        ELSE 'Other Protocol'
    END                                         AS bucket,
    CASE WHEN r.reason = 'on_ladder' THEN s.step_no END AS step_no,
    r.reason,
    COALESCE(a.n_htn_drugs, 0)::integer         AS n_htn_drugs,
    COALESCE(a.dose_units, 0)::numeric          AS dose_units,
    CASE
        WHEN r.reason = 'on_ladder' THEN s.step_no
        WHEN r.reason = 'non_protocol_drug' THEN 8
        WHEN r.reason IN ('no_prescription', 'unreadable', 'no_htn_medicine') THEN 9
        ELSE 7
    END                                         AS bucket_order,
    e.patient_id,
    e.encounter_date,
    e.org_unit_id,
    (p.encounter_id IS NOT NULL)                AS has_prescription,
    CASE WHEN p.encounter_id IS NOT NULL THEN COALESCE(a.any_statin, FALSE) END AS on_statin,
    lv.ccb_level,
    lv.raas_level,
    lv.thz_level
FROM encounters e
LEFT JOIN prescriptions p
       ON p.encounter_id = e.id
LEFT JOIN LATERAL (
    SELECT
        bool_or(d.htn_role = 'non_protocol')                                    AS any_non_protocol,
        bool_or(d.unreadable)                                                   AS any_unreadable,
        bool_or(d.htn_role = 'protocol')                                        AS any_protocol,
        bool_or(d.is_statin)                                                    AS any_statin,
        count(*) FILTER (WHERE d.htn_role IN ('protocol', 'non_protocol'))      AS n_htn_drugs,
        sum(CASE WHEN d.full_mg_day > 0 THEN d.daily_mg / d.full_mg_day ELSE 1.0 END)
            FILTER (WHERE d.htn_role IN ('protocol', 'non_protocol'))           AS dose_units,
        count(*)          FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'CCB')      AS ccb_n,
        sum(d.daily_mg)   FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'CCB')      AS ccb_mg,
        max(d.start_mg_day) FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'CCB')    AS ccb_start,
        max(d.full_mg_day)  FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'CCB')    AS ccb_full,
        count(*)          FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'RAAS')     AS raas_n,
        sum(d.daily_mg)   FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'RAAS')     AS raas_mg,
        max(d.start_mg_day) FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'RAAS')   AS raas_start,
        max(d.full_mg_day)  FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'RAAS')   AS raas_full,
        count(*)          FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'THIAZIDE') AS thz_n,
        sum(d.daily_mg)   FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'THIAZIDE') AS thz_mg,
        max(d.start_mg_day) FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'THIAZIDE') AS thz_start,
        max(d.full_mg_day)  FILTER (WHERE d.htn_role = 'protocol' AND d.ladder_class = 'THIAZIDE') AS thz_full
    FROM (
        -- One row per drug: lines of the same drug are summed first (A67).
        -- Unparsed and unknown lines share the drug_name NULL row.
        SELECT
            m.htn_role,
            m.ladder_class,
            m.is_statin,
            m.start_mg_day,
            m.full_mg_day,
            bool_or(l.parse_status <> 'ok') AS unreadable,
            sum(l.daily_mg)                 AS daily_mg
        FROM prescription_lines l
        LEFT JOIN medicines m ON m.drug_name = l.drug_name
        WHERE l.encounter_id = p.encounter_id
        GROUP BY l.drug_name, m.htn_role, m.ladder_class, m.is_statin, m.start_mg_day, m.full_mg_day
    ) d
) a ON p.encounter_id IS NOT NULL
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN COALESCE(a.ccb_n, 0) = 0 THEN 0 WHEN a.ccb_n > 1 THEN -2
             WHEN a.ccb_mg >= a.ccb_full THEN 2 WHEN a.ccb_mg >= a.ccb_start THEN 1 ELSE -1 END AS ccb_level,
        CASE WHEN COALESCE(a.raas_n, 0) = 0 THEN 0 WHEN a.raas_n > 1 THEN -2
             WHEN a.raas_mg >= a.raas_full THEN 2 WHEN a.raas_mg >= a.raas_start THEN 1 ELSE -1 END AS raas_level,
        CASE WHEN COALESCE(a.thz_n, 0) = 0 THEN 0 WHEN a.thz_n > 1 THEN -2
             WHEN a.thz_mg >= a.thz_full THEN 2 WHEN a.thz_mg >= a.thz_start THEN 1 ELSE -1 END AS thz_level
) lv
LEFT JOIN htn_ladder_steps s
       ON s.ccb_level = lv.ccb_level
      AND s.raas_level = lv.raas_level
      AND s.thz_level = lv.thz_level
CROSS JOIN LATERAL (
    -- CR-1 bucket rules, first match wins.
    SELECT CASE
        WHEN p.encounter_id IS NULL THEN 'no_prescription'
        WHEN a.any_non_protocol THEN 'non_protocol_drug'
        WHEN a.any_unreadable THEN 'unreadable'
        WHEN NOT COALESCE(a.any_protocol, FALSE) THEN 'no_htn_medicine'
        WHEN -2 IN (lv.ccb_level, lv.raas_level, lv.thz_level) THEN 'two_drugs_one_class'
        WHEN -1 IN (lv.ccb_level, lv.raas_level, lv.thz_level) THEN 'below_start_dose'
        WHEN s.step_no IS NOT NULL THEN 'on_ladder'
        ELSE 'off_ladder'
    END AS reason
) r;

CREATE OR REPLACE FUNCTION classify_visit_step(p_encounter_id bigint)
RETURNS TABLE (
    encounter_id bigint,
    bucket       text,
    step_no      integer,
    reason       text,
    n_htn_drugs  integer,
    dose_units   numeric
)
LANGUAGE sql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
    SELECT v.encounter_id, v.bucket, v.step_no, v.reason, v.n_htn_drugs, v.dose_units
    FROM visit_step v
    WHERE v.encounter_id = p_encounter_id;
$$;

-- ----------------------------------------------------------------------------
-- patient_cvd_history (CR-5)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS patient_cvd_history (
    patient_id BIGINT NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    event_type TEXT   NOT NULL,
    event_date DATE   NOT NULL,
    source     TEXT   NOT NULL DEFAULT 'demo',
    PRIMARY KEY (patient_id, event_type, event_date),
    CONSTRAINT patient_cvd_history_event_type_check CHECK (event_type IN ('MI', 'STROKE'))
);

-- Re-parse stored cells so a re-run picks up catalogue and parser changes.
UPDATE prescriptions SET obat_raw = obat_raw;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, grant matrix). Invoker helpers: EXECUTE to heart360tk_reader only.
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE medicines, htn_ladder_steps, prescriptions, prescription_lines,
                    patient_cvd_history, visit_step FROM PUBLIC;
REVOKE ALL ON FUNCTION parse_obat(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION classify_visit_step(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION prescriptions_parse_trigger() FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'heart360tk_cached']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format(
                'GRANT SELECT ON TABLE heart360tk_schema.medicines, heart360tk_schema.htn_ladder_steps, '
                'heart360tk_schema.prescriptions, heart360tk_schema.prescription_lines, '
                'heart360tk_schema.patient_cvd_history, heart360tk_schema.visit_step TO %I',
                v_role
            );
        END IF;
    END LOOP;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_schema.parse_obat(text) TO heart360tk_reader';
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_schema.classify_visit_step(bigint) TO heart360tk_reader';
    END IF;
END $$;

COMMIT;
