-- Screening and treatment cascades, Hypertension tab panel-stc (story 14.3, H360-463, H360-454).
-- One row: the place name and the numbers; names, targets and step 4 live in cascade.js (COUNTRIES).
-- Month: the latest completed month, like the other Hypertension headlines.
-- Temporary sources (demo seed 50): demo_cascade_population, demo_cascade_prevalence and
-- demo_cascade_screening. Gyan's H360-501, H360-504 and H360-505 replace them; keep these columns.
WITH sel AS (SELECT NULLIF(NULLIF(TRIM(BOTH FROM '${org_unit}'), ''), '0')::int AS id),
scope AS (SELECT id FROM get_descendant_ids((SELECT id FROM sel))),
m AS (SELECT (to_timestamp(${reference_month}/1000.0) - interval '1 month')::date AS mon),
pop AS (
  SELECT SUM(p.adults) AS adults
  FROM demo_cascade_population p, m
  WHERE p.org_unit_id IN (SELECT id FROM scope) AND p.year = EXTRACT(YEAR FROM m.mon) AND p.age_group = '15+'),
prev AS (
  SELECT v.prevalence_pct FROM demo_cascade_prevalence v, m
  WHERE v.year = EXTRACT(YEAR FROM m.mon) AND v.age_group = '15+'),
scr AS (
  SELECT COUNT(*) AS screening_rows, SUM(s.screened) AS screened, SUM(s.raised) AS raised,
         -- Starter medicine (step 4) is not a real indicator yet, so it stays NULL and the chart shows
         -- four bars. When the indicator exists, return its sum here (NULLIF(SUM(...), 0)); the bar
         -- appears with no other change (cascade.js shows step 4 whenever it is not NULL).
         NULL::numeric AS linked, SUM(s.diagnosed) AS diagnosed
  FROM demo_cascade_screening s, m
  WHERE s.as_of_month = m.mon AND s.org_unit_id IN (SELECT id FROM scope)),
trt AS (
  SELECT
    (SELECT SUM(r.cumulative_number_of_patients) FROM heart360tk_reporting.heart360_patients_registered r, m
      WHERE r.ref_month = m.mon AND r.org_unit_id IN (SELECT id FROM scope)) AS registered,
    (SELECT SUM(c.nb_patients_under_care) FROM heart360tk_reporting.heart360_patients_category c, m
      WHERE c.ref_month = m.mon AND c.org_unit_id IN (SELECT id FROM scope)) AS under_care,
    (SELECT SUM(c.nb_patients_controlled) FROM heart360tk_reporting.heart360_patients_category c, m
      WHERE c.ref_month = m.mon AND c.org_unit_id IN (SELECT id FROM scope)) AS controlled)
SELECT to_char(m.mon, 'YYYY-MM-DD') AS reporting_month,
  (SELECT name FROM org_units WHERE id = (SELECT id FROM sel)) AS place,
  pop.adults, prev.prevalence_pct, ROUND(pop.adults * prev.prevalence_pct / 100) AS estimated,
  scr.screening_rows, scr.screened, scr.raised, scr.linked, scr.diagnosed,
  trt.registered, trt.under_care, trt.controlled
FROM m CROSS JOIN pop CROSS JOIN scr CROSS JOIN trt LEFT JOIN prev ON true
WHERE '${isAllowed}' = '1'
