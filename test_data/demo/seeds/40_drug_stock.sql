-- Seed 40: drug stock for the six PHCs (story 4.7, AD-19, AD-22, AD-34).
-- Months 2026-09, 2026-10 and 2026-11 go through drug_stock_pull_apply.
-- PHC-B in 2026-11 is submitted twice, newer row first in the array; the
-- newer submission is the one that stays. PHC-B in 2026-10 has low CCB stock.
-- PHC-F leaves Chlorthalidone 25 blank in 2026-10 so the thiazide category
-- is unknown that month. The cohort is the six PHCs and no descendant of them.
SET ROLE heart360tk;
SET search_path TO heart360tk_schema, public;

CREATE TABLE IF NOT EXISTS demo_seed_marker (
    seed       text PRIMARY KEY,
    anchor     date NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

DO $do$
DECLARE
    v_anchor   date;
    v_payload  jsonb;
    v_expected integer;
    v_accepted integer;
    v_rejected integer;
    v_region   text;
    v_district text;
    v_phc      text;
    v_shc      text;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '40_drug_stock') THEN
        RAISE NOTICE '40_drug_stock already applied';
        RETURN;
    END IF;

    SELECT COALESCE(
        (SELECT anchor FROM demo_seed_marker WHERE seed = '10_visits'),
        DATE '2026-10-13'
    ) INTO v_anchor;

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

    -- Cohort is the six facilities. Skip a facility that would put a node
    -- and its descendant in the cohort together.
    INSERT INTO drug_stock_form_cohort (org_unit_id)
    SELECT phc.id
    FROM (
        SELECT DISTINCT ON (ou.name) ou.id, ou.name
        FROM org_units ou
        WHERE ou.level = 3
          AND ou.name IN ('PHC-A', 'PHC-B', 'PHC-C', 'PHC-D', 'PHC-E', 'PHC-F')
        ORDER BY ou.name, ou.id
    ) AS phc
    WHERE NOT EXISTS (
        SELECT 1
        FROM drug_stock_form_cohort c
        WHERE c.org_unit_id <> phc.id
          AND (
              c.org_unit_id IN (SELECT id FROM get_descendant_ids(phc.id))
              OR phc.id IN (SELECT id FROM get_descendant_ids(c.org_unit_id))
          )
    )
    ON CONFLICT DO NOTHING;

    WITH drugs AS (
        SELECT *
        FROM (VALUES
            ('329528', 'CCB', 1),
            ('329526', 'CCB', 2),
            ('316764', 'ARB', 1),
            ('316765', 'ARB', 2),
            ('331132', 'Diuretic', 1),
            ('197499', 'Diuretic', 2)
        ) AS d(code, category, dose_slot)
    ),
    months AS (
        SELECT *
        FROM (VALUES
            -- submitted_at is an offset from the anchor (2026-10-13), never later
            -- than the demo "now" (anchor + 23 days = 2026-11-05), so a form
            -- save for November wins under Latest Wins. With anchor 2026-10-13:
            -- 2026-09-12 09:00, 2026-10-08 09:00, 2026-11-04 11:30, 2026-11-03 08:00.
            (DATE '2026-09-01', (v_anchor - 31 + TIME '09:00') AT TIME ZONE 'UTC', FALSE),
            (DATE '2026-10-01', (v_anchor -  5 + TIME '09:00') AT TIME ZONE 'UTC', FALSE),
            (DATE '2026-11-01', (v_anchor + 22 + TIME '11:30') AT TIME ZONE 'UTC', FALSE),
            (DATE '2026-11-01', (v_anchor + 21 + TIME '08:00') AT TIME ZONE 'UTC', TRUE)
        ) AS m(month_start, submitted_at, earlier_november)
    ),
    fac AS (
        SELECT DISTINCT ON (ou.name) ou.id, ou.name
        FROM org_units ou
        WHERE ou.level = 3
          AND ou.name IN ('PHC-A', 'PHC-B', 'PHC-C', 'PHC-D', 'PHC-E', 'PHC-F')
        ORDER BY ou.name, ou.id
    ),
    sized AS (
        SELECT f.id AS org_unit_id,
               f.name,
               m.month_start,
               m.submitted_at,
               m.earlier_november,
               (
                   SELECT count(*)
                   FROM patients p
                   JOIN patient_diagnoses dx
                     ON dx.patient_id = p.patient_id
                    AND dx.diagnosis_code = 'I10'
                   WHERE p.patient_status = 'ALIVE'
                     AND p.registration_date < (m.month_start + INTERVAL '1 month')
                     AND p.org_unit_id IN (SELECT id FROM get_descendant_ids(f.id))
               ) AS patients_n
        FROM fac f
        CROSS JOIN months m
        WHERE NOT m.earlier_november
           OR f.name = 'PHC-B'
    ),
    stocked AS (
        SELECT s.org_unit_id,
               s.name,
               s.month_start,
               s.submitted_at,
               s.earlier_november,
               d.code,
               CASE
                   WHEN s.earlier_november THEN 1::numeric
                   WHEN s.name = 'PHC-F'
                        AND s.month_start = DATE '2026-10-01'
                        AND d.code = '197499' THEN NULL
                   WHEN d.category = 'CCB' AND d.dose_slot = 2 THEN 0
                   WHEN d.category = 'CCB'
                        AND s.name = 'PHC-B'
                        AND s.month_start = DATE '2026-10-01'
                       THEN round(18 * GREATEST(s.patients_n, 1) * 1.4)
                   WHEN d.category = 'CCB'
                       THEN round(90 * GREATEST(s.patients_n, 1) * 1.4)
                   WHEN d.category = 'ARB' AND d.dose_slot = 2 THEN 0
                   WHEN d.category = 'ARB'
                       THEN round(90 * GREATEST(s.patients_n, 1) * 0.37)
                   WHEN d.category = 'Diuretic' AND d.dose_slot = 2 THEN 0
                   ELSE round(90 * GREATEST(s.patients_n, 1) * 0.06)
               END AS in_stock,
               'stock.' || lower(s.name) || '@hearts360.demo' AS submitter_email
        FROM sized s
        CROSS JOIN drugs d
    ),
    numbered AS (
        SELECT stocked.*,
               row_number() OVER (
                   ORDER BY submitted_at DESC, org_unit_id, code
               )::integer AS sheet_row
        FROM stocked
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'org_unit_id', org_unit_id::text,
                   'reporting_month', to_char(month_start, 'YYYY-MM-DD'),
                   'drug_code', code,
                   'in_stock', in_stock,
                   'submitted_at', to_char(submitted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   'submitter_email', submitter_email,
                   'sheet_row', sheet_row
               )
               ORDER BY submitted_at DESC, org_unit_id, code
           ),
           count(*)
      INTO v_payload, v_expected
    FROM numbered;

    SELECT accepted, rejected
      INTO v_accepted, v_rejected
    FROM drug_stock_pull_apply(v_payload);

    IF v_rejected <> 0 OR v_accepted <> v_expected THEN
        RAISE EXCEPTION 'drug stock seed accepted % rejected %, expected %',
            v_accepted, v_rejected, v_expected;
    END IF;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('40_drug_stock', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '40_drug_stock applied, % rows', v_accepted;
END
$do$;
