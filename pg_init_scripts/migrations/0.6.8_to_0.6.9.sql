-- 0.6.8_to_0.6.9: report common + protocol adherence (AD-26, AD-27, CR-2; stories 5.1 and 5.7)
--
-- report_window(month)              the only period source (AD-26). Granted to heart360tk_reader, h360_api.
-- report_flag_thresholds            every threshold and minimum (CLINICAL-RULES section 2). No report,
--                                   panel or API code holds a threshold literal; read it with h360_threshold.
-- h360_threshold(report, key)       one threshold value; raises if the row is missing.
-- h360_report_units(org)            the report rows: the selection (or `All places in view`, id 0) then one
--                                   row per facility (hierarchy_config var_name 'facility') in the subtree
--                                   when the selection is above facility level.
-- h360_report_member(org)           which report row(s) each org unit in the subtree counts towards. A patient
--                                   belongs to the subtree of patients.org_unit_id (A52); level 4 rolls up to
--                                   its facility.
-- h360_control_summary(month, org)  HTN tab BP control for a node and month (EP-3), from
--                                   heart360tk_reporting.heart360_patients_category, exactly as the program
--                                   dashboard's `Hypertension treatment outcomes` panel computes it.
-- h360_adherence_patients(...)      CR-2 cohort, one row per patient with the bucket of the latest visit.
-- report_adherence(month, org, include_new)          CR-2 measures and flags per report row.
-- report_adherence_buckets(month, org, include_new)  selection only: nine bucket rows.
--
-- The adherence functions SET jit = off: set-returning functions are costed at 1000 rows, so their
-- plans pass jit_above_cost and JIT compilation alone took about 0.5 s per call on the demo data.
--
-- The h360_* helpers are invoker functions owned by heart360tk with no EXECUTE grant: the report_* and
-- chat_* definer functions call them as heart360tk. None is in the verify_security.sh allowlist.
--
-- One transaction, idempotent, safe to re-run. Threshold rows are inserted ON CONFLICT DO NOTHING so a
-- re-run never resets a tuned value.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- report_flag_thresholds (AD-27, CLINICAL-RULES section 2)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS report_flag_thresholds (
    report TEXT    NOT NULL,
    key    TEXT    NOT NULL,
    value  NUMERIC NOT NULL,
    PRIMARY KEY (report, key)
);

-- Sources: A36, A37, A38, A4, A5, A19, A20, A21, A57, FR-47, the overdue list.
INSERT INTO report_flag_thresholds (report, key, value) VALUES
    ('common',       'high_control_pct',        60),
    ('adherence',    'min_cohort',              20),
    ('adherence',    'off_protocol_pct',        20),
    ('adherence',    'one_medicine_pct',        60),
    ('titration',    'min_visits',              10),
    ('titration',    'flag_below_pct',          40),
    ('titration',    'next_visit_days',         30),
    ('titration',    'too_recent_days',         30),
    ('fudging',      'min_readings',            20),
    ('fudging',      'flag_score',              2.0),
    ('statins',      'min_eligible',            10),
    ('statins',      'flag_below_pct',          25),
    ('statins',      'min_age',                 40),
    ('calling',      'min_overdue_phone',       10),
    ('calling',      'overdue_days',            45),
    ('calling',      'called_below_pct',        10),
    ('calling',      'early_days',              14),
    ('calling',      'early_below_pct',         50),
    ('calling',      'return_days',             30),
    ('new_patients', 'phone_below_pct',         50),
    ('chat',         'new_loss_above_pct',      25),
    ('chat',         'usable_phone_below_pct',  90),
    ('chat',         'called_below_pct',        10),
    ('chat',         'early_below_pct',         50),
    ('chat',         'titration_below_pct',     40),
    ('chat',         'stock_days_below',        30),
    ('chattogram',   'control_below_pct',       50),
    ('chattogram',   'uncontrolled_above_pct',  20),
    ('chattogram',   'missed_visit_above_pct',  25),
    ('chattogram',   'ltfu_above_pct',          20)
ON CONFLICT (report, key) DO NOTHING;

CREATE OR REPLACE FUNCTION h360_threshold(p_report text, p_key text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
DECLARE
    v_value numeric;
BEGIN
    SELECT t.value INTO v_value
    FROM report_flag_thresholds t
    WHERE t.report = p_report AND t.key = p_key;
    IF v_value IS NULL THEN
        RAISE EXCEPTION 'report_flag_thresholds has no row (%, %)', p_report, p_key;
    END IF;
    RETURN v_value;
END;
$$;

-- ----------------------------------------------------------------------------
-- report_window (AD-26)
--   window_end   last day of the reporting month; NULL month = the latest completed month
--   window_start window_end - 89 (90 days inclusive)
--   data_end     newest encounter_date::date on or before window_end
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_window(p_reporting_month date)
RETURNS TABLE (window_start date, window_end date, data_end date)
LANGUAGE sql
STABLE
ROWS 1
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
AS $$
    SELECT
        w.window_end - 89,
        w.window_end,
        (SELECT max(e.encounter_date)::date
         FROM encounters e
         WHERE e.encounter_date < w.window_end + 1)
    FROM (
        SELECT (date_trunc('month', COALESCE(p_reporting_month::timestamp,
                                             date_trunc('month', current_date::timestamp) - interval '1 month'))
                + interval '1 month' - interval '1 day')::date AS window_end
    ) w;
$$;

-- ----------------------------------------------------------------------------
-- Report rows (AD-27) and attribution (AD-26)
-- ----------------------------------------------------------------------------
-- Rows: the selection first (row_order 0), then facilities by name. 0 or NULL selects
-- `All places in view` (org_unit_id 0, level 0). An unknown id gives no rows.
CREATE OR REPLACE FUNCTION h360_report_units(p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, org_unit_name text, level integer, is_selected boolean, row_order integer)
LANGUAGE sql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
    WITH fac AS (
        SELECT hc.level FROM hierarchy_config hc WHERE hc.var_name = 'facility'
    ),
    sel AS (
        SELECT 0 AS id, 'All places in view'::text AS name, 0 AS level
        WHERE COALESCE(p_org_unit_id, 0) = 0
        UNION ALL
        SELECT ou.id, ou.name::text, ou.level
        FROM org_units ou
        WHERE COALESCE(p_org_unit_id, 0) <> 0 AND ou.id = p_org_unit_id
    )
    SELECT s.id, s.name, s.level, TRUE, 0
    FROM sel s
    UNION ALL
    SELECT ou.id, ou.name::text, ou.level, FALSE,
           row_number() OVER (ORDER BY ou.name, ou.id)::integer
    FROM sel s
    CROSS JOIN fac
    JOIN org_units ou
      ON ou.level = fac.level
     AND ou.id IN (SELECT d.id FROM get_descendant_ids(NULLIF(s.id, 0)) d)
    WHERE s.level < fac.level;
$$;

-- One row per (org unit in the subtree, report row it counts towards). Every org unit in
-- the subtree counts towards the selection row; one at or below a facility also counts
-- towards that facility's row when facility rows are shown.
CREATE OR REPLACE FUNCTION h360_report_member(p_org_unit_id integer)
RETURNS TABLE (member_org_unit_id integer, report_org_unit_id integer)
LANGUAGE sql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
    WITH units AS (
        SELECT u.org_unit_id, u.is_selected FROM h360_report_units(p_org_unit_id) u
    ),
    scope AS (
        SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d
        WHERE EXISTS (SELECT 1 FROM units)
    )
    SELECT s.id, u.org_unit_id
    FROM scope s
    CROSS JOIN units u
    WHERE u.is_selected
    UNION ALL
    SELECT l.org_unit_id, l.ancestor_id
    FROM org_unit_lineage l
    JOIN units u ON u.org_unit_id = l.ancestor_id AND NOT u.is_selected
    WHERE l.org_unit_id IN (SELECT s.id FROM scope s);
$$;

-- ----------------------------------------------------------------------------
-- h360_control_summary (EP-3): HTN tab BP control for a node and month.
-- Same formula as the program dashboard (`Hypertension treatment outcomes`, `% 12 month lost
-- to follow-up`) on the cached reporting table:
--   under_care_n     = total - newly registered - lost to follow-up (GREATEST 0)
--   controlled_pct   = controlled / under_care_n
--   uncontrolled_pct = uncontrolled / under_care_n
--   missed_visit_pct = no visit in 3 months / under_care_n
--   ltfu_pct         = lost to follow-up / total
-- ref_month = the reporting month (NULL = latest completed month, as report_window).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h360_control_summary(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    ref_month          date,
    total_n            bigint,
    newly_registered_n bigint,
    ltfu_n             bigint,
    under_care_n       bigint,
    controlled_n       bigint,
    uncontrolled_n     bigint,
    no_visit_n         bigint,
    controlled_pct     numeric,
    uncontrolled_pct   numeric,
    missed_visit_pct   numeric,
    ltfu_pct           numeric
)
LANGUAGE sql
STABLE
ROWS 1
SET search_path = heart360tk_schema, pg_temp
AS $$
    WITH m AS (
        SELECT date_trunc('month', w.window_end)::date AS ref_month
        FROM report_window(p_reporting_month) w
    ),
    s AS (
        SELECT
            m.ref_month,
            COALESCE(sum(c.total_number_of_patients), 0)::bigint      AS total_n,
            COALESCE(sum(c.nb_patients_newly_registered), 0)::bigint  AS newly_registered_n,
            COALESCE(sum(c.nb_patients_lost_to_follow_up), 0)::bigint AS ltfu_n,
            GREATEST(0, COALESCE(sum(c.total_number_of_patients), 0)
                        - COALESCE(sum(c.nb_patients_newly_registered), 0)
                        - COALESCE(sum(c.nb_patients_lost_to_follow_up), 0))::bigint AS under_care_n,
            COALESCE(sum(c.nb_patients_controlled), 0)::bigint        AS controlled_n,
            COALESCE(sum(c.nb_patients_uncontrolled), 0)::bigint      AS uncontrolled_n,
            COALESCE(sum(c.nb_patients_no_visit), 0)::bigint          AS no_visit_n
        FROM m
        LEFT JOIN heart360tk_reporting.heart360_patients_category c
               ON c.ref_month = m.ref_month
              AND c.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
        GROUP BY m.ref_month
    )
    SELECT
        s.ref_month, s.total_n, s.newly_registered_n, s.ltfu_n, s.under_care_n,
        s.controlled_n, s.uncontrolled_n, s.no_visit_n,
        round(100.0 * s.controlled_n   / NULLIF(s.under_care_n, 0), 1),
        round(100.0 * s.uncontrolled_n / NULLIF(s.under_care_n, 0), 1),
        round(100.0 * s.no_visit_n     / NULLIF(s.under_care_n, 0), 1),
        round(100.0 * s.ltfu_n         / NULLIF(s.total_n, 0), 1)
    FROM s;
$$;

-- ----------------------------------------------------------------------------
-- Protocol adherence (CR-2)
-- ----------------------------------------------------------------------------
-- Cohort: alive, diagnosis I10, at least one encounter in the window, in the subtree.
-- Registration = the patient's earliest encounter; strict keeps registration < window_start.
-- One row per patient: the bucket of the latest encounter in the window, and whether that
-- encounter's BP is controlled (< 140 and < 90; no BP row = not controlled).
CREATE OR REPLACE FUNCTION h360_adherence_patients(p_reporting_month date, p_org_unit_id integer,
                                                   p_include_new boolean)
RETURNS TABLE (
    patient_id    bigint,
    org_unit_id   integer,
    encounter_id  bigint,
    bucket        text,
    bucket_order  integer,
    step_no       integer,
    controlled    boolean
)
LANGUAGE sql
STABLE
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH w AS (
        SELECT * FROM report_window(p_reporting_month)
    ),
    cohort AS (
        SELECT p.patient_id, p.org_unit_id
        FROM patients p
        WHERE p.patient_status IS DISTINCT FROM 'DEAD'
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
          AND EXISTS (SELECT 1 FROM patient_diagnoses pd
                      WHERE pd.patient_id = p.patient_id AND pd.diagnosis_code = 'I10')
    ),
    latest AS (
        SELECT DISTINCT ON (e.patient_id) e.patient_id, e.id
        FROM encounters e
        JOIN cohort c ON c.patient_id = e.patient_id
        CROSS JOIN w
        WHERE e.encounter_date >= w.window_start
          AND e.encounter_date <  w.window_end + 1
        ORDER BY e.patient_id, e.encounter_date DESC, e.id DESC
    ),
    registered AS (
        SELECT e.patient_id, min(e.encounter_date)::date AS registration_date
        FROM encounters e
        WHERE e.patient_id IN (SELECT l.patient_id FROM latest l)
        GROUP BY e.patient_id
    )
    SELECT
        c.patient_id,
        c.org_unit_id,
        l.id,
        v.bucket,
        v.bucket_order,
        v.step_no,
        COALESCE(bp.systolic_bp < 140 AND bp.diastolic_bp < 90, FALSE)
    FROM latest l
    JOIN cohort c ON c.patient_id = l.patient_id
    JOIN registered r ON r.patient_id = l.patient_id
    JOIN visit_step v ON v.encounter_id = l.id
    LEFT JOIN blood_pressures bp ON bp.encounter_id = l.id
    CROSS JOIN w
    WHERE COALESCE(p_include_new, FALSE) OR r.registration_date < w.window_start;
$$;

-- Columns: CLINICAL-RULES section 1. Flags compare the displayed (1 decimal) percent with
-- report_flag_thresholds; too_few (cohort < adherence.min_cohort) forces flag = false.
CREATE OR REPLACE FUNCTION report_adherence(p_reporting_month date, p_org_unit_id integer,
                                            p_include_new boolean DEFAULT false)
RETURNS TABLE (
    org_unit_id      integer,
    org_unit_name    text,
    level            integer,
    is_selected      boolean,
    too_few          boolean,
    flag             boolean,
    flag_reason      text,
    cohort_n         bigint,
    controlled_n     bigint,
    controlled_pct   numeric,
    off_protocol_pct numeric,
    one_medicine_pct numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('adherence', 'min_cohort')       AS min_cohort,
               h360_threshold('adherence', 'off_protocol_pct') AS off_protocol_pct,
               h360_threshold('adherence', 'one_medicine_pct') AS one_medicine_pct
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*)                                                         AS cohort_n,
            count(*) FILTER (WHERE a.controlled)                             AS controlled_n,
            count(*) FILTER (WHERE a.bucket IN ('Non-Protocol', 'Other Protocol')) AS off_protocol_n,
            count(*) FILTER (WHERE a.step_no IN (1, 2))                      AS one_medicine_n
        FROM h360_adherence_patients(p_reporting_month, p_org_unit_id, p_include_new) a
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = a.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.cohort_n, 0)     AS cohort_n,
            COALESCE(g.controlled_n, 0) AS controlled_n,
            round(100.0 * g.controlled_n   / NULLIF(g.cohort_n, 0), 1) AS controlled_pct,
            round(100.0 * g.off_protocol_n / NULLIF(g.cohort_n, 0), 1) AS off_protocol_pct,
            round(100.0 * g.one_medicine_n / NULLIF(g.cohort_n, 0), 1) AS one_medicine_pct
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
    ),
    f AS (
        SELECT
            r.*,
            r.cohort_n < t.min_cohort AS too_few,
            r.off_protocol_pct >= t.off_protocol_pct AS off_hit,
            r.one_medicine_pct >= t.one_medicine_pct AS one_hit
        FROM r CROSS JOIN t
    )
    SELECT
        f.org_unit_id,
        f.org_unit_name,
        f.level,
        f.is_selected,
        f.too_few,
        (NOT f.too_few AND (COALESCE(f.off_hit, FALSE) OR COALESCE(f.one_hit, FALSE))) AS flag,
        CASE WHEN NOT f.too_few THEN
            NULLIF(concat_ws(' ',
                CASE WHEN f.off_hit THEN 'Many patients are on medicines outside the protocol: '
                                         || to_char(f.off_protocol_pct, 'FM9990.0') || '%.' END,
                CASE WHEN f.one_hit THEN 'Most patients stay on one medicine: '
                                         || to_char(f.one_medicine_pct, 'FM9990.0') || '%.' END), '')
        END AS flag_reason,
        f.cohort_n::bigint,
        f.controlled_n::bigint,
        f.controlled_pct,
        f.off_protocol_pct,
        f.one_medicine_pct
    FROM f
    ORDER BY f.row_order;
$$;

-- Selection only: nine rows, bucket_order 1-9 (none for an unknown org unit). Step labels come from htn_ladder_steps.label (C16).
CREATE OR REPLACE FUNCTION report_adherence_buckets(p_reporting_month date, p_org_unit_id integer,
                                                    p_include_new boolean DEFAULT false)
RETURNS TABLE (
    bucket         text,
    bucket_order   integer,
    label          text,
    patients_n     bigint,
    controlled_n   bigint,
    controlled_pct numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH buckets AS (
        SELECT 'Step ' || g AS bucket, g AS bucket_order,
               COALESCE((SELECT (array_agg(s.label ORDER BY s.ccb_level, s.raas_level, s.thz_level))[1]
                         FROM htn_ladder_steps s WHERE s.step_no = g),
                        'Step ' || g) AS label
        FROM generate_series(1, 6) g
        UNION ALL
        SELECT * FROM (VALUES
            ('Other Protocol', 7, 'Other protocol combination'),
            ('Non-Protocol',   8, 'Medicine outside the protocol'),
            ('Unrecognized',   9, 'Could not read the entry')
        ) v(bucket, bucket_order, label)
    ),
    agg AS (
        SELECT a.bucket_order,
               count(*)                             AS patients_n,
               count(*) FILTER (WHERE a.controlled) AS controlled_n
        FROM h360_adherence_patients(p_reporting_month, p_org_unit_id, p_include_new) a
        GROUP BY a.bucket_order
    )
    SELECT
        b.bucket,
        b.bucket_order,
        b.label,
        COALESCE(g.patients_n, 0)::bigint,
        COALESCE(g.controlled_n, 0)::bigint,
        round(100.0 * g.controlled_n / NULLIF(g.patients_n, 0), 1)
    FROM buckets b
    LEFT JOIN agg g ON g.bucket_order = b.bucket_order
    WHERE EXISTS (SELECT 1 FROM h360_report_units(p_org_unit_id))   -- unknown org unit: no rows
    ORDER BY b.bucket_order;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE report_flag_thresholds FROM PUBLIC;

REVOKE ALL ON FUNCTION h360_threshold(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION h360_report_units(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION h360_report_member(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION h360_control_summary(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION h360_adherence_patients(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_window(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_adherence(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_adherence_buckets(date, integer, boolean) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader') THEN
        EXECUTE 'GRANT SELECT ON TABLE heart360tk_schema.report_flag_thresholds TO heart360tk_reader';
    END IF;

    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_window(date) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_adherence(date, integer, boolean) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_adherence_buckets(date, integer, boolean) TO %I', v_role);
        END IF;
    END LOOP;
END $$;

COMMIT;
