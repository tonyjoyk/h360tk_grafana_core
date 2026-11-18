-- Seed 50: TEMPORARY Indonesia example data for the screening and treatment cascades on the
-- Hypertension tab (story 14.1, H360-463, H360-454).
--
-- EXAMPLE DATA, NOT PROGRAM DATA. Demo only, like seed_screening_cascade.sql: no migration, no
-- schema change. The demo_cascade_* tables stand in for the real loads that Gyan owns in 0.8.0:
--   H360-496 / H360-501  population file and load        -> demo_cascade_population
--   H360-504             estimate = population x prevalence -> demo_cascade_prevalence
--   H360-503 / H360-505  monthly screening file and load  -> demo_cascade_screening
--   H360-498             diagnosed this year from EHR      -> demo_cascade_screening.diagnosed
-- When those land, point the panel query (dashboard_src/cascade/panel.sql) at the real tables and
-- retire this seed. The panel reads only the columns listed in dashboard_src/cascade/README.md.
--
-- National totals copy the approved design file
-- (_bmad-output/planning-artifacts/research/htn-cascade-2026-11-18/imports/HTN_Cascade_Data.md):
--   adults aged 15+ 2,100,000; screened 840,000; raised BP 75,600; given starter medicine 41,000;
--   diagnosed 18,900. Prevalence 11.94% (250,800 / 2,100,000 in the design, rounded), so the
--   estimate is 250,740.
-- The demo's last full month is October 2026, so the totals are the year-to-date counts at the
-- end of October. Month m (1 = January) holds m/10 of each unit's October count.
-- Each total is split across the org units that have patients, by their share of patients
-- (largest remainder, so the units add up to the national total exactly).
-- Insert only: no UPDATE, DELETE or random(). A second run adds nothing.
SET ROLE heart360tk;
SET search_path TO heart360tk_schema, public;

CREATE TABLE IF NOT EXISTS demo_seed_marker (
    seed       text PRIMARY KEY,
    anchor     date NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS demo_cascade_population (
    org_unit_id integer NOT NULL REFERENCES org_units (id),
    year        integer NOT NULL,
    age_group   text NOT NULL,
    adults      integer NOT NULL CHECK (adults >= 0),
    PRIMARY KEY (org_unit_id, year, age_group)
);
CREATE TABLE IF NOT EXISTS demo_cascade_prevalence (
    year           integer NOT NULL,
    age_group      text NOT NULL,
    prevalence_pct numeric(5,2) NOT NULL CHECK (prevalence_pct BETWEEN 0 AND 100),
    PRIMARY KEY (year, age_group)
);
-- Counts are year to date at the end of as_of_month (the first day of the month).
CREATE TABLE IF NOT EXISTS demo_cascade_screening (
    org_unit_id integer NOT NULL REFERENCES org_units (id),
    as_of_month date NOT NULL,
    screened    integer CHECK (screened >= 0),
    raised      integer CHECK (raised >= 0),
    linked      integer CHECK (linked >= 0),
    diagnosed   integer CHECK (diagnosed >= 0),
    PRIMARY KEY (org_unit_id, as_of_month)
);
GRANT SELECT ON demo_cascade_population, demo_cascade_prevalence, demo_cascade_screening TO heart360tk_cached, heart360tk_reader;

-- Split p_total across the org units by their share of patients. Session-only helper.
CREATE OR REPLACE FUNCTION pg_temp.cascade_split(p_total bigint)
RETURNS TABLE (org_unit_id integer, n bigint)
LANGUAGE sql STABLE
AS $fn$
    WITH w AS (
        SELECT p.org_unit_id, count(*)::numeric AS patients
        FROM heart360tk_schema.patients p
        JOIN heart360tk_schema.org_units ou ON ou.id = p.org_unit_id
        GROUP BY p.org_unit_id
    ), s AS (
        SELECT w.org_unit_id,
               p_total * w.patients / sum(w.patients) OVER () AS exact
        FROM w
    ), f AS (
        SELECT s.org_unit_id, floor(s.exact)::bigint AS base,
               s.exact - floor(s.exact) AS rest
        FROM s
    ), r AS (
        SELECT f.*, row_number() OVER (ORDER BY f.rest DESC, f.org_unit_id) AS rk,
               p_total - sum(f.base) OVER () AS left_over
        FROM f
    )
    SELECT r.org_unit_id, r.base + CASE WHEN r.rk <= r.left_over THEN 1 ELSE 0 END
    FROM r;
$fn$;

DO $do$
DECLARE
    v_anchor date := DATE '2026-10-01';
    v_months integer := 10;
    v_rows   integer;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '50_cascade_indonesia') THEN
        RAISE NOTICE '50_cascade_indonesia already applied';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM patients) THEN
        RAISE EXCEPTION 'no patients yet; load the demo cohort first';
    END IF;

    INSERT INTO demo_cascade_prevalence (year, age_group, prevalence_pct)
    VALUES (2026, '15+', 11.94)
    ON CONFLICT DO NOTHING;

    INSERT INTO demo_cascade_population (org_unit_id, year, age_group, adults)
    SELECT org_unit_id, 2026, '15+', n FROM pg_temp.cascade_split(2100000)
    ON CONFLICT DO NOTHING;

    -- October totals per org unit, then January to October as m/10 of them (October exact).
    INSERT INTO demo_cascade_screening (org_unit_id, as_of_month, screened, raised, linked, diagnosed)
    SELECT s.org_unit_id,
           (v_anchor - make_interval(months => v_months - m))::date,
           floor(s.n * m / v_months::numeric),
           floor(r.n * m / v_months::numeric),
           floor(l.n * m / v_months::numeric),
           floor(d.n * m / v_months::numeric)
    FROM pg_temp.cascade_split(840000) s
    JOIN pg_temp.cascade_split(75600) r USING (org_unit_id)
    JOIN pg_temp.cascade_split(41000) l USING (org_unit_id)
    JOIN pg_temp.cascade_split(18900) d USING (org_unit_id)
    CROSS JOIN generate_series(1, v_months) AS m
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('50_cascade_indonesia', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '50_cascade_indonesia applied, % screening rows', v_rows;
END
$do$;
