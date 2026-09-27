-- Demo cohort for the Drug Stock board.
-- Docker runs this file after 01_heart360_tables.sql on a fresh data volume.
-- Re-running replaces stock and registered counts for the Demo facilities only.
--
-- The Reporting Month picker is the current month and the five months before it.
-- Each of those months carries the same picture:
--
--   Demo Riverside Clinic  N=100
--     Amlodipine 5 mg 100, 10 mg 50. CCB patient-days = 200 / (100 * 1.4) = 1.428571
--     Telmisartan 40 mg 2775, 80 mg 0. ARB patient-days = 75
--     Chlorthalidone 12.5 mg 540, 25 mg 0. Diuretic patient-days = 90
--   Demo Hillside PHC      N=80
--     Amlodipine 5 mg 4000, 10 mg 3040. CCB patient-days = 90
--     Telmisartan 40 mg 1332, 80 mg 0. ARB patient-days = 45
--     Chlorthalidone 12.5 mg 48, 25 mg 0. Diuretic patient-days = 10
--   Demo Market UPHC       N=40   every strength is an explicit 0. Patient-days = 0
--   Demo Blank Ward        N=60
--     Amlodipine 5 mg 140, 10 mg 140. CCB patient-days = 5
--     Both telmisartan strengths are blank. ARB patient-days stays null
--     Chlorthalidone 12.5 mg 18, 25 mg 9. Diuretic patient-days = 10
--   Demo Silent Camp       N=25   no submission. The board shows ?
--
-- Registered N is alive patients with diagnosis I10, all registered on the
-- first day of the oldest picker month, so every picker month has that N.
-- The reporting table is filled with the same counts. The hourly refresh
-- rebuilds that table from those patients and keeps the same N.

BEGIN;

SET search_path TO heart360tk_schema, heart360tk_reporting;

DO $seed$
DECLARE
    v_country   varchar(64);
    v_programme varchar(64);
    v_state     integer;
    v_north     integer;
    v_south     integer;
    v_riverside integer;
    v_hillside  integer;
    v_market    integer;
    v_blank     integer;
    v_silent    integer;
    v_anchor    timestamp;
    v_month     date;
    v_offset    integer;
    v_id_lo     bigint := 910000001;
    v_id_hi     bigint := 910000305;
BEGIN
    SELECT s.country_code, s.programme_code
      INTO v_country, v_programme
      FROM deploy_setting s
     WHERE s.setting_name = 'active_programme';

    IF v_country IS DISTINCT FROM 'India' OR v_programme IS DISTINCT FROM 'IHCI' THEN
        RAISE EXCEPTION 'drug stock demo seed expects India/IHCI, found %/%', v_country, v_programme;
    END IF;

    v_state := upsert_org_unit('Demo State', 1, NULL);
    v_north := upsert_org_unit('Demo North District', 2, v_state);
    v_south := upsert_org_unit('Demo South District', 2, v_state);
    v_riverside := upsert_org_unit('Demo Riverside Clinic', 3, v_north);
    v_blank := upsert_org_unit('Demo Blank Ward', 3, v_north);
    v_silent := upsert_org_unit('Demo Silent Camp', 3, v_north);
    v_hillside := upsert_org_unit('Demo Hillside PHC', 3, v_south);
    v_market := upsert_org_unit('Demo Market UPHC', 3, v_south);

    IF v_state IS NULL OR v_north IS NULL OR v_south IS NULL
       OR v_riverside IS NULL OR v_blank IS NULL OR v_silent IS NULL
       OR v_hillside IS NULL OR v_market IS NULL THEN
        RAISE EXCEPTION 'drug stock demo seed could not create the Demo org tree';
    END IF;

    INSERT INTO drug_stock_form_cohort (org_unit_id)
    VALUES (v_riverside), (v_blank), (v_silent), (v_hillside), (v_market)
    ON CONFLICT (org_unit_id) DO NOTHING;

    IF to_regclass('heart360tk_schema.call_results') IS NOT NULL THEN
        DELETE FROM call_results
        WHERE patient_id BETWEEN v_id_lo AND v_id_hi;
    END IF;
    IF to_regclass('heart360tk_schema.scheduled_visits') IS NOT NULL THEN
        DELETE FROM scheduled_visits
        WHERE patient_id BETWEEN v_id_lo AND v_id_hi;
    END IF;
    IF to_regclass('heart360tk_schema.encounters') IS NOT NULL THEN
        DELETE FROM encounters
        WHERE patient_id BETWEEN v_id_lo AND v_id_hi;
    END IF;
    IF to_regclass('heart360tk_schema.patient_diagnoses') IS NOT NULL THEN
        DELETE FROM patient_diagnoses
        WHERE patient_id BETWEEN v_id_lo AND v_id_hi;
    END IF;
    IF to_regclass('heart360tk_schema.patients') IS NOT NULL THEN
        DELETE FROM patients
        WHERE patient_id BETWEEN v_id_lo AND v_id_hi;

        v_anchor := date_trunc('month', current_date) - interval '5 months';

        INSERT INTO patients (
            patient_id, patient_name, patient_status, registration_date, org_unit_id
        )
        SELECT
            f.id_start + g.n - 1,
            'Demo Patient',
            'ALIVE',
            v_anchor,
            f.org_unit_id
        FROM (
            VALUES
                (v_riverside, 910000001::bigint, 100),
                (v_hillside,  910000101::bigint, 80),
                (v_market,    910000181::bigint, 40),
                (v_blank,     910000221::bigint, 60),
                (v_silent,    910000281::bigint, 25)
        ) AS f(org_unit_id, id_start, patients_n)
        CROSS JOIN LATERAL generate_series(1, f.patients_n) AS g(n);

        INSERT INTO patient_diagnoses (patient_id, diagnosis_code)
        SELECT p.patient_id, 'I10'
        FROM patients p
        WHERE p.patient_id BETWEEN v_id_lo AND v_id_hi;
    END IF;

    DELETE FROM drug_stock_submission
    WHERE org_unit_id IN (v_riverside, v_blank, v_silent, v_hillside, v_market);

    DELETE FROM heart360tk_reporting.heart360_patients_registered
    WHERE org_unit_id IN (v_riverside, v_blank, v_silent, v_hillside, v_market)
      AND ref_month >= (date_trunc('month', current_date) - interval '5 months')::date
      AND ref_month < (date_trunc('month', current_date) + interval '1 month')::date;

    FOR v_offset IN 0..5 LOOP
        v_month := (date_trunc('month', current_date) - make_interval(months => v_offset))::date;

        INSERT INTO heart360tk_reporting.heart360_patients_registered (
            ref_month, org_unit_id, cumulative_number_of_patients, nb_new_patients
        )
        VALUES
            (v_month, v_riverside, 100, 100),
            (v_month, v_hillside, 80, 80),
            (v_month, v_market, 40, 40),
            (v_month, v_blank, 60, 60),
            (v_month, v_silent, 25, 25);

        INSERT INTO drug_stock_submission (
            org_unit_id, reporting_month, rxnorm_code,
            country_code, programme_code, in_stock, submitted_at, pulled_at
        )
        SELECT
            s.org_unit_id,
            v_month,
            s.rxnorm_code,
            v_country,
            v_programme,
            s.in_stock,
            transaction_timestamp(),
            transaction_timestamp()
        FROM (
            VALUES
                (v_riverside, '329528', 100::numeric),
                (v_riverside, '329526', 50::numeric),
                (v_riverside, '316764', 2775::numeric),
                (v_riverside, '316765', 0::numeric),
                (v_riverside, '331132', 540::numeric),
                (v_riverside, '197499', 0::numeric),
                (v_hillside, '329528', 4000::numeric),
                (v_hillside, '329526', 3040::numeric),
                (v_hillside, '316764', 1332::numeric),
                (v_hillside, '316765', 0::numeric),
                (v_hillside, '331132', 48::numeric),
                (v_hillside, '197499', 0::numeric),
                (v_market, '329528', 0::numeric),
                (v_market, '329526', 0::numeric),
                (v_market, '316764', 0::numeric),
                (v_market, '316765', 0::numeric),
                (v_market, '331132', 0::numeric),
                (v_market, '197499', 0::numeric),
                (v_blank, '329528', 140::numeric),
                (v_blank, '329526', 140::numeric),
                (v_blank, '316764', NULL::numeric),
                (v_blank, '316765', NULL::numeric),
                (v_blank, '331132', 18::numeric),
                (v_blank, '197499', 9::numeric)
        ) AS s(org_unit_id, rxnorm_code, in_stock);
    END LOOP;
END
$seed$;

COMMIT;
