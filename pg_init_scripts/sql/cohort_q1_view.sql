-- Quarter-1 cohort. The follow-up window is the next quarter after registration.
-- A later visit in that window with no complete blood pressure is visited_no_bp.
-- An earlier reading in the same window does not override it.
-- An open follow-up quarter is omitted. It is not a missed visit.
CREATE OR REPLACE VIEW HEART360_COHORT_PATIENT_DETAILS AS
WITH members AS (
    SELECT
        p.patient_id,
        p.org_unit_id,
        date_trunc('quarter', p.registration_date) AS registration_quarter
    FROM patients p
    WHERE EXISTS (
        SELECT 1
        FROM patient_diagnoses pd
        WHERE pd.patient_id = p.patient_id
          AND pd.diagnosis_code = 'I10'
    )
),
closed AS (
    SELECT
        m.patient_id,
        m.org_unit_id,
        m.registration_quarter,
        m.registration_quarter + interval '3 months' AS window_start,
        m.registration_quarter + interval '6 months' AS window_end
    FROM members m
    WHERE m.registration_quarter + interval '6 months' <= CURRENT_TIMESTAMP
),
latest AS (
    SELECT DISTINCT ON (c.patient_id)
        c.patient_id,
        bp.systolic_bp,
        bp.diastolic_bp
    FROM closed c
    JOIN encounters e
        ON e.patient_id = c.patient_id
       AND e.encounter_date >= c.window_start
       AND e.encounter_date < c.window_end
    LEFT JOIN blood_pressures bp ON bp.encounter_id = e.id
    ORDER BY c.patient_id, e.encounter_date DESC, e.id DESC
)
SELECT
    c.patient_id,
    c.org_unit_id,
    c.registration_quarter,
    CASE
        WHEN l.patient_id IS NULL THEN 'missed_visit'
        WHEN l.systolic_bp IS NULL OR l.diastolic_bp IS NULL THEN 'visited_no_bp'
        WHEN l.systolic_bp < 140 AND l.diastolic_bp < 90 THEN 'controlled'
        ELSE 'uncontrolled'
    END AS status_at_end_of_interval
FROM closed c
LEFT JOIN latest l ON l.patient_id = c.patient_id;
