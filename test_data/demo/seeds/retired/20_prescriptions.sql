-- Seed 20: one prescriptions row per encounter (story 4.5, AD-34).
-- The parse trigger fills prescription_lines. This file never writes those lines.
-- Start mix: 70% step 1-2, 12% step 3-4, 6% non-protocol, 4% other protocol,
-- 3% unreadable text, 5% no hypertension medicine.
-- An uncontrolled visit steps up at the facility rate (about 46%, PHC-E about 28%).
-- Statin lines: about 32% of eligible patients, PHC-F about 22%.
SET ROLE heart360tk;
SET search_path TO heart360tk_schema, public;

CREATE TABLE IF NOT EXISTS demo_seed_marker (
    seed       text PRIMARY KEY,
    anchor     date NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION demo_seed_hash(p_key text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT (
        (get_byte(decode(md5(p_key), 'hex'), 0)::bigint << 24)
      + (get_byte(decode(md5(p_key), 'hex'), 1)::bigint << 16)
      + (get_byte(decode(md5(p_key), 'hex'), 2)::bigint << 8)
      +  get_byte(decode(md5(p_key), 'hex'), 3)::bigint
    );
$fn$;

-- Regimen text for one visit. p_step_ups is how many step-ups have happened
-- for this patient up to and including this visit.
CREATE OR REPLACE FUNCTION demo_seed_obat(
    p_bucket text,
    p_start_step integer,
    p_step_ups integer,
    p_statin boolean
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT txt || CASE
        WHEN p_statin THEN '; Atorvastatin 20 mg - 1 x 1 Tablet Sehari'
        ELSE ''
    END
    FROM (
        SELECT CASE p_bucket
            WHEN 'unreadable' THEN 'Obat herbal 2 x sehari'
            WHEN 'nohtn' THEN
                CASE
                    WHEN p_step_ups <= 0 THEN 'Metformin 500 mg - 1 x 2 Tablet Sehari'
                    WHEN p_step_ups = 1 THEN 'Metformin 500 mg - 1 x 2 Tablet Sehari; Amlodipine 5 mg - 1 x 1 Tablet Sehari'
                    ELSE 'Metformin 500 mg - 1 x 2 Tablet Sehari; Amlodipine 10 mg - 1 x 1 Tablet Sehari'
                END
            WHEN 'nonproto' THEN
                CASE
                    WHEN p_step_ups <= 0 THEN 'Losartan 50 mg - 1 x 1 Tablet Sehari'
                    WHEN p_step_ups = 1 THEN 'Losartan 100 mg - 1 x 1 Tablet Sehari'
                    ELSE 'Losartan 100 mg - 1 x 1 Tablet Sehari; Amlodipine 5 mg - 1 x 1 Tablet Sehari'
                END
            WHEN 'other' THEN
                CASE
                    WHEN p_step_ups <= 0 THEN 'Lisinopril 10 mg - 1 x 1 Tablet Sehari'
                    WHEN p_step_ups = 1 THEN 'Lisinopril 20 mg - 1 x 1 Tablet Sehari'
                    ELSE 'Lisinopril 20 mg - 1 x 1 Tablet Sehari; Amlodipine 5 mg - 1 x 1 Tablet Sehari'
                END
            ELSE
                CASE least(6, GREATEST(p_start_step, 1) + GREATEST(p_step_ups, 0))
                    WHEN 1 THEN 'Amlodipine 5 mg - 1 x 1 Tablet Sehari'
                    WHEN 2 THEN 'Amlodipine 10 mg - 1 x 1 Tablet Sehari'
                    WHEN 3 THEN 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari'
                    WHEN 4 THEN 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari'
                    WHEN 5 THEN 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Chlorthalidone 12.5 mg - 1 x 1 Tablet Sehari'
                    ELSE 'Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Chlorthalidone 25 mg - 1 x 1 Tablet Sehari'
                END
        END AS txt
    ) AS built;
$fn$;

DO $do$
DECLARE
    v_anchor date;
    v_end    date;
    v_cut    date;
    v_n      integer;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '20_prescriptions') THEN
        RAISE NOTICE '20_prescriptions already applied';
        RETURN;
    END IF;

    SELECT COALESCE(
        (SELECT anchor FROM demo_seed_marker WHERE seed = '10_visits'),
        (SELECT MAX(encounter_date)::date FROM encounters),
        DATE '2026-10-13'
    ) INTO v_anchor;

    SELECT COALESCE(MAX(encounter_date)::date, v_anchor) INTO v_end FROM encounters;
    v_cut := v_end - 30;

    WITH fac AS (
        SELECT leaf.id AS org_unit_id, anc.facility_id, anc.facility_name
        FROM org_units leaf
        JOIN LATERAL (
            WITH RECURSIVE up AS (
                SELECT id, parent_id, level, name
                FROM org_units
                WHERE id = leaf.id
                UNION ALL
                SELECT o.id, o.parent_id, o.level, o.name
                FROM org_units o
                JOIN up ON up.parent_id = o.id
            )
            SELECT id AS facility_id, name AS facility_name
            FROM up
            WHERE level = 3
            LIMIT 1
        ) AS anc ON true
    ),
    people AS (
        SELECT DISTINCT e.patient_id, f.facility_id, f.facility_name
        FROM encounters e
        JOIN patients p ON p.patient_id = e.patient_id
        LEFT JOIN fac f ON f.org_unit_id = p.org_unit_id
    ),
    ranked AS (
        SELECT patient_id, facility_id, facility_name,
               row_number() OVER (
                   PARTITION BY facility_id
                   ORDER BY md5(patient_id::text || ':mix')
               ) AS rn,
               count(*) OVER (PARTITION BY facility_id) AS n
        FROM people
    ),
    cuts AS (
        SELECT patient_id, facility_id, facility_name, rn, n,
               round(0.70 * n)::integer AS c70,
               GREATEST(round(0.70 * n), round(0.82 * n))::integer AS c82,
               GREATEST(round(0.82 * n), round(0.88 * n))::integer AS c88,
               GREATEST(round(0.88 * n), round(0.92 * n))::integer AS c92,
               GREATEST(round(0.92 * n), round(0.95 * n))::integer AS c95
        FROM ranked
    ),
    starts AS (
        SELECT patient_id, facility_id, facility_name,
               CASE
                   WHEN rn <= c70 THEN 'step12'
                   WHEN rn <= c82 THEN 'step34'
                   WHEN rn <= c88 THEN 'nonproto'
                   WHEN rn <= c92 THEN 'other'
                   WHEN rn <= c95 THEN 'unreadable'
                   ELSE 'nohtn'
               END AS bucket,
               CASE
                   WHEN rn <= c70 AND demo_seed_hash(patient_id::text || ':which') % 2 = 0 THEN 1
                   WHEN rn <= c70 THEN 2
                   WHEN rn <= c82 AND demo_seed_hash(patient_id::text || ':which') % 2 = 0 THEN 3
                   WHEN rn <= c82 THEN 4
                   ELSE 1
               END AS start_step
        FROM cuts
    ),
    eligible AS (
        SELECT e.id, e.patient_id, s.facility_id, s.facility_name
        FROM encounters e
        JOIN blood_pressures bp ON bp.encounter_id = e.id
        JOIN starts s ON s.patient_id = e.patient_id
        WHERE (bp.systolic_bp >= 140 OR bp.diastolic_bp >= 90)
          AND e.encounter_date::date BETWEEN DATE '2026-08-03' AND DATE '2026-10-31'
          AND e.encounter_date::date <= v_cut
          AND s.bucket <> 'unreadable'
          AND EXISTS (
              SELECT 1
              FROM encounters prev
              WHERE prev.patient_id = e.patient_id
                AND (prev.encounter_date, prev.id) < (e.encounter_date, e.id)
          )
    ),
    chosen AS (
        SELECT id
        FROM (
            SELECT e.id,
                   row_number() OVER (
                       PARTITION BY e.facility_id
                       ORDER BY md5(e.id::text || ':stepup')
                   ) AS rn,
                   count(*) OVER (PARTITION BY e.facility_id) AS n,
                   CASE WHEN e.facility_name = 'PHC-E' THEN 0.28 ELSE 0.46 END AS rate
            FROM eligible e
        ) AS scored
        WHERE scored.rn <= round(scored.rate * scored.n)
    ),
    statin_people AS (
        SELECT p.patient_id, f.facility_id, f.facility_name
        FROM patients p
        LEFT JOIN fac f ON f.org_unit_id = p.org_unit_id
        WHERE p.patient_status = 'ALIVE'
          AND p.birth_date <= DATE '1986-10-31'
          AND (
              EXISTS (
                  SELECT 1 FROM patient_diagnoses d
                  WHERE d.patient_id = p.patient_id AND d.diagnosis_code = 'E11'
              )
              OR EXISTS (
                  SELECT 1 FROM patient_cvd_history h
                  WHERE h.patient_id = p.patient_id
                    AND h.event_date <= DATE '2026-10-31'
              )
          )
    ),
    on_statin AS (
        SELECT patient_id
        FROM (
            SELECT patient_id,
                   row_number() OVER (
                       PARTITION BY facility_id
                       ORDER BY md5(patient_id::text || ':statin')
                   ) AS rn,
                   count(*) OVER (PARTITION BY facility_id) AS n,
                   CASE WHEN facility_name = 'PHC-F' THEN 0.22 ELSE 0.32 END AS rate
            FROM statin_people
        ) AS scored
        WHERE rn <= round(rate * n)
    ),
    lined AS (
        SELECT e.id AS encounter_id,
               s.bucket,
               s.start_step,
               SUM(CASE WHEN c.id IS NOT NULL THEN 1 ELSE 0 END) OVER (
                   PARTITION BY e.patient_id
                   ORDER BY e.encounter_date, e.id
               )::integer AS step_ups,
               (os.patient_id IS NOT NULL) AS statin
        FROM encounters e
        JOIN starts s ON s.patient_id = e.patient_id
        LEFT JOIN chosen c ON c.id = e.id
        LEFT JOIN on_statin os ON os.patient_id = e.patient_id
        WHERE NOT EXISTS (
            SELECT 1 FROM prescriptions pr WHERE pr.encounter_id = e.id
        )
    )
    INSERT INTO prescriptions (encounter_id, obat_raw, source)
    SELECT encounter_id,
           demo_seed_obat(bucket, start_step, step_ups, statin),
           'demo'
    FROM lined
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_n = ROW_COUNT;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('20_prescriptions', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '20_prescriptions applied, % rows, data end % cutoff %', v_n, v_end, v_cut;
END
$do$;
