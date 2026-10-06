SELECT * FROM (
  WITH selected_org AS (
    SELECT id FROM get_descendant_ids((
      SELECT ou.id FROM org_units ou
      WHERE ou.id::text = NULLIF(TRIM(BOTH FROM '${org_unit}'), '')
      LIMIT 1
    ))
  ),
  quarters AS (
    SELECT (
      date_trunc('quarter', CURRENT_DATE)
      - interval '6 months'
      - offs.n * interval '3 months'
    ) AS registration_quarter
    FROM generate_series(0, 4) AS offs(n)
  ),
  counts AS (
    SELECT
      q.registration_quarter,
      COUNT(*) FILTER (WHERE c.status_at_end_of_interval = 'controlled') AS controlled,
      COUNT(*) FILTER (WHERE c.status_at_end_of_interval = 'uncontrolled') AS uncontrolled,
      COUNT(*) FILTER (WHERE c.status_at_end_of_interval = 'missed_visit') AS missed_visit,
      COUNT(*) FILTER (WHERE c.status_at_end_of_interval = 'visited_no_bp') AS visited_no_bp
    FROM quarters q
    LEFT JOIN heart360_cohort_patient_details c
      ON c.registration_quarter = q.registration_quarter
     AND c.org_unit_id IN (SELECT id FROM selected_org)
    GROUP BY q.registration_quarter
  )
  SELECT
    to_char(registration_quarter, 'YYYY "Q"Q') AS quarter,
    controlled,
    uncontrolled,
    missed_visit,
    visited_no_bp,
    COALESCE(ROUND(100.0 * controlled / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS controlled_pct,
    COALESCE(ROUND(100.0 * uncontrolled / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS uncontrolled_pct,
    COALESCE(ROUND(100.0 * missed_visit / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS missed_visit_pct,
    COALESCE(ROUND(100.0 * visited_no_bp / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS visited_no_bp_pct
  FROM counts
  ORDER BY registration_quarter DESC
) AS master_access_control
WHERE '${isAllowed}' = '1'
