-- Screening and treatment cascades, PLACEHOLDER variant for branches without the demo seed (H360-321).
-- Same output columns as panel.sql. No tables: the Indonesia example numbers (HTN_Cascade_Data.md)
-- are inline and scaled by the place's share of registered patients, so a facility shows
-- facility-sized numbers. Treatment numbers (registered, under care, controlled) are live.
-- shortcut: placeholder scaled by registered share, replace with panel.sql when H360-501, H360-504
-- and H360-505 land.
WITH sel AS (SELECT NULLIF(NULLIF(TRIM(BOTH FROM '${org_unit}'), ''), '0')::int AS id),
scope AS (SELECT id FROM get_descendant_ids((SELECT id FROM sel))),
m AS (SELECT (to_timestamp(${reference_month}/1000.0) - interval '1 month')::date AS mon),
ex AS (SELECT 2100000::numeric AS adults, 11.94::numeric AS prevalence_pct, 840000::numeric AS screened,
              75600::numeric AS raised, 41000::numeric AS linked, 18900::numeric AS diagnosed),
trt AS (
  SELECT
    (SELECT SUM(r.cumulative_number_of_patients) FROM heart360tk_reporting.heart360_patients_registered r, m
      WHERE r.ref_month = m.mon AND r.org_unit_id IN (SELECT id FROM scope)) AS registered,
    (SELECT SUM(r.cumulative_number_of_patients) FROM heart360tk_reporting.heart360_patients_registered r, m
      WHERE r.ref_month = m.mon) AS registered_all,
    (SELECT SUM(c.nb_patients_under_care) FROM heart360tk_reporting.heart360_patients_category c, m
      WHERE c.ref_month = m.mon AND c.org_unit_id IN (SELECT id FROM scope)) AS under_care,
    (SELECT SUM(c.nb_patients_controlled) FROM heart360tk_reporting.heart360_patients_category c, m
      WHERE c.ref_month = m.mon AND c.org_unit_id IN (SELECT id FROM scope)) AS controlled),
k AS (SELECT COALESCE(trt.registered / NULLIF(trt.registered_all, 0), 0) AS share FROM trt)
SELECT to_char(m.mon, 'YYYY-MM-DD') AS reporting_month,
  (SELECT name FROM org_units WHERE id = (SELECT id FROM sel)) AS place,
  ROUND(ex.adults * k.share) AS adults, ex.prevalence_pct,
  ROUND(ex.adults * k.share * ex.prevalence_pct / 100) AS estimated,
  CASE WHEN k.share > 0 THEN 1 ELSE 0 END AS screening_rows,
  ROUND(ex.screened * k.share) AS screened, ROUND(ex.raised * k.share) AS raised,
  NULL::numeric AS linked, ROUND(ex.diagnosed * k.share) AS diagnosed,
  trt.registered, trt.under_care, trt.controlled
FROM m CROSS JOIN ex CROSS JOIN trt CROSS JOIN k
WHERE '${isAllowed}' = '1'
