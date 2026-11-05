-- Run after demo ingest and reporting refresh (psql -f test_data/demo/verify_demo.sql).

DO $$
DECLARE
  v_ref_month date;
  v_estimated_pct numeric;
  v_registered_pct numeric;
  v_under_care_pct numeric;
  v_controlled_pct numeric;
  v_quarter_count integer;
  est_pop numeric := 14500;
BEGIN
  SELECT MAX(ref_month) INTO v_ref_month
  FROM heart360tk_reporting.heart360_patients_category;

  IF v_ref_month IS NULL THEN
    RAISE EXCEPTION 'verify_demo: no rows in heart360_patients_category';
  END IF;

  SELECT
    100.0,
    100.0 * SUM(reg.cumulative_number_of_patients) / est_pop,
    100.0 * SUM(cat.nb_patients_under_care_registered_before_the_past_3_months) / est_pop,
    100.0 * SUM(cat.nb_patients_controlled) / est_pop
  INTO v_estimated_pct, v_registered_pct, v_under_care_pct, v_controlled_pct
  FROM heart360tk_reporting.heart360_patients_category cat
  JOIN heart360tk_reporting.heart360_patients_registered reg
    ON reg.ref_month = cat.ref_month AND reg.org_unit_id = cat.org_unit_id
  WHERE cat.ref_month = v_ref_month;

  IF COALESCE(v_registered_pct, 0) <= 0
     OR COALESCE(v_under_care_pct, 0) <= 0
     OR COALESCE(v_controlled_pct, 0) <= 0 THEN
    RAISE EXCEPTION
      'verify_demo cascade failed at %: estimated=%, registered_pct=%, under_care_pct=%, controlled_pct=%',
      v_ref_month, v_estimated_pct, v_registered_pct, v_under_care_pct, v_controlled_pct;
  END IF;

  SELECT COUNT(*) INTO v_quarter_count
  FROM (
    SELECT registration_quarter
    FROM heart360tk_reporting.heart360_cohort_patient_details
    GROUP BY registration_quarter
    HAVING COUNT(*) > 0
  ) q;

  IF v_quarter_count < 6 THEN
    RAISE EXCEPTION 'verify_demo cohort failed: only % quarters with patients', v_quarter_count;
  END IF;

  RAISE NOTICE 'verify_demo OK: ref_month=%, estimated=%, registered_pct=%, under_care_pct=%, controlled_pct=%, cohort_quarters=%',
    v_ref_month, v_estimated_pct, v_registered_pct, v_under_care_pct, v_controlled_pct, v_quarter_count;
END $$;
