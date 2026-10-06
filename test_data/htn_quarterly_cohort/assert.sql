-- Literal oracle for fixture patients 910001-910018. Run in the same session as seed.sql.

CREATE TEMP TABLE cohort_oracle (
    patient_id bigint PRIMARY KEY,
    outcome text
);

INSERT INTO cohort_oracle (patient_id, outcome) VALUES
    (910001, 'controlled'),
    (910002, 'controlled'),
    (910003, 'uncontrolled'),
    (910004, 'uncontrolled'),
    (910005, 'missed_visit'),
    (910006, 'missed_visit'),
    (910007, 'visited_no_bp'),
    (910008, 'visited_no_bp'),
    (910009, 'visited_no_bp'),
    (910010, 'controlled'),
    (910011, 'uncontrolled'),
    (910012, 'missed_visit'),
    (910013, 'controlled'),
    (910014, NULL),
    (910015, NULL),
    (910016, 'controlled'),
    (910017, 'controlled'),
    (910018, 'visited_no_bp');

DO $check$
DECLARE
    v_bad integer;
    v_detail text;
BEGIN
    SELECT count(*) INTO v_bad
    FROM (
        SELECT patient_id, status_at_end_of_interval AS outcome
        FROM heart360_cohort_patient_details
        WHERE patient_id BETWEEN 910001 AND 910018
        EXCEPT
        SELECT patient_id, outcome FROM cohort_oracle WHERE outcome IS NOT NULL
    ) extra;
    IF v_bad <> 0 THEN
        SELECT string_agg(patient_id::text || '=' || status_at_end_of_interval, ', ')
        INTO v_detail
        FROM heart360_cohort_patient_details
        WHERE patient_id BETWEEN 910001 AND 910018;
        RAISE EXCEPTION 'cohort view does not match oracle: %', v_detail;
    END IF;

    SELECT count(*) INTO v_bad
    FROM cohort_oracle o
    WHERE o.outcome IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM heart360_cohort_patient_details c
          WHERE c.patient_id = o.patient_id
            AND c.status_at_end_of_interval = o.outcome
      );
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'cohort oracle rows missing from the view: %', v_bad;
    END IF;

    SELECT count(*) INTO v_bad
    FROM heart360_cohort_patient_details
    WHERE patient_id IN (910014, 910015);
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'open-quarter or diabetes-only patient leaked into the cohort';
    END IF;
END
$check$;

TRUNCATE heart360tk_reporting.heart360_cohort_patient_details;
INSERT INTO heart360tk_reporting.heart360_cohort_patient_details
SELECT * FROM heart360tk_schema.heart360_cohort_patient_details;

DO $panel$
DECLARE
    v_facility integer;
    v_district integer;
    v_empty integer;
    v_bad integer;
    c0 timestamp;
    c1 timestamp;
BEGIN
    SELECT org_unit_id INTO v_facility FROM cohort_fixture_org WHERE role = 'facility';
    SELECT org_unit_id INTO v_district FROM cohort_fixture_org WHERE role = 'district';
    SELECT org_unit_id INTO v_empty FROM cohort_fixture_org WHERE role = 'empty';
    c0 := date_trunc('quarter', CURRENT_TIMESTAMP) - interval '6 months';
    c1 := c0 - interval '3 months';

    CREATE TEMP TABLE got_panel ON COMMIT DROP AS
    WITH selected_org AS (
        SELECT id FROM get_descendant_ids(v_facility)
    ),
    quarters AS (
        SELECT (
            date_trunc('quarter', CURRENT_DATE) - interval '6 months' - offs.n * interval '3 months'
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
        LEFT JOIN heart360tk_reporting.heart360_cohort_patient_details c
            ON c.registration_quarter = q.registration_quarter
           AND c.org_unit_id IN (SELECT id FROM selected_org)
        GROUP BY q.registration_quarter
    )
    SELECT
        registration_quarter,
        controlled,
        uncontrolled,
        missed_visit,
        visited_no_bp,
        COALESCE(ROUND(100.0 * controlled / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS controlled_pct,
        COALESCE(ROUND(100.0 * uncontrolled / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS uncontrolled_pct,
        COALESCE(ROUND(100.0 * missed_visit / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS missed_visit_pct,
        COALESCE(ROUND(100.0 * visited_no_bp / NULLIF(controlled + uncontrolled + missed_visit + visited_no_bp, 0), 1), 0) AS visited_no_bp_pct
    FROM counts;

    CREATE TEMP TABLE want_panel (
        registration_quarter timestamp,
        controlled bigint,
        uncontrolled bigint,
        missed_visit bigint,
        visited_no_bp bigint,
        controlled_pct numeric,
        uncontrolled_pct numeric,
        missed_visit_pct numeric,
        visited_no_bp_pct numeric
    );
    INSERT INTO want_panel VALUES
        (c0, 4, 2, 2, 4, 33.3, 16.7, 16.7, 33.3),
        (c1, 1, 1, 1, 0, 33.3, 33.3, 33.3, 0),
        (c0 - interval '6 months', 0, 0, 0, 0, 0, 0, 0, 0),
        (c0 - interval '9 months', 0, 0, 0, 0, 0, 0, 0, 0),
        (c0 - interval '12 months', 0, 0, 0, 0, 0, 0, 0, 0);

    SELECT count(*) INTO v_bad
    FROM (
        SELECT * FROM got_panel
        EXCEPT
        SELECT * FROM want_panel
    ) d;
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'facility panel counts do not match the oracle';
    END IF;

    SELECT count(*) INTO v_bad FROM (
        SELECT registration_quarter FROM want_panel
        EXCEPT
        SELECT registration_quarter FROM got_panel
    ) d;
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'facility panel is missing an oracle quarter';
    END IF;

    PERFORM 1
    FROM heart360tk_reporting.heart360_cohort_patient_details
    WHERE org_unit_id = v_district
      AND patient_id = 910013
      AND status_at_end_of_interval = 'controlled';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'district patient 910013 was not rolled into the snapshot';
    END IF;

    SELECT count(*) INTO v_bad
    FROM heart360tk_reporting.heart360_cohort_patient_details c
    WHERE c.org_unit_id IN (SELECT id FROM get_descendant_ids(v_district))
      AND c.patient_id BETWEEN 910001 AND 910018
      AND c.registration_quarter = c0;
    IF v_bad <> 13 THEN
        RAISE EXCEPTION 'district rollup cohort size for the latest quarter is %', v_bad;
    END IF;

    SELECT count(*) INTO v_bad
    FROM (
        SELECT (
            date_trunc('quarter', CURRENT_DATE) - interval '6 months' - offs.n * interval '3 months'
        ) AS registration_quarter
        FROM generate_series(0, 4) AS offs(n)
    ) q
    LEFT JOIN heart360tk_reporting.heart360_cohort_patient_details c
        ON c.registration_quarter = q.registration_quarter
       AND c.org_unit_id IN (SELECT id FROM get_descendant_ids(v_empty))
    GROUP BY q.registration_quarter
    HAVING COUNT(c.patient_id) <> 0;
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'empty facility is not an all-zero cohort';
    END IF;
END
$panel$;
