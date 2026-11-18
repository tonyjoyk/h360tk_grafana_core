-- 0.6.16_to_0.6.17: one BP readings rule everywhere (UX-25 follow-up), chat home unit (UX-29)
--
-- report_fudging(month, org)  Same signature and columns. It now reads the BP Fudging PRD rule of
--     report_fudging_quarterly instead of the CR-4 3-month 135-139 / 140-144 score, so report_flags,
--     the Start here grid, the chat and the quarterly tab agree.
--       quarter          the newest completed quarter on or before the reporting month (the
--                        is_complete quarter of report_fudging_quarterly with the latest start).
--                        Month 2026-09 -> Q3 2026; 2026-10 and 2026-11 -> Q3 2026; 2026-08 -> Q2 2026.
--       readings_n       every blood_pressures row with a systolic value in that quarter, patient
--                        attributed by patients.org_unit_id (A52).
--       band_135_139_n   visits with 130 <= systolic < 140 in that quarter (column name kept).
--       band_140_144_n   visits with 140 <= systolic < 150 in that quarter (column name kept).
--       too_few          band_135_139_n + band_140_144_n < fudging.min_readings; score NULL.
--       score            round(130-139 / 140-149, 2); NULL when too_few or the 140-149 count is 0.
--       flag             not too_few, and the 140-149 count is 0 or score >= fudging.flag_ratio (2.0).
--       flag_reason      `{x.xx} readings at 130-139 for every 1 at 140-149 in Q3 2026. Check how BP
--                        is measured.` or `No 140-149 readings in Q3 2026. Check how BP is measured.`
--                        (17 and 11 words; no returned string names the internal report).
--       control_pct      unchanged: h360_control_summary for the reporting month (EP-3).
--       looks_fine_check unchanged: flag AND control_pct >= common.high_control_pct.
--     fudging.flag_score is no longer read (its row stays for older dashboards).
-- report_fudging_histogram(month, org)  Same signature, columns and seven bands over the 3-month
--     window (the tab says `last 3 months`). The highlight now marks the PRD bands: 130-134, 135-139,
--     140-144 and 145-149.
-- chat_home_unit(is_admin, team_names)  UX-29: the user's home org unit for the chat at blank scope,
--     the home dashboard's UserOrgUnitId query (dashboard_src/reports/_shared/user_home_unit.sql)
--     clause for clause, with the Grafana user's is_admin and team names passed in by h360-api.
--     Among the units named by `heart360tk_<level>_view_(patients|aggregated)_<name>` teams (not
--     `_ALL`), and every unit at the highest `_ALL` level below the root, the one at the lowest level
--     number, then by name. NULL for an admin or when nothing matches. Granted to h360_api only.
--
-- Report functions are STABLE SECURITY DEFINER, owned by heart360tk, SET jit = off, granted to
-- heart360tk_reader and h360_api. Thresholds come from report_flag_thresholds through h360_threshold.
--
-- One transaction, idempotent, safe to re-run (CREATE OR REPLACE with unchanged return types).
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- report_fudging on the PRD rule (newest completed quarter)
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
        SELECT h360_threshold('common', 'high_control_pct') AS high_control_pct
    ),
    qa AS (
        SELECT * FROM report_fudging_quarterly(p_reporting_month, p_org_unit_id) q WHERE q.is_complete
    ),
    qn AS (
        SELECT * FROM qa WHERE qa.quarter_start = (SELECT max(x.quarter_start) FROM qa x)
    ),
    qd AS (
        SELECT DISTINCT qn.quarter_start, qn.quarter_end FROM qn
    ),
    rd AS (
        SELECT m.report_org_unit_id, count(*) AS readings_n
        FROM qd
        JOIN encounters e
          ON e.encounter_date >= qd.quarter_start
         AND e.encounter_date <  qd.quarter_end + 1
        JOIN blood_pressures bp ON bp.encounter_id = e.id
        JOIN patients p ON p.patient_id = e.patient_id
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = p.org_unit_id
        WHERE bp.systolic_bp IS NOT NULL
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            qn.*,
            COALESCE(rd.readings_n, 0) AS readings_n,
            CASE WHEN NOT qn.too_few THEN qn.ratio END AS score,
            c.controlled_pct AS control_pct
        FROM qn
        LEFT JOIN rd ON rd.report_org_unit_id = qn.org_unit_id
        LEFT JOIN LATERAL h360_control_summary(p_reporting_month, qn.org_unit_id) c ON TRUE
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    )
    SELECT
        r.org_unit_id,
        r.org_unit_name,
        r.level,
        r.is_selected,
        r.too_few,
        r.flag,
        CASE
            WHEN r.flag AND r.n_140_149 = 0 THEN
                'No 140-149 readings in ' || r.quarter_label || '. Check how BP is measured.'
            WHEN r.flag THEN
                r.score::text || ' readings at 130-139 for every 1 at 140-149 in '
                || r.quarter_label || '. Check how BP is measured.'
        END AS flag_reason,
        r.readings_n::bigint,
        r.n_130_139::bigint,
        r.n_140_149::bigint,
        r.score,
        r.control_pct,
        (r.flag AND COALESCE(r.control_pct >= t.high_control_pct, FALSE)) AS looks_fine_check
    FROM r
    JOIN units u ON u.org_unit_id = r.org_unit_id
    CROSS JOIN t
    ORDER BY u.row_order;
$$;

COMMENT ON FUNCTION report_fudging(date, integer) IS
    'BP readings check on the owner''s PRD rule, newest completed quarter on or before the month '
    '(report_fudging_quarterly). Column names are kept from CR-4: band_135_139_n holds visits with '
    'systolic 130-139 and band_140_144_n holds visits with systolic 140-149; score = 130-139 / '
    '140-149, flagged at the flag_ratio threshold (2.0) or more.';

-- ----------------------------------------------------------------------------
-- report_fudging_histogram: seven bands over the 3-month window, PRD bands highlighted
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
        SELECT g AS band_low, g + 4 AS band_high, g BETWEEN 130 AND 145 AS highlight
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

COMMENT ON FUNCTION report_fudging_histogram(date, integer) IS
    'Top BP number of each reading in the 3-month report window, seven 5-point bands 120-124 to '
    '150-154; highlight marks the PRD bands 130-139 and 140-149.';

-- ----------------------------------------------------------------------------
-- UX-29: chat_home_unit, the home dashboard's UserOrgUnitId for h360-api
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chat_home_unit(p_is_admin boolean, p_team_names text[])
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
AS $$
    WITH my_teams AS (
        SELECT t.name
        FROM unnest(COALESCE(p_team_names, ARRAY[]::text[])) AS t(name)
        WHERE NOT COALESCE(p_is_admin, FALSE)
    ),
    specific_units AS (
        SELECT hc.level, ou.id, ou.name
        FROM my_teams mt
        JOIN hierarchy_config hc
          ON mt.name ~ ('^heart360tk_' || hc.var_name || '_view_(patients|aggregated)_')
         AND mt.name NOT LIKE '%\_ALL' ESCAPE '\'
        JOIN org_units ou
          ON ou.level = hc.level
         AND regexp_replace(lower(trim(ou.name)), '\s+', '_', 'g') =
             regexp_replace(mt.name, '^heart360tk_' || hc.var_name || '_view_(patients|aggregated)_', '')
    ),
    all_access_level AS (
        SELECT min(hc.level) AS level
        FROM my_teams mt
        JOIN hierarchy_config hc
          ON mt.name IN ('heart360tk_' || hc.var_name || '_view_patients_ALL',
                         'heart360tk_' || hc.var_name || '_view_aggregated_ALL')
    ),
    all_access_units AS (
        SELECT ou.level, ou.id, ou.name
        FROM all_access_level al
        JOIN org_units ou ON ou.level = al.level
        WHERE al.level > 1
    ),
    candidates AS (
        SELECT * FROM specific_units
        UNION ALL
        SELECT * FROM all_access_units
    )
    SELECT c.id FROM candidates c ORDER BY c.level ASC, c.name ASC LIMIT 1;
$$;

COMMENT ON FUNCTION chat_home_unit(boolean, text[]) IS
    'UX-29: the user''s home org unit for the chat at blank scope, as the home dashboard''s '
    'UserOrgUnitId query (dashboard_src/reports/_shared/user_home_unit.sql). NULL for an admin or '
    'when no team matches. h360_api only.';

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION report_fudging(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_fudging_histogram(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION chat_home_unit(boolean, text[]) FROM PUBLIC;

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
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'h360_api') THEN
        GRANT EXECUTE ON FUNCTION heart360tk_schema.chat_home_unit(boolean, text[]) TO h360_api;
    END IF;
END $$;

COMMIT;
