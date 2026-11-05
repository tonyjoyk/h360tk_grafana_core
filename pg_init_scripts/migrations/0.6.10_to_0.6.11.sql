-- 0.6.10_to_0.6.11: BP readings check (CR-4; stories 5.2 and 5.3)
--
-- h360_bp_readings(month, org)            invoker helper: one row per blood_pressures row of an encounter in
--                                         the AD-26 window, for patients in the subtree (attribution by
--                                         patients.org_unit_id, A52). No EXECUTE grant.
-- report_fudging(month, org)              per report row: readings_n, band_135_139_n (a), band_140_144_n (b),
--                                         score = round(a / b, 2), control_pct (h360_control_summary, EP-3),
--                                         looks_fine_check = flag AND control_pct >= common.high_control_pct.
-- report_fudging_histogram(month, org)    selection only: seven systolic bands 120-124 ... 150-154,
--                                         highlight on 135-139 and 140-144.
--
-- Cases (CR-4, thresholds from report_flag_thresholds via h360_threshold):
--   a + b < fudging.min_readings  too_few, no score, flag false
--   b = 0                         score NULL, flag true, `No 140-144 readings. Check how BP is measured.`
--   otherwise                     flag when the displayed score (2 decimals) >= fudging.flag_score,
--                                 `{x.xx} readings just under 140 for every 1 just over. Check how BP is measured.`
-- Wording follows PD-5 (party mode, decision 5); no returned string contains the internal report name.
-- Bands are half-open on the numeric systolic value: 135-139 means 135 <= systolic < 140.
-- Cut 6 (A39) would make the histogram return only the two highlighted bands; this build returns all seven.
--
-- Report functions are definer, STABLE, SET jit = off (set-returning functions cost 1000 rows and pass
-- jit_above_cost otherwise), granted to heart360tk_reader and h360_api only.
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- Readings in the window, attributed to the patient's org unit
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h360_bp_readings(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (org_unit_id integer, systolic_bp numeric)
LANGUAGE sql
STABLE
ROWS 5000
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    SELECT p.org_unit_id, bp.systolic_bp
    FROM report_window(p_reporting_month) w
    JOIN encounters e
      ON e.encounter_date >= w.window_start
     AND e.encounter_date <  w.window_end + 1
    JOIN blood_pressures bp ON bp.encounter_id = e.id
    JOIN patients p ON p.patient_id = e.patient_id
    WHERE bp.systolic_bp IS NOT NULL
      AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d);
$$;

-- ----------------------------------------------------------------------------
-- report_fudging (CR-4, CLINICAL-RULES section 1)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_fudging(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id      integer,
    org_unit_name    text,
    level            integer,
    is_selected      boolean,
    too_few          boolean,
    flag             boolean,
    flag_reason      text,
    readings_n       bigint,
    band_135_139_n   bigint,
    band_140_144_n   bigint,
    score            numeric,
    control_pct      numeric,
    looks_fine_check boolean
)
LANGUAGE sql
STABLE
ROWS 10
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('fudging', 'min_readings')    AS min_readings,
               h360_threshold('fudging', 'flag_score')      AS flag_score,
               h360_threshold('common', 'high_control_pct') AS high_control_pct
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*)                                                          AS readings_n,
            count(*) FILTER (WHERE r.systolic_bp >= 135 AND r.systolic_bp < 140) AS a,
            count(*) FILTER (WHERE r.systolic_bp >= 140 AND r.systolic_bp < 145) AS b
        FROM h360_bp_readings(p_reporting_month, p_org_unit_id) r
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = r.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.readings_n, 0) AS readings_n,
            COALESCE(g.a, 0)          AS a,
            COALESCE(g.b, 0)          AS b,
            c.controlled_pct          AS control_pct
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
        LEFT JOIN LATERAL h360_control_summary(p_reporting_month, u.org_unit_id) c ON TRUE
    ),
    f AS (
        SELECT
            r.*,
            (r.a + r.b) < t.min_readings AS too_few,
            CASE WHEN (r.a + r.b) >= t.min_readings AND r.b > 0
                 THEN round(r.a::numeric / r.b, 2) END AS score,
            t.flag_score,
            t.high_control_pct
        FROM r CROSS JOIN t
    ),
    g AS (
        SELECT
            f.*,
            (NOT f.too_few AND (f.b = 0 OR f.score >= f.flag_score)) AS flag
        FROM f
    )
    SELECT
        g.org_unit_id,
        g.org_unit_name,
        g.level,
        g.is_selected,
        g.too_few,
        g.flag,
        CASE
            WHEN g.flag AND g.b = 0 THEN 'No 140-144 readings. Check how BP is measured.'
            WHEN g.flag THEN g.score::text || ' readings just under 140 for every 1 just over. Check how BP is measured.'
        END AS flag_reason,
        g.readings_n::bigint,
        g.a::bigint,
        g.b::bigint,
        g.score,
        g.control_pct,
        (g.flag AND COALESCE(g.control_pct >= g.high_control_pct, FALSE)) AS looks_fine_check
    FROM g
    ORDER BY g.row_order;
$$;

-- ----------------------------------------------------------------------------
-- report_fudging_histogram (CR-4, A39): selection only, seven bands; none for an unknown org unit.
-- The two highlighted counts equal band_135_139_n and band_140_144_n of the report_fudging selection row.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_fudging_histogram(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    band_low   integer,
    band_high  integer,
    readings_n bigint,
    highlight  boolean
)
LANGUAGE sql
STABLE
ROWS 7
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH bands AS (
        SELECT g AS band_low, g + 4 AS band_high, g IN (135, 140) AS highlight
        FROM generate_series(120, 150, 5) g
    ),
    agg AS (
        SELECT b.band_low, count(r.systolic_bp) AS readings_n
        FROM bands b
        LEFT JOIN h360_bp_readings(p_reporting_month, p_org_unit_id) r
               ON r.systolic_bp >= b.band_low AND r.systolic_bp < b.band_low + 5
        GROUP BY b.band_low
    )
    SELECT b.band_low, b.band_high, COALESCE(a.readings_n, 0)::bigint, b.highlight
    FROM bands b
    LEFT JOIN agg a ON a.band_low = b.band_low
    WHERE EXISTS (SELECT 1 FROM h360_report_units(p_org_unit_id))   -- unknown org unit: no rows
    ORDER BY b.band_low;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION h360_bp_readings(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_fudging(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_fudging_histogram(date, integer) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_fudging(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_fudging_histogram(date, integer) TO %I', v_role);
        END IF;
    END LOOP;
END $$;

COMMIT;
