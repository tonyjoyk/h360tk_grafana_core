-- Invented patients only. Ids 910001-910018. Re-running deletes that range first.
-- C0 is the latest registration quarter whose follow-up quarter has ended.

CREATE TEMP TABLE IF NOT EXISTS cohort_fixture_org (
    role text PRIMARY KEY,
    org_unit_id integer NOT NULL
);
TRUNCATE cohort_fixture_org;

DO $seed$
DECLARE
    v_facility integer;
    v_district integer;
    v_empty integer;
    c0 timestamp;
    c1 timestamp;
    open_q timestamp;
    w0_start timestamp;
    w1_start timestamp;
    w1_end timestamp;
    recent timestamp;
    enc bigint;
BEGIN
    v_facility := upsert_org_unit_chain(
        ARRAY['Demo Region', 'Cohort Sample District', 'Cohort Sample Facility'],
        ARRAY[1, 2, 3]
    );
    SELECT parent_id INTO v_district FROM org_units WHERE id = v_facility;
    v_empty := upsert_org_unit('Cohort Empty Facility', 3, v_district);

    INSERT INTO cohort_fixture_org (role, org_unit_id) VALUES
        ('facility', v_facility),
        ('district', v_district),
        ('empty', v_empty);

    c0 := date_trunc('quarter', CURRENT_TIMESTAMP) - interval '6 months';
    c1 := c0 - interval '3 months';
    open_q := date_trunc('quarter', CURRENT_TIMESTAMP);
    w0_start := c0 + interval '3 months';
    w1_start := c1 + interval '3 months';
    w1_end := c1 + interval '6 months';
    recent := date_trunc('month', CURRENT_TIMESTAMP) + interval '2 days';

    DELETE FROM blood_sugars
    WHERE encounter_id IN (SELECT id FROM encounters WHERE patient_id BETWEEN 910001 AND 910018);
    DELETE FROM blood_pressures
    WHERE encounter_id IN (SELECT id FROM encounters WHERE patient_id BETWEEN 910001 AND 910018);
    DELETE FROM encounters WHERE patient_id BETWEEN 910001 AND 910018;
    DELETE FROM patients WHERE patient_id BETWEEN 910001 AND 910018;

    INSERT INTO patients (patient_id, patient_name, patient_status, registration_date, org_unit_id, death_date) VALUES
        (910001, 'Fixture Cohort 01', 'ALIVE', c0 + interval '10 days', v_facility, NULL),
        (910002, 'Fixture Cohort 02', 'ALIVE', c0 + interval '11 days', v_facility, NULL),
        (910003, 'Fixture Cohort 03', 'ALIVE', c0 + interval '12 days', v_facility, NULL),
        (910004, 'Fixture Cohort 04', 'ALIVE', c0 + interval '13 days', v_facility, NULL),
        (910005, 'Fixture Cohort 05', 'ALIVE', c0 + interval '14 days', v_facility, NULL),
        (910006, 'Fixture Cohort 06', 'ALIVE', c0 + interval '15 days', v_facility, NULL),
        (910007, 'Fixture Cohort 07', 'ALIVE', c0 + interval '16 days', v_facility, NULL),
        (910008, 'Fixture Cohort 08', 'ALIVE', c0 + interval '17 days', v_facility, NULL),
        (910009, 'Fixture Cohort 09', 'ALIVE', c0 + interval '18 days', v_facility, NULL),
        (910010, 'Fixture Cohort 10', 'ALIVE', c1 + interval '10 days', v_facility, NULL),
        (910011, 'Fixture Cohort 11', 'ALIVE', c1 + interval '11 days', v_facility, NULL),
        (910012, 'Fixture Cohort 12', 'ALIVE', c1 + interval '12 days', v_facility, NULL),
        (910013, 'Fixture Cohort 13', 'ALIVE', c0 + interval '5 days', v_district, NULL),
        (910014, 'Fixture Cohort 14', 'ALIVE', open_q + interval '5 days', v_facility, NULL),
        (910015, 'Fixture Cohort 15', 'ALIVE', c0 + interval '6 days', v_facility, NULL),
        (910016, 'Fixture Cohort 16', 'DEAD', c0 + interval '7 days', v_facility, (c0 + interval '4 months')::date),
        (910017, 'Fixture Cohort 17', 'ALIVE', c0 + interval '2 months', v_facility, NULL),
        (910018, 'Fixture Cohort 18', 'ALIVE', c0 + interval '8 days', v_facility, NULL);

    INSERT INTO patient_diagnoses (patient_id, diagnosis_code)
    SELECT patient_id, 'I10'
    FROM patients
    WHERE patient_id BETWEEN 910001 AND 910018
      AND patient_id <> 910015;
    INSERT INTO patient_diagnoses (patient_id, diagnosis_code) VALUES (910015, 'E11');

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910001, w0_start + interval '10 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 139, 89 FROM encounters WHERE patient_id = 910001;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910002, w0_start, v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910002;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910003, w0_start + interval '20 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 140, 80 FROM encounters WHERE patient_id = 910003;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910004, w0_start + interval '21 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 90 FROM encounters WHERE patient_id = 910004;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910006, w0_start - interval '1 day', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910006;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910007, w0_start + interval '15 days', v_facility);

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910008, w0_start + interval '16 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, NULL, 80 FROM encounters WHERE patient_id = 910008;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910009, w0_start + interval '5 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 70 FROM encounters
    WHERE patient_id = 910009 AND encounter_date = w0_start + interval '5 days';
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910009, w0_start + interval '40 days', v_facility);

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910010, w1_start + interval '10 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 130, 80 FROM encounters WHERE patient_id = 910010;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910011, w1_start + interval '5 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters
    WHERE patient_id = 910011 AND encounter_date = w1_start + interval '5 days';
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910011, w1_end - interval '1 day', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 150, 95 FROM encounters
    WHERE patient_id = 910011 AND encounter_date = w1_end - interval '1 day';

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910013, w0_start + interval '12 days', v_district);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910013;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910014, open_q + interval '3 months' + interval '10 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 110, 70 FROM encounters WHERE patient_id = 910014;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910015, w0_start + interval '12 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910015;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910016, w0_start + interval '12 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910016;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910017, w0_start + interval '12 days', v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910017;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910018, w0_start + interval '18 days', v_facility);
    SELECT id INTO enc FROM encounters WHERE patient_id = 910018;
    INSERT INTO blood_sugars (encounter_id, blood_sugar_value) VALUES (enc, 8.0);

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id) VALUES
        (910001, recent, v_facility),
        (910002, recent, v_facility),
        (910003, recent, v_facility),
        (910004, recent, v_facility),
        (910010, recent, v_facility),
        (910017, recent, v_facility);
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 120, 80 FROM encounters WHERE patient_id = 910001 AND encounter_date = recent;
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 118, 76 FROM encounters WHERE patient_id = 910002 AND encounter_date = recent;
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 150, 92 FROM encounters WHERE patient_id = 910003 AND encounter_date = recent;
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 145, 88 FROM encounters WHERE patient_id = 910004 AND encounter_date = recent;
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 128, 82 FROM encounters WHERE patient_id = 910010 AND encounter_date = recent;
    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT id, 122, 78 FROM encounters WHERE patient_id = 910017 AND encounter_date = recent;
END
$seed$;
