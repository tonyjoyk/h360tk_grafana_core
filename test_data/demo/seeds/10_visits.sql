-- Seed 10: visits, phones and CVD history (story 4.4, AD-34, A32, A55, A56).
-- Reporting month 2026-10. Data window ends 2026-10-13.
-- PHC-E is the high-control, high-bunching facility (135-139 vs 140-144).
-- PHC-D loses more new patients before a second visit. PHC-C adds 220 patients with no phone.
-- Every choice is md5(id || ':' || salt). Insert only; a second run hits the marker and stops.
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

-- Kind of a synthetic id. NULL means this seed did not mint the id.
CREATE OR REPLACE FUNCTION demo_seed_kind(p_id bigint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN p_id BETWEEN 920000001 AND 929999999 THEN 'call'
        WHEN p_id BETWEEN 900000001 AND 900000220 THEN 'new'
        WHEN p_id BETWEEN 910000001 AND 910599999
             AND (p_id - 910000000) % 100000 BETWEEN 1 AND 200 THEN 'established'
        WHEN p_id BETWEEN 910000001 AND 910599999
             AND (p_id - 910000000) % 100000 BETWEEN 201 AND 400 THEN 'new'
        ELSE NULL
    END;
$fn$;

-- 0 = PHC-A ... 5 = PHC-F. The phoneless block 900000001+ sits under PHC-C.
CREATE OR REPLACE FUNCTION demo_seed_slot(p_id bigint)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN p_id BETWEEN 900000001 AND 900000220 THEN 2
        WHEN p_id BETWEEN 910000001 AND 910599999 THEN ((p_id - 910000000) / 100000)::integer
        WHEN p_id BETWEEN 920000001 AND 929999999 THEN ((p_id - 920000000) / 10000)::integer
        ELSE NULL
    END;
$fn$;

CREATE OR REPLACE FUNCTION demo_seed_phone(p_id bigint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT '9' || lpad((demo_seed_hash(p_id::text || ':phone') % 1000000000)::text, 9, '0');
$fn$;

DO $do$
DECLARE
    v_anchor   date;
    v_region   text;
    v_district text;
    v_phc      text;
    v_shc      text;
    v_name     text;
    v_fac      integer;
    v_total    integer;
    v_loss     integer;
    v_lo       numeric;
    v_hi       numeric;
    v_goal     numeric;
    v_blo      numeric;
    v_bhi      numeric;
    v_a        integer;
    v_b        integer;
    v_ta       integer;
    v_tb       integer;
    v_da       integer;
    v_db       integer;
    v_guard    integer;
    v_ctrl     integer;
    v_denom    integer;
    v_add      integer;
    v_got      integer;
    v_i        integer;
    v_pick     bigint;
    v_org      integer;
    v_first    timestamp;
    v_when     timestamp;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '10_visits') THEN
        RAISE NOTICE '10_visits already applied';
        RETURN;
    END IF;

    SELECT COALESCE(MAX(encounter_date)::date, DATE '2026-10-13')
      INTO v_anchor
      FROM encounters;

    -- Same names as test_data/demo/build_demo_data.py. Re-running the chain
    -- does not rewrite an org unit that ingest already stored.
    FOR v_region, v_district, v_phc, v_shc IN
        SELECT *
        FROM (VALUES
            ('Region-A', 'District-A', 'PHC-A', 'SHC-A'),
            ('Region-A', 'District-A', 'PHC-A', 'SHC-B'),
            ('Region-A', 'District-A', 'PHC-A', 'SHC-C'),
            ('Region-A', 'District-A', 'PHC-A', 'SHC-D'),
            ('Region-A', 'District-A', 'PHC-B', 'SHC-E'),
            ('Region-A', 'District-A', 'PHC-B', 'SHC-F'),
            ('Region-A', 'District-A', 'PHC-B', 'SHC-G'),
            ('Region-A', 'District-A', 'PHC-B', 'SHC-H'),
            ('Region-A', 'District-B', 'PHC-C', 'SHC-I'),
            ('Region-A', 'District-B', 'PHC-C', 'SHC-J'),
            ('Region-A', 'District-B', 'PHC-C', 'SHC-K'),
            ('Region-A', 'District-B', 'PHC-C', 'SHC-L'),
            ('Region-B', 'District-C', 'PHC-D', 'SHC-M'),
            ('Region-B', 'District-C', 'PHC-D', 'SHC-N'),
            ('Region-B', 'District-C', 'PHC-D', 'SHC-O'),
            ('Region-B', 'District-C', 'PHC-D', 'SHC-P'),
            ('Region-B', 'District-D', 'PHC-E', 'SHC-Q'),
            ('Region-B', 'District-D', 'PHC-E', 'SHC-R'),
            ('Region-B', 'District-D', 'PHC-E', 'SHC-S'),
            ('Region-B', 'District-D', 'PHC-E', 'SHC-T'),
            ('Region-B', 'District-D', 'PHC-F', 'SHC-U'),
            ('Region-B', 'District-D', 'PHC-F', 'SHC-V'),
            ('Region-B', 'District-D', 'PHC-F', 'SHC-W'),
            ('Region-B', 'District-D', 'PHC-F', 'SHC-X')
        ) AS chain(region_name, district_name, phc_name, shc_name)
    LOOP
        PERFORM upsert_org_unit_chain(
            ARRAY[v_region, v_district, v_phc, v_shc]::varchar[],
            ARRAY[1, 2, 3, 4]::integer[]
        );
    END LOOP;

    -- Established cohort: 200 patients per PHC, registered 2025-01-15, age 56.
    INSERT INTO patients (
        patient_id, patient_name, gender, phone_number, patient_status,
        registration_date, birth_date, death_date, org_unit_id
    )
    SELECT
        id.pid,
        'Demo ' || id.pid::text,
        CASE WHEN demo_seed_hash(id.pid::text || ':gender') % 2 = 0 THEN 'Female' ELSE 'Male' END,
        demo_seed_phone(id.pid),
        'ALIVE',
        TIMESTAMP '2025-01-15 09:00:00',
        DATE '1970-06-15',
        NULL,
        shc.id
    FROM generate_series(0, 5) AS slot
    CROSS JOIN generate_series(1, 200) AS n
    CROSS JOIN LATERAL (
        SELECT (910000000 + slot * 100000 + n)::bigint AS pid
    ) AS id
    JOIN LATERAL (
        SELECT ou.id
        FROM org_units ou
        WHERE ou.level = 3
          AND ou.name = (ARRAY['PHC-A','PHC-B','PHC-C','PHC-D','PHC-E','PHC-F'])[slot + 1]
        ORDER BY ou.id
        LIMIT 1
    ) AS phc ON true
    JOIN LATERAL (
        SELECT s.id
        FROM (
            SELECT c.id,
                   row_number() OVER (ORDER BY c.name) - 1 AS rn,
                   count(*) OVER () AS cnt
            FROM org_units c
            WHERE c.parent_id = phc.id
              AND c.level = 4
        ) AS s
        WHERE s.rn = demo_seed_hash(id.pid::text || ':shc') % s.cnt
    ) AS shc ON true
    ON CONFLICT DO NOTHING;

    -- New patients other than the PHC-C phoneless block. First visit 2026-08-01,
    -- so October still treats them as newly registered.
    INSERT INTO patients (
        patient_id, patient_name, gender, phone_number, patient_status,
        registration_date, birth_date, death_date, org_unit_id
    )
    SELECT
        id.pid,
        'Demo ' || id.pid::text,
        CASE WHEN demo_seed_hash(id.pid::text || ':gender') % 2 = 0 THEN 'Female' ELSE 'Male' END,
        demo_seed_phone(id.pid),
        'ALIVE',
        TIMESTAMP '2026-08-01 09:00:00',
        DATE '1996-06-15',
        NULL,
        shc.id
    FROM generate_series(0, 5) AS slot
    CROSS JOIN LATERAL generate_series(201, CASE WHEN slot = 2 THEN 380 ELSE 280 END) AS ns(n)
    CROSS JOIN LATERAL (
        SELECT (910000000 + slot * 100000 + ns.n)::bigint AS pid
    ) AS id
    JOIN LATERAL (
        SELECT ou.id
        FROM org_units ou
        WHERE ou.level = 3
          AND ou.name = (ARRAY['PHC-A','PHC-B','PHC-C','PHC-D','PHC-E','PHC-F'])[slot + 1]
        ORDER BY ou.id
        LIMIT 1
    ) AS phc ON true
    JOIN LATERAL (
        SELECT s.id
        FROM (
            SELECT c.id,
                   row_number() OVER (ORDER BY c.name) - 1 AS rn,
                   count(*) OVER () AS cnt
            FROM org_units c
            WHERE c.parent_id = phc.id
              AND c.level = 4
        ) AS s
        WHERE s.rn = demo_seed_hash(id.pid::text || ':shc') % s.cnt
    ) AS shc ON true
    ON CONFLICT DO NOTHING;

    -- PHC-C: 220 new patients with no phone. Ids start at 900000001.
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
    FROM generate_series(900000001, 900000220) AS id(pid)
    JOIN LATERAL (
        SELECT ou.id
        FROM org_units ou
        WHERE ou.level = 3
          AND ou.name = 'PHC-C'
        ORDER BY ou.id
        LIMIT 1
    ) AS phc ON true
    JOIN LATERAL (
        SELECT s.id
        FROM (
            SELECT c.id,
                   row_number() OVER (ORDER BY c.name) - 1 AS rn,
                   count(*) OVER () AS cnt
            FROM org_units c
            WHERE c.parent_id = phc.id
              AND c.level = 4
        ) AS s
        WHERE s.rn = demo_seed_hash(id.pid::text || ':shc') % s.cnt
    ) AS shc ON true
    ON CONFLICT DO NOTHING;

    -- Call cohort: under 40, no I10, no BP. One batch per month so early calls
    -- are possible in that month and nowhere earlier. Seed 30 places the calls.
    INSERT INTO patients (
        patient_id, patient_name, gender, phone_number, patient_status,
        registration_date, birth_date, death_date, org_unit_id
    )
    SELECT
        id.pid,
        'Demo ' || id.pid::text,
        CASE WHEN demo_seed_hash(id.pid::text || ':gender') % 2 = 0 THEN 'Female' ELSE 'Male' END,
        demo_seed_phone(id.pid),
        'ALIVE',
        TIMESTAMP '2025-01-15 09:00:00',
        DATE '1996-06-15',
        NULL,
        shc.id
    FROM generate_series(0, 5) AS slot
    CROSS JOIN generate_series(0, 5) AS m
    CROSS JOIN generate_series(1, 120) AS i
    CROSS JOIN LATERAL (
        SELECT (920000000 + slot * 10000 + m * 200 + i)::bigint AS pid
    ) AS id
    JOIN LATERAL (
        SELECT ou.id
        FROM org_units ou
        WHERE ou.level = 3
          AND ou.name = (ARRAY['PHC-A','PHC-B','PHC-C','PHC-D','PHC-E','PHC-F'])[slot + 1]
        ORDER BY ou.id
        LIMIT 1
    ) AS phc ON true
    JOIN LATERAL (
        SELECT s.id
        FROM (
            SELECT c.id,
                   row_number() OVER (ORDER BY c.name) - 1 AS rn,
                   count(*) OVER () AS cnt
            FROM org_units c
            WHERE c.parent_id = phc.id
              AND c.level = 4
        ) AS s
        WHERE s.rn = demo_seed_hash(id.pid::text || ':shc') % s.cnt
    ) AS shc ON true
    ON CONFLICT DO NOTHING;

    INSERT INTO patient_diagnoses (patient_id, diagnosis_code)
    SELECT p.patient_id, 'I10'
    FROM patients p
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) IN ('established', 'new')
    ON CONFLICT DO NOTHING;

    -- About half of each facility's established patients also have diabetes,
    -- which makes them statin-eligible. The call and new cohorts stay under 40.
    INSERT INTO patient_diagnoses (patient_id, diagnosis_code)
    SELECT ranked.patient_id, 'E11'
    FROM (
        SELECT p.patient_id,
               row_number() OVER (
                   PARTITION BY demo_seed_slot(p.patient_id)
                   ORDER BY md5(p.patient_id::text || ':dm')
               ) AS rn,
               count(*) OVER (PARTITION BY demo_seed_slot(p.patient_id)) AS n
        FROM patients p
        WHERE p.patient_name = 'Demo ' || p.patient_id::text
          AND demo_seed_kind(p.patient_id) = 'established'
    ) AS ranked
    WHERE ranked.rn <= round(0.50 * ranked.n)
    ON CONFLICT DO NOTHING;

    -- Established visits. 2026-04-20 is the first encounter, before the
    -- new-patient window opens on 2026-05-05, so these patients are not new.
    -- 2026-07-15 is a controlled reading outside the bunching window.
    -- 2026-09-01 is the high reading used for stepping up.
    -- 2026-10-10 is the latest reading.
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
    SELECT p.patient_id, v.visit_at, p.org_unit_id
    FROM patients p
    CROSS JOIN (
        VALUES
            (TIMESTAMP '2026-04-20 10:00:00'),
            (TIMESTAMP '2026-07-15 10:00:00'),
            (TIMESTAMP '2026-09-01 10:00:00'),
            (TIMESTAMP '2026-10-10 10:00:00')
    ) AS v(visit_at)
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) = 'established'
    ON CONFLICT DO NOTHING;

    -- Pin the newest encounter at the anchor so visits after 2026-09-13 stay
    -- inside the "too recent to judge stepping up" band.
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
    SELECT p.patient_id, TIMESTAMP '2026-10-13 16:00:00', p.org_unit_id
    FROM patients p
    WHERE p.patient_id = 910000001
      AND p.patient_name = 'Demo 910000001'
    ON CONFLICT DO NOTHING;

    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT e.id,
           CASE e.encounter_date
               WHEN TIMESTAMP '2026-04-20 10:00:00' THEN 128
               WHEN TIMESTAMP '2026-07-15 10:00:00' THEN 128
               WHEN TIMESTAMP '2026-09-01 10:00:00' THEN 162
               ELSE CASE WHEN ranked.controlled THEN 122 ELSE 158 END
           END,
           CASE
               WHEN e.encounter_date = TIMESTAMP '2026-09-01 10:00:00' THEN 96
               WHEN e.encounter_date IN (
                   TIMESTAMP '2026-04-20 10:00:00',
                   TIMESTAMP '2026-07-15 10:00:00'
               ) THEN 80
               WHEN NOT ranked.controlled THEN 96
               ELSE 80
           END
    FROM encounters e
    JOIN (
        SELECT p.patient_id,
               row_number() OVER (
                   PARTITION BY demo_seed_slot(p.patient_id)
                   ORDER BY md5(p.patient_id::text || ':control')
               ) <= round(0.60 * count(*) OVER (PARTITION BY demo_seed_slot(p.patient_id))) AS controlled
        FROM patients p
        WHERE p.patient_name = 'Demo ' || p.patient_id::text
          AND demo_seed_kind(p.patient_id) = 'established'
    ) AS ranked ON ranked.patient_id = e.patient_id
    WHERE e.encounter_date IN (
        TIMESTAMP '2026-04-20 10:00:00',
        TIMESTAMP '2026-07-15 10:00:00',
        TIMESTAMP '2026-09-01 10:00:00',
        TIMESTAMP '2026-10-10 10:00:00',
        TIMESTAMP '2026-10-13 16:00:00'
    )
    ON CONFLICT DO NOTHING;

    -- New-patient first visits, all inside [2026-05-05, 2026-08-02].
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
    SELECT p.patient_id, TIMESTAMP '2026-08-01 09:00:00', p.org_unit_id
    FROM patients p
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) = 'new'
    ON CONFLICT DO NOTHING;

    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT e.id, 124, 78
    FROM encounters e
    JOIN patients p ON p.patient_id = e.patient_id
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) = 'new'
      AND e.encounter_date = TIMESTAMP '2026-08-01 09:00:00'
    ON CONFLICT DO NOTHING;

    -- Second visits until the synthetic loss rate sits in the facility band.
    -- PHC-D keeps about 37.5% without a second visit; the others about 27%.
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
    SELECT ranked.patient_id, TIMESTAMP '2026-09-25 14:00:00', p.org_unit_id
    FROM (
        SELECT p.patient_id,
               demo_seed_slot(p.patient_id) AS slot,
               row_number() OVER (
                   PARTITION BY demo_seed_slot(p.patient_id)
                   ORDER BY md5(p.patient_id::text || ':loss')
               ) AS rn,
               count(*) OVER (PARTITION BY demo_seed_slot(p.patient_id)) AS n
        FROM patients p
        WHERE p.patient_name = 'Demo ' || p.patient_id::text
          AND demo_seed_kind(p.patient_id) = 'new'
    ) AS ranked
    JOIN patients p ON p.patient_id = ranked.patient_id
    WHERE ranked.rn > round(
        (CASE WHEN ranked.slot = 3 THEN 0.375 ELSE 0.27 END) * ranked.n
    )
    ON CONFLICT DO NOTHING;

    INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
    SELECT e.id, 124, 78
    FROM encounters e
    JOIN patients p ON p.patient_id = e.patient_id
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) = 'new'
      AND e.encounter_date = TIMESTAMP '2026-09-25 14:00:00'
    ON CONFLICT DO NOTHING;

    -- Call-cohort visits have no BP, so they do not enter the control denominator.
    INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
    SELECT p.patient_id, TIMESTAMP '2025-06-01 09:00:00', p.org_unit_id
    FROM patients p
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) = 'call'
    ON CONFLICT DO NOTHING;

    INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
    SELECT p.patient_id,
           (
               CASE
                   WHEN ((p.patient_id - 920000000) % 10000) % 200 <= 80
                       THEN DATE '2026-05-01'
                            + (((p.patient_id - 920000000) % 10000) / 200) * INTERVAL '1 month'
                            - INTERVAL '50 days'
                   ELSE DATE '2026-05-01'
                            + (((p.patient_id - 920000000) % 10000) / 200) * INTERVAL '1 month'
                            - INTERVAL '100 days'
               END
           ) + TIME '10:00',
           p.org_unit_id
    FROM patients p
    WHERE p.patient_name = 'Demo ' || p.patient_id::text
      AND demo_seed_kind(p.patient_id) = 'call'
    ON CONFLICT DO NOTHING;

    -- If source patients push new-patient loss above the band, add second visits.
    -- Insert-only cannot raise a loss rate that is already too low.
    FOR v_name, v_fac, v_lo, v_hi IN
        SELECT bands.name, ou.id, bands.lo, bands.hi
        FROM (VALUES
            ('PHC-A', 0.24::numeric, 0.30::numeric),
            ('PHC-B', 0.24, 0.30),
            ('PHC-C', 0.24, 0.30),
            ('PHC-D', 0.36, 0.40),
            ('PHC-E', 0.24, 0.30),
            ('PHC-F', 0.24, 0.30)
        ) AS bands(name, lo, hi)
        JOIN LATERAL (
            SELECT id
            FROM org_units
            WHERE name = bands.name AND level = 3
            ORDER BY id
            LIMIT 1
        ) AS ou ON true
    LOOP
        FOR v_i IN 1..4000 LOOP
            SELECT count(*),
                   count(*) FILTER (
                       WHERE NOT EXISTS (
                           SELECT 1
                           FROM encounters later
                           WHERE later.patient_id = cohort.patient_id
                             AND later.encounter_date > cohort.first_dt
                             AND later.encounter_date <= cohort.first_dt + INTERVAL '90 days'
                       )
                   )
              INTO v_total, v_loss
            FROM (
                SELECT p.patient_id, min(e.encounter_date) AS first_dt
                FROM patients p
                JOIN encounters e ON e.patient_id = p.patient_id
                WHERE p.patient_status = 'ALIVE'
                  AND p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
                GROUP BY p.patient_id
                HAVING min(e.encounter_date)::date BETWEEN DATE '2026-05-05' AND DATE '2026-08-02'
            ) AS cohort;

            EXIT WHEN v_total IS NULL OR v_total = 0
                OR v_loss::numeric / v_total <= v_hi;
            EXIT WHEN (v_loss - 1)::numeric / v_total < v_lo;

            SELECT cohort.patient_id, p.org_unit_id, cohort.first_dt
              INTO v_pick, v_org, v_first
            FROM (
                SELECT p.patient_id, min(e.encounter_date) AS first_dt
                FROM patients p
                JOIN encounters e ON e.patient_id = p.patient_id
                WHERE p.patient_status = 'ALIVE'
                  AND p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
                GROUP BY p.patient_id
                HAVING min(e.encounter_date)::date BETWEEN DATE '2026-05-05' AND DATE '2026-08-02'
            ) AS cohort
            JOIN patients p ON p.patient_id = cohort.patient_id
            WHERE NOT EXISTS (
                SELECT 1
                FROM encounters later
                WHERE later.patient_id = cohort.patient_id
                  AND later.encounter_date > cohort.first_dt
                  AND later.encounter_date <= cohort.first_dt + INTERVAL '90 days'
            )
            ORDER BY md5(cohort.patient_id::text || ':loss-fill')
            LIMIT 1;

            EXIT WHEN v_pick IS NULL;

            v_when := v_first + INTERVAL '40 days'
                      + (v_pick % 20) * INTERVAL '1 day';
            IF v_when > v_first + INTERVAL '90 days' OR v_when::date > DATE '2026-10-13' THEN
                EXIT;
            END IF;

            INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
            VALUES (v_pick, v_when, v_org)
            ON CONFLICT DO NOTHING;

            INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
            SELECT e.id, 124, 78
            FROM encounters e
            WHERE e.patient_id = v_pick
              AND e.encounter_date = v_when
            ON CONFLICT DO NOTHING;

            IF NOT EXISTS (
                SELECT 1 FROM encounters e
                WHERE e.patient_id = v_pick AND e.encounter_date = v_when
            ) THEN
                EXIT;
            END IF;
        END LOOP;
    END LOOP;

    -- PHC-E: add a 135-139 visit after the latest visit of uncontrolled patients
    -- until the October control share is about 75% (band 72-78%).
    SELECT ou.id
      INTO v_fac
      FROM org_units ou
     WHERE ou.name = 'PHC-E' AND ou.level = 3
     ORDER BY ou.id
     LIMIT 1;

    IF v_fac IS NOT NULL THEN
        WITH latest AS (
            SELECT DISTINCT ON (e.patient_id)
                   e.patient_id, e.encounter_date, bp.systolic_bp, bp.diastolic_bp
            FROM encounters e
            JOIN blood_pressures bp ON bp.encounter_id = e.id
            WHERE e.encounter_date < TIMESTAMP '2026-11-01'
            ORDER BY e.patient_id, e.encounter_date DESC, e.id DESC
        )
        SELECT
            count(*) FILTER (
                WHERE date_trunc('month', p.registration_date) + INTERVAL '3 months' <= DATE '2026-10-01'
                  AND date_trunc('month', latest.encounter_date) + INTERVAL '12 months' > DATE '2026-10-01'
            ),
            count(*) FILTER (
                WHERE date_trunc('month', p.registration_date) + INTERVAL '3 months' <= DATE '2026-10-01'
                  AND date_trunc('month', latest.encounter_date) + INTERVAL '3 months' > DATE '2026-10-01'
                  AND latest.systolic_bp < 140
                  AND latest.diastolic_bp < 90
            )
          INTO v_denom, v_ctrl
        FROM patients p
        JOIN latest ON latest.patient_id = p.patient_id
        WHERE p.patient_status = 'ALIVE'
          AND p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
          AND EXISTS (
              SELECT 1 FROM patient_diagnoses d
              WHERE d.patient_id = p.patient_id AND d.diagnosis_code = 'I10'
          );

        IF v_denom > 0 AND v_ctrl::numeric / v_denom < 0.72 THEN
            v_add := LEAST(
                CEIL(0.75 * v_denom - v_ctrl)::integer,
                FLOOR(0.78 * v_denom - v_ctrl)::integer
            );
            IF v_add < 0 THEN
                v_add := 0;
            END IF;

            WITH latest AS (
                SELECT DISTINCT ON (e.patient_id)
                       e.patient_id, e.encounter_date, bp.systolic_bp, bp.diastolic_bp
                FROM encounters e
                JOIN blood_pressures bp ON bp.encounter_id = e.id
                WHERE e.encounter_date < TIMESTAMP '2026-11-01'
                ORDER BY e.patient_id, e.encounter_date DESC, e.id DESC
            ),
            picked AS (
                SELECT p.patient_id,
                       p.org_unit_id,
                       TIMESTAMP '2026-10-12 11:00:00'
                           + row_number() OVER (ORDER BY md5(p.patient_id::text || ':control-top'))
                             * INTERVAL '1 minute' AS visit_at
                FROM patients p
                JOIN latest ON latest.patient_id = p.patient_id
                WHERE p.patient_status = 'ALIVE'
                  AND p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
                  AND EXISTS (
                      SELECT 1 FROM patient_diagnoses d
                      WHERE d.patient_id = p.patient_id AND d.diagnosis_code = 'I10'
                  )
                  AND date_trunc('month', p.registration_date) + INTERVAL '3 months' <= DATE '2026-10-01'
                  AND date_trunc('month', latest.encounter_date) + INTERVAL '12 months' > DATE '2026-10-01'
                  AND (
                      date_trunc('month', latest.encounter_date) + INTERVAL '3 months' <= DATE '2026-10-01'
                      OR latest.systolic_bp >= 140
                      OR latest.diastolic_bp >= 90
                  )
                  AND latest.encounter_date < TIMESTAMP '2026-10-12 11:00:00'
                ORDER BY md5(p.patient_id::text || ':control-top')
                LIMIT v_add
            ),
            ins AS (
                INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
                SELECT patient_id, visit_at, org_unit_id FROM picked
                ON CONFLICT DO NOTHING
                RETURNING id
            )
            INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
            SELECT id, 136, 84 FROM ins
            ON CONFLICT DO NOTHING;

            GET DIAGNOSTICS v_got = ROW_COUNT;
            RAISE NOTICE 'PHC-E control top-up added % of % requested (was % / %)',
                v_got, v_add, v_ctrl, v_denom;
        END IF;
    END IF;

    -- Bunching: 135-139 and 140-144 readings that are not the latest visit.
    -- 140-144 rows are attached to patients whose latest reading is still high.
    FOR v_name, v_fac, v_goal, v_blo, v_bhi IN
        SELECT bands.name, ou.id, bands.goal, bands.lo, bands.hi
        FROM (VALUES
            ('PHC-A', 1.2::numeric, 0.9::numeric, 1.5::numeric),
            ('PHC-B', 1.2, 0.9, 1.5),
            ('PHC-C', 1.2, 0.9, 1.5),
            ('PHC-D', 1.2, 0.9, 1.5),
            ('PHC-E', 5.4, 5.2, 5.6),
            ('PHC-F', 1.2, 0.9, 1.5)
        ) AS bands(name, goal, lo, hi)
        JOIN LATERAL (
            SELECT id FROM org_units
            WHERE name = bands.name AND level = 3
            ORDER BY id
            LIMIT 1
        ) AS ou ON true
    LOOP
        SELECT
            count(*) FILTER (WHERE bp.systolic_bp >= 135 AND bp.systolic_bp < 140),
            count(*) FILTER (WHERE bp.systolic_bp >= 140 AND bp.systolic_bp < 145)
          INTO v_a, v_b
        FROM blood_pressures bp
        JOIN encounters e ON e.id = bp.encounter_id
        JOIN patients p ON p.patient_id = e.patient_id
        WHERE p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
          AND e.encounter_date::date BETWEEN DATE '2026-08-03' AND DATE '2026-10-31';

        IF v_b = 0 THEN
            v_tb := 10;
        ELSE
            v_tb := v_b;
        END IF;
        v_ta := round(v_tb * v_goal)::integer;
        IF v_a > v_ta THEN
            v_tb := GREATEST(v_tb, ceil(v_a / v_goal)::integer);
            v_ta := GREATEST(v_a, round(v_tb * v_goal)::integer);
        END IF;

        v_guard := 0;
        WHILE v_tb > 0 AND v_ta::numeric > v_tb * v_bhi AND v_guard < 5000 LOOP
            v_tb := v_tb + 1;
            v_guard := v_guard + 1;
        END LOOP;
        v_guard := 0;
        WHILE v_tb > 0 AND v_ta::numeric < v_tb * v_blo AND v_guard < 5000 LOOP
            v_ta := v_ta + 1;
            v_guard := v_guard + 1;
        END LOOP;
        v_guard := 0;
        WHILE v_ta + v_tb < 20 AND v_guard < 50 LOOP
            v_tb := v_tb + 1;
            WHILE v_ta::numeric < v_tb * v_blo AND v_guard < 5000 LOOP
                v_ta := v_ta + 1;
                v_guard := v_guard + 1;
            END LOOP;
            v_guard := v_guard + 1;
        END LOOP;

        v_da := GREATEST(v_ta - v_a, 0);
        v_db := GREATEST(v_tb - v_b, 0);
        IF v_da > 400 THEN
            v_da := 400;
        END IF;
        IF v_db > 400 THEN
            v_db := 400;
        END IF;

        WITH pool AS (
            SELECT p.patient_id, p.org_unit_id
            FROM patients p
            JOIN LATERAL (
                SELECT e.encounter_date, bp.systolic_bp, bp.diastolic_bp
                FROM encounters e
                JOIN blood_pressures bp ON bp.encounter_id = e.id
                WHERE e.patient_id = p.patient_id
                ORDER BY e.encounter_date DESC, e.id DESC
                LIMIT 1
            ) AS latest ON true
            WHERE p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
              AND latest.encounter_date >= TIMESTAMP '2026-09-25'
              AND (latest.systolic_bp >= 140 OR latest.diastolic_bp >= 90)
        ),
        picked AS (
            SELECT patient_id,
                   org_unit_id,
                   TIMESTAMP '2026-09-20 08:00:00'
                       + row_number() OVER (ORDER BY md5(patient_id::text || ':band-over:' || v_name))
                         * INTERVAL '1 minute' AS visit_at
            FROM pool
            ORDER BY md5(patient_id::text || ':band-over:' || v_name)
            LIMIT v_db
        ),
        ins AS (
            INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
            SELECT patient_id, visit_at, org_unit_id FROM picked
            ON CONFLICT DO NOTHING
            RETURNING id
        )
        INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
        SELECT id, 142, 88 FROM ins
        ON CONFLICT DO NOTHING;

        WITH pool AS (
            SELECT p.patient_id, p.org_unit_id
            FROM patients p
            JOIN LATERAL (
                SELECT e.encounter_date
                FROM encounters e
                JOIN blood_pressures bp ON bp.encounter_id = e.id
                WHERE e.patient_id = p.patient_id
                ORDER BY e.encounter_date DESC, e.id DESC
                LIMIT 1
            ) AS latest ON true
            WHERE p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
              AND latest.encounter_date >= TIMESTAMP '2026-09-25'
        ),
        picked AS (
            SELECT patient_id,
                   org_unit_id,
                   TIMESTAMP '2026-09-21 08:00:00'
                       + row_number() OVER (ORDER BY md5(patient_id::text || ':band-under:' || v_name))
                         * INTERVAL '1 minute' AS visit_at
            FROM pool
            ORDER BY md5(patient_id::text || ':band-under:' || v_name)
            LIMIT v_da
        ),
        ins AS (
            INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
            SELECT patient_id, visit_at, org_unit_id FROM picked
            ON CONFLICT DO NOTHING
            RETURNING id
        )
        INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
        SELECT id, 137, 84 FROM ins
        ON CONFLICT DO NOTHING;

        RAISE NOTICE '% bunching plan a % -> % , b % -> %', v_name, v_a, v_ta, v_b, v_tb;
    END LOOP;

    -- About 4% of patients aged 40 or older on 2026-10-31.
    INSERT INTO patient_cvd_history (patient_id, event_type, event_date, source)
    SELECT ranked.patient_id,
           CASE WHEN demo_seed_hash(ranked.patient_id::text || ':cvd-type') % 2 = 0
                THEN 'MI' ELSE 'STROKE' END,
           DATE '2024-01-15',
           'demo'
    FROM (
        SELECT p.patient_id,
               row_number() OVER (ORDER BY md5(p.patient_id::text || ':cvd')) AS rn,
               count(*) OVER () AS n
        FROM patients p
        WHERE p.patient_status = 'ALIVE'
          AND p.birth_date IS NOT NULL
          AND p.birth_date <= DATE '1986-10-31'
    ) AS ranked
    WHERE ranked.n > 0
      AND ranked.rn <= round(0.04 * ranked.n)
    ON CONFLICT DO NOTHING;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('10_visits', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '10_visits applied, anchor %', v_anchor;
END
$do$;
