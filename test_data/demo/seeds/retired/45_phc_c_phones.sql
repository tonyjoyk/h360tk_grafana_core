-- Seed 45: more PHC-C new patients without a phone (story 4.4 follow-up, AD-34, A56).
-- Seed 10 added 220 phoneless new patients, but PHC-C's usable-phone share for
-- the 2026-10 new-patient cohort stayed near 65% (target 40-48%,
-- CLINICAL-RULES section 7). This seed adds enough phoneless I10 new patients to
-- bring it to about 44%, and gives about 73% of them a second visit so the
-- facility's new-patient loss sits near 27% (band 24-30%).
--
-- Mirrors seed 10's PHC-C block: ids continue at 900000221, same name, gender,
-- birth date, sub-facility pick, first visit 2026-08-01 09:00 with BP 124/78
-- and second visit 2026-09-25 14:00 with BP 124/78. The patients are 30 years
-- old with no diabetes, so they are not statin-eligible, and their readings are
-- controlled and outside 135-144, so stepping up and the bunching score do not
-- move. It runs after seeds 20 and 30 (so a fresh install and an upgraded one
-- end the same) and writes one prescription per new visit with seed 20's
-- Step 1-2 regimen text.
--
-- The count is worked out from the database at run time, so it is
-- deterministic for a given cohort. Every choice is md5(id || ':' || salt).
-- Insert only; a second run hits the marker and stops.
SET ROLE heart360tk;
SET search_path TO heart360tk_schema, public;

CREATE TABLE IF NOT EXISTS demo_seed_marker (
    seed       text PRIMARY KEY,
    anchor     date NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

DO $do$
DECLARE
    -- New-patient cohort of report_new_patients for 2026-10 (window end
    -- 2026-10-31): first visit from window_end - 179 to window_end - 90.
    c_from     constant date    := DATE '2026-05-05';
    c_to       constant date    := DATE '2026-08-02';
    c_phone    constant numeric := 0.44;  -- target usable-phone share
    c_loss     constant numeric := 0.27;  -- target new-patient loss
    c_first_id constant bigint  := 900000221;
    v_anchor   date;
    v_fac      integer;
    v_total    integer;
    v_usable   integer;
    v_lost     integer;
    v_add      integer;
    v_keep     integer;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '45_phc_c_phones') THEN
        RAISE NOTICE '45_phc_c_phones already applied';
        RETURN;
    END IF;

    SELECT COALESCE(
        (SELECT anchor FROM demo_seed_marker WHERE seed = '10_visits'),
        (SELECT MAX(encounter_date)::date FROM encounters),
        DATE '2026-10-13'
    ) INTO v_anchor;

    SELECT id INTO v_fac
    FROM org_units
    WHERE level = 3 AND name = 'PHC-C'
    ORDER BY id
    LIMIT 1;

    IF v_fac IS NULL THEN
        RAISE NOTICE '45_phc_c_phones: no PHC-C, nothing to add';
        INSERT INTO demo_seed_marker (seed, anchor, applied_at)
        VALUES ('45_phc_c_phones', v_anchor, clock_timestamp())
        ON CONFLICT DO NOTHING;
        RETURN;
    END IF;

    -- Same cohort, return and usable-phone rules as report_new_patients.
    SELECT count(*),
           count(*) FILTER (WHERE c.usable_phone),
           count(*) FILTER (WHERE NOT c.came_back)
      INTO v_total, v_usable, v_lost
    FROM (
        SELECT
            EXISTS (SELECT 1 FROM encounters e
                    WHERE e.patient_id = f.patient_id
                      AND e.encounter_date >  f.first_dt
                      AND e.encounter_date <= f.first_dt + INTERVAL '90 days') AS came_back,
            (length(regexp_replace(COALESCE(f.phone_number, ''), '[^0-9]', '', 'g')) >= 8
             AND NOT EXISTS (SELECT 1 FROM call_results cr
                             WHERE cr.patient_id = f.patient_id
                               AND cr.removed_reason = 'Wrong phone number')) AS usable_phone
        FROM (
            SELECT p.patient_id, p.phone_number, min(e.encounter_date) AS first_dt
            FROM patients p
            JOIN encounters e ON e.patient_id = p.patient_id
            WHERE p.patient_status IS DISTINCT FROM 'DEAD'
              AND p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
            GROUP BY p.patient_id, p.phone_number
        ) AS f
        WHERE f.first_dt::date BETWEEN c_from AND c_to
    ) AS c;

    -- usable / (total + add) = 0.44, capped so an odd cohort cannot add thousands.
    v_add := GREATEST(0, LEAST(600, ceil(v_usable / c_phone)::integer - v_total));
    -- Lost among the new ones so the facility loss lands near 27%.
    v_keep := GREATEST(0, LEAST(v_add, v_add - (round(c_loss * (v_total + v_add))::integer - v_lost)));

    RAISE NOTICE '45_phc_c_phones: cohort % usable % lost %; adding % phoneless, % with a second visit',
        v_total, v_usable, v_lost, v_add, v_keep;

    IF v_add > 0 THEN
        INSERT INTO patients (
            patient_id, patient_name, gender, phone_number, patient_status,
            registration_date, birth_date, death_date, org_unit_id
        )
        SELECT
            id.pid,
            'Demo ' || id.pid::text,
            CASE WHEN demo_seed_hash(id.pid::text || ':gender') % 2 = 0 THEN 'Female' ELSE 'Male' END,
            NULL,
            'ALIVE',
            TIMESTAMP '2026-08-01 09:00:00',
            DATE '1996-06-15',
            NULL,
            shc.id
        FROM generate_series(c_first_id, c_first_id + v_add - 1) AS id(pid)
        JOIN LATERAL (
            SELECT s.id
            FROM (
                SELECT c.id,
                       row_number() OVER (ORDER BY c.name) - 1 AS rn,
                       count(*) OVER () AS cnt
                FROM org_units c
                WHERE c.parent_id = v_fac
                  AND c.level = 4
            ) AS s
            WHERE s.rn = demo_seed_hash(id.pid::text || ':shc') % s.cnt
        ) AS shc ON true
        ON CONFLICT DO NOTHING;

        INSERT INTO patient_diagnoses (patient_id, diagnosis_code)
        SELECT id.pid, 'I10'
        FROM generate_series(c_first_id, c_first_id + v_add - 1) AS id(pid)
        JOIN patients p ON p.patient_id = id.pid AND p.patient_name = 'Demo ' || id.pid::text
        ON CONFLICT DO NOTHING;

        INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
        SELECT p.patient_id, TIMESTAMP '2026-08-01 09:00:00', p.org_unit_id
        FROM patients p
        WHERE p.patient_id BETWEEN c_first_id AND c_first_id + v_add - 1
          AND p.patient_name = 'Demo ' || p.patient_id::text
        ON CONFLICT DO NOTHING;

        -- Second visits for all but the lost ones, chosen by md5.
        INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
        SELECT ranked.patient_id, TIMESTAMP '2026-09-25 14:00:00', ranked.org_unit_id
        FROM (
            SELECT p.patient_id, p.org_unit_id,
                   row_number() OVER (ORDER BY md5(p.patient_id::text || ':loss')) AS rn
            FROM patients p
            WHERE p.patient_id BETWEEN c_first_id AND c_first_id + v_add - 1
              AND p.patient_name = 'Demo ' || p.patient_id::text
        ) AS ranked
        WHERE ranked.rn <= v_keep
        ON CONFLICT DO NOTHING;

        INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
        SELECT e.id, 124, 78
        FROM encounters e
        JOIN patients p ON p.patient_id = e.patient_id
        WHERE p.patient_id BETWEEN c_first_id AND c_first_id + v_add - 1
          AND p.patient_name = 'Demo ' || p.patient_id::text
          AND e.encounter_date IN (TIMESTAMP '2026-08-01 09:00:00', TIMESTAMP '2026-09-25 14:00:00')
        ON CONFLICT DO NOTHING;

        -- One prescription per new visit: Step 1 or Step 2, no step-up (all
        -- readings are controlled), no statin (not eligible).
        INSERT INTO prescriptions (encounter_id, obat_raw, source)
        SELECT e.id,
               CASE WHEN demo_seed_hash(p.patient_id::text || ':which') % 2 = 0
                    THEN 'Amlodipine 5 mg - 1 x 1 Tablet Sehari'
                    ELSE 'Amlodipine 10 mg - 1 x 1 Tablet Sehari'
               END,
               'demo'
        FROM encounters e
        JOIN patients p ON p.patient_id = e.patient_id
        WHERE p.patient_id BETWEEN c_first_id AND c_first_id + v_add - 1
          AND p.patient_name = 'Demo ' || p.patient_id::text
          AND e.encounter_date IN (TIMESTAMP '2026-08-01 09:00:00', TIMESTAMP '2026-09-25 14:00:00')
          AND NOT EXISTS (SELECT 1 FROM prescriptions pr WHERE pr.encounter_id = e.id)
        ON CONFLICT DO NOTHING;
    END IF;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('45_phc_c_phones', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '45_phc_c_phones applied, % patients', v_add;
END
$do$;
