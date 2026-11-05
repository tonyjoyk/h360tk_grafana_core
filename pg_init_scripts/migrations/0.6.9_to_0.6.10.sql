-- 0.6.9_to_0.6.10: titration report, "Stepping up" (CR-3, AD-26, AD-27, PD-6; story 5.4)
--
-- h360_titration_visits(month, org)  CR-3, one row per uncontrolled visit in the window: its baseline B,
--                                    its next visit within titration.next_visit_days, the exclusion that
--                                    applies (too_recent, no_baseline or NULL) and whether it was stepped up.
-- report_titration(month, org)       CR-3 measures and flag per report row (CLINICAL-RULES section 1), plus
--                                    control_pct (h360_control_summary, HTN tab formula, EP-3) and
--                                    looks_fine_check = flag and control_pct >= common.high_control_pct (PD-6).
--
-- Rules (CR-3):
--   uncontrolled visit v  an encounter in the window (report_window) with a BP row at systolic >= 140 or
--                         diastolic >= 90. A patient counts towards the subtree of patients.org_unit_id (A52).
--   too recent            v::date > data_end - titration.too_recent_days. Checked first: a visit that is both
--                         too recent and without a baseline counts as too recent only.
--   no baseline           B = the patient's latest encounter before v (by encounter_date, then id). No B, or B
--                         is Unrecognized with reason no_prescription or unreadable.
--   candidates            v itself, and the patient's first encounter after v when its date is within
--                         titration.next_visit_days of v's date.
--   step-up over B        both on the ladder: step_no(C) > step_no(B). Otherwise C is not Unrecognized and
--                         n_htn_drugs(C) > n_htn_drugs(B), or equal and dose_units(C) > dose_units(B) (A68).
--   titration_pct         stepped-up visits / remaining uncontrolled visits (uncontrolled_visits_n counts the
--                         remaining visits, after both exclusions).
--   flag                  displayed titration_pct < titration.flag_below_pct, never when too_few
--                         (uncontrolled_visits_n < titration.min_visits).
--
-- h360_titration_visits is an invoker helper owned by heart360tk with no EXECUTE grant (visit level);
-- report_titration is a definer function granted to heart360tk_reader and h360_api.
-- Both SET jit = off (see 0.6.8_to_0.6.9).
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- h360_titration_visits: CR-3 per uncontrolled visit
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h360_titration_visits(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    patient_id            bigint,
    org_unit_id           integer,
    encounter_id          bigint,
    encounter_date        timestamp,
    baseline_encounter_id bigint,
    next_encounter_id     bigint,
    excluded              text,      -- 'too_recent' | 'no_baseline' | NULL
    stepped_up            boolean    -- NULL when excluded
)
LANGUAGE sql
STABLE
ROWS 2000
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH w AS (
        SELECT r.window_start, r.window_end, r.data_end,
               h360_threshold('titration', 'too_recent_days')::integer AS too_recent_days,
               h360_threshold('titration', 'next_visit_days')::integer AS next_visit_days
        FROM report_window(p_reporting_month) r
    ),
    pts AS (
        SELECT p.patient_id, p.org_unit_id
        FROM patients p
        WHERE p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
    ),
    v AS (
        SELECT e.id, e.patient_id, e.encounter_date, pts.org_unit_id
        FROM encounters e
        JOIN pts ON pts.patient_id = e.patient_id
        CROSS JOIN w
        WHERE e.encounter_date >= w.window_start
          AND e.encounter_date <  w.window_end + 1
          AND EXISTS (SELECT 1 FROM blood_pressures bp
                      WHERE bp.encounter_id = e.id
                        AND (bp.systolic_bp >= 140 OR bp.diastolic_bp >= 90))
    ),
    linked AS (
        SELECT
            v.*,
            v.encounter_date::date > w.data_end - w.too_recent_days AS too_recent,
            b.id AS b_id,
            n.id AS n_id
        FROM v
        CROSS JOIN w
        LEFT JOIN LATERAL (
            SELECT e.id
            FROM encounters e
            WHERE e.patient_id = v.patient_id
              AND (e.encounter_date, e.id) < (v.encounter_date, v.id)
            ORDER BY e.encounter_date DESC, e.id DESC
            LIMIT 1
        ) b ON TRUE
        LEFT JOIN LATERAL (
            SELECT x.id
            FROM (
                SELECT e.id, e.encounter_date
                FROM encounters e
                WHERE e.patient_id = v.patient_id
                  AND (e.encounter_date, e.id) > (v.encounter_date, v.id)
                ORDER BY e.encounter_date, e.id
                LIMIT 1
            ) x
            WHERE x.encounter_date::date <= v.encounter_date::date + w.next_visit_days
        ) n ON TRUE
    ),
    classified AS (
        SELECT
            l.*,
            sb.bucket AS b_bucket, sb.reason AS b_reason, sb.step_no AS b_step,
            sb.n_htn_drugs AS b_n, sb.dose_units AS b_dose,
            sv.bucket AS v_bucket, sv.step_no AS v_step, sv.n_htn_drugs AS v_n, sv.dose_units AS v_dose,
            sn.bucket AS n_bucket, sn.step_no AS n_step, sn.n_htn_drugs AS n_n, sn.dose_units AS n_dose
        FROM linked l
        LEFT JOIN LATERAL (SELECT * FROM visit_step s WHERE s.encounter_id = l.b_id) sb ON TRUE
        LEFT JOIN LATERAL (SELECT * FROM visit_step s WHERE s.encounter_id = l.id)   sv ON TRUE
        LEFT JOIN LATERAL (SELECT * FROM visit_step s WHERE s.encounter_id = l.n_id) sn ON TRUE
    ),
    judged AS (
        SELECT
            c.*,
            CASE
                WHEN c.too_recent THEN 'too_recent'
                WHEN c.b_id IS NULL OR c.b_reason IN ('no_prescription', 'unreadable') THEN 'no_baseline'
            END AS excluded,
            -- step-up of candidate C over B (CR-3, A68); a missing next visit is not a step-up
            CASE WHEN c.b_step IS NOT NULL AND c.v_step IS NOT NULL THEN c.v_step > c.b_step
                 ELSE c.v_bucket <> 'Unrecognized'
                      AND (c.v_n > c.b_n OR (c.v_n = c.b_n AND c.v_dose > c.b_dose))
            END AS v_up,
            CASE WHEN c.n_id IS NULL THEN FALSE
                 WHEN c.b_step IS NOT NULL AND c.n_step IS NOT NULL THEN c.n_step > c.b_step
                 ELSE c.n_bucket <> 'Unrecognized'
                      AND (c.n_n > c.b_n OR (c.n_n = c.b_n AND c.n_dose > c.b_dose))
            END AS n_up
        FROM classified c
    )
    SELECT
        j.patient_id,
        j.org_unit_id,
        j.id,
        j.encounter_date,
        j.b_id,
        j.n_id,
        j.excluded,
        CASE WHEN j.excluded IS NULL THEN COALESCE(j.v_up, FALSE) OR COALESCE(j.n_up, FALSE) END
    FROM judged j;
$$;

-- ----------------------------------------------------------------------------
-- report_titration (CLINICAL-RULES section 1 columns; PD-6 adds control_pct, looks_fine_check)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_titration(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id            integer,
    org_unit_name          text,
    level                  integer,
    is_selected            boolean,
    too_few                boolean,
    flag                   boolean,
    flag_reason            text,
    uncontrolled_visits_n  bigint,
    stepped_up_n           bigint,
    titration_pct          numeric,
    excluded_too_recent_n  bigint,
    excluded_no_baseline_n bigint,
    control_pct            numeric,
    looks_fine_check       boolean
)
LANGUAGE sql
STABLE
ROWS 10
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('titration', 'min_visits')     AS min_visits,
               h360_threshold('titration', 'flag_below_pct') AS flag_below_pct,
               h360_threshold('common', 'high_control_pct')  AS high_control_pct
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*) FILTER (WHERE v.excluded IS NULL)           AS uncontrolled_visits_n,
            count(*) FILTER (WHERE v.stepped_up)                 AS stepped_up_n,
            count(*) FILTER (WHERE v.excluded = 'too_recent')    AS excluded_too_recent_n,
            count(*) FILTER (WHERE v.excluded = 'no_baseline')   AS excluded_no_baseline_n
        FROM h360_titration_visits(p_reporting_month, p_org_unit_id) v
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = v.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.uncontrolled_visits_n, 0)  AS uncontrolled_visits_n,
            COALESCE(g.stepped_up_n, 0)           AS stepped_up_n,
            round(100.0 * g.stepped_up_n / NULLIF(g.uncontrolled_visits_n, 0), 1) AS titration_pct,
            COALESCE(g.excluded_too_recent_n, 0)  AS excluded_too_recent_n,
            COALESCE(g.excluded_no_baseline_n, 0) AS excluded_no_baseline_n,
            cs.controlled_pct                     AS control_pct
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
        LEFT JOIN LATERAL h360_control_summary(p_reporting_month, u.org_unit_id) cs ON TRUE
    ),
    f AS (
        SELECT
            r.*,
            r.uncontrolled_visits_n < t.min_visits AS too_few,
            COALESCE(r.titration_pct < t.flag_below_pct, FALSE) AS low,
            t.high_control_pct
        FROM r CROSS JOIN t
    )
    SELECT
        f.org_unit_id,
        f.org_unit_name,
        f.level,
        f.is_selected,
        f.too_few,
        (NOT f.too_few AND f.low) AS flag,
        CASE WHEN NOT f.too_few AND f.low THEN
            'Medicine rarely stepped up: ' || to_char(f.titration_pct, 'FM9990.0') || '% of '
            || f.uncontrolled_visits_n || ' high BP visits.'
        END AS flag_reason,
        f.uncontrolled_visits_n::bigint,
        f.stepped_up_n::bigint,
        f.titration_pct,
        f.excluded_too_recent_n::bigint,
        f.excluded_no_baseline_n::bigint,
        f.control_pct,
        (NOT f.too_few AND f.low AND COALESCE(f.control_pct >= f.high_control_pct, FALSE)) AS looks_fine_check
    FROM f
    ORDER BY f.row_order;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION h360_titration_visits(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_titration(date, integer) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_titration(date, integer) TO %I', v_role);
        END IF;
    END LOOP;
END $$;

COMMIT;
