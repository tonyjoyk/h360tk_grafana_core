-- 0.6.13_to_0.6.14: chat levers and report_flags (AD-27, AD-30, AD-31; stories 5.10, 6.1 and 6.2)
--
-- report_flags(month, org)                 the flags of the five reports in one list (AD-27, A35, EP-4,
--                                          EP-13): org_unit_id, org_unit_name, report, flag_reason, patients_n.
-- chat_control_summary(month, org)         HTN tab control per report row (EP-3): h360_control_summary for
--                                          the selection, then one row per facility when above facility.
-- chat_drug_stock_gate(month, org)         Patient-Days per protocol stock category for the place-month
--                                          (AD-22 All row) and whether it is under chat.stock_days_below.
-- chat_call_plan(month, org)               overdue with a usable phone at the start of the month, split over
--                                          four weeks (CR-6, EP-10).
-- chat_facility_rank_district(month, org)  facilities ranked by uncontrolled patients, with the Chattogram
--                                          lines they breach and the AD-31 "Also check" mark.
--
-- report_flags
--   Rows       facility rows only (EP-13): rows whose level is the facility level (hierarchy_config
--              var_name 'facility') or deeper, so a facility or sub-facility selection gives its own row and
--              a district or `All places in view` selection gives only the facility rows.
--   report     adherence, titration, fudging, statins, calling. The new-patient usable-phone flag
--              (report_new_patients) is shown on the Overdue calls tab (EP-12), so it is listed as
--              `calling`. One row per (facility, report): when both the calling flag and the new-patient
--              phone flag hit, the reasons are joined with a space, calling first.
--   patients_n under-care patients of the row's org unit (h360_control_summary.under_care_n, EP-4).
--   Stubs      a cut report (PD-2, comment h360:stub) returns zero rows with the same columns, so it adds
--              no flags and the other reports still come through.
--   Order      org_unit_name, org_unit_id, then report in the order above.
--
-- chat_control_summary
--   Columns    the AD-27 standard columns without flag and flag_reason (CLINICAL-RULES section 1), then
--              under_care_n, controlled_n, controlled_pct, uncontrolled_n, uncontrolled_pct,
--              missed_visit_pct, ltfu_pct. Equal to h360_control_summary, so equal to control_pct of
--              report_fudging and report_titration for the same place and month.
--   too_few    under_care_n = 0 (no data). CLINICAL-RULES section 2 has no minimum for control.
--
-- chat_drug_stock_gate
--   Scope      the selection; a node below facility level uses its facility ancestor (AD-30 scope).
--   Month      the first day of the report_window month (NULL = latest completed month).
--   Source     heart360tk_reporting.drug_stock_patient_days_all (0.6.6_to_0.6.7): the stock board's All
--              row, one row per stock-tracked category (CCB, ARB, Diuretic).
--   patient_days rounded to 1 decimal; NULL when the category is unknown (A50) or no facility reported.
--   low        displayed patient_days < chat.stock_days_below; false when patient_days is NULL.
--
-- chat_call_plan
--   One row, the selection: n = overdue_with_phone_n and c = calls_per_week (= ceil(n/4)) from
--   report_calling. week_k = LEAST(c, GREATEST(n - (k - 1) * c, 0)) (EP-10), so the weeks sum to n:
--   86 gives 22, 22, 22, 20.
--
-- chat_facility_rank_district
--   Rows       the facility rows of chat_control_summary (as report_flags), every facility in scope,
--              whether or not it breaches; the ranker filters (AD-31 `visit_first`).
--   breaches   the chattogram threshold keys hit, in this order, on the displayed (1 decimal) percents:
--              control_below_pct (controlled_pct < 50), uncontrolled_above_pct (> 20),
--              missed_visit_above_pct (> 25), ltfu_above_pct (> 20). Empty array when none.
--   also_check controlled_pct >= common.high_control_pct and a fudging or titration row in report_flags.
--   rank       1.. by uncontrolled_n descending, then org_unit_name, org_unit_id.
--
-- All five are STABLE SECURITY DEFINER, owned by heart360tk, SET jit = off (see 0.6.8_to_0.6.9).
-- Grants (grant matrix): report_flags to heart360tk_reader and h360_api; chat_* to h360_api only.
-- Thresholds come from report_flag_thresholds through h360_threshold; no literal in this file.
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- report_flags (story 5.10)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_flags(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id   integer,
    org_unit_name text,
    report        text,
    flag_reason   text,
    patients_n    bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH fac AS (
        SELECT hc.level FROM hierarchy_config hc WHERE hc.var_name = 'facility'
    ),
    f AS (
        SELECT 1 AS report_order, 1 AS reason_order, 'adherence'::text AS report,
               r.org_unit_id, r.org_unit_name, r.level, r.flag_reason
        FROM report_adherence(p_reporting_month, p_org_unit_id) r WHERE r.flag
        UNION ALL
        SELECT 2, 1, 'titration', r.org_unit_id, r.org_unit_name, r.level, r.flag_reason
        FROM report_titration(p_reporting_month, p_org_unit_id) r WHERE r.flag
        UNION ALL
        SELECT 3, 1, 'fudging', r.org_unit_id, r.org_unit_name, r.level, r.flag_reason
        FROM report_fudging(p_reporting_month, p_org_unit_id) r WHERE r.flag
        UNION ALL
        SELECT 4, 1, 'statins', r.org_unit_id, r.org_unit_name, r.level, r.flag_reason
        FROM report_statins(p_reporting_month, p_org_unit_id) r WHERE r.flag
        UNION ALL
        SELECT 5, 1, 'calling', r.org_unit_id, r.org_unit_name, r.level, r.flag_reason
        FROM report_calling(p_reporting_month, p_org_unit_id) r WHERE r.flag
        UNION ALL
        -- new-patient usable phone: shown on the Overdue calls tab (EP-12)
        SELECT 5, 2, 'calling', r.org_unit_id, r.org_unit_name, r.level, r.flag_reason
        FROM report_new_patients(p_reporting_month, p_org_unit_id) r WHERE r.flag
    ),
    g AS (
        SELECT
            f.org_unit_id,
            min(f.org_unit_name)                                  AS org_unit_name,
            f.report,
            min(f.report_order)                                   AS report_order,
            string_agg(f.flag_reason, ' ' ORDER BY f.reason_order) AS flag_reason
        FROM f
        CROSS JOIN fac
        WHERE f.level >= fac.level
        GROUP BY f.org_unit_id, f.report
    )
    SELECT g.org_unit_id, g.org_unit_name, g.report, g.flag_reason, c.under_care_n
    FROM g
    LEFT JOIN LATERAL h360_control_summary(p_reporting_month, g.org_unit_id) c ON TRUE
    ORDER BY g.org_unit_name, g.org_unit_id, g.report_order;
$$;

-- ----------------------------------------------------------------------------
-- chat_control_summary (story 6.1, EP-3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chat_control_summary(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id      integer,
    org_unit_name    text,
    level            integer,
    is_selected      boolean,
    too_few          boolean,
    under_care_n     bigint,
    controlled_n     bigint,
    controlled_pct   numeric,
    uncontrolled_n   bigint,
    uncontrolled_pct numeric,
    missed_visit_pct numeric,
    ltfu_pct         numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    SELECT
        u.org_unit_id,
        u.org_unit_name,
        u.level,
        u.is_selected,
        COALESCE(c.under_care_n, 0) = 0 AS too_few,
        c.under_care_n,
        c.controlled_n,
        c.controlled_pct,
        c.uncontrolled_n,
        c.uncontrolled_pct,
        c.missed_visit_pct,
        c.ltfu_pct
    FROM h360_report_units(p_org_unit_id) u
    LEFT JOIN LATERAL h360_control_summary(p_reporting_month, u.org_unit_id) c ON TRUE
    ORDER BY u.row_order;
$$;

-- ----------------------------------------------------------------------------
-- chat_drug_stock_gate (story 6.1, AD-31 stock gate)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chat_drug_stock_gate(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id  integer,
    category     text,
    patient_days numeric,
    low          boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('chat', 'stock_days_below') AS stock_days_below
    ),
    m AS (
        SELECT date_trunc('month', w.window_end)::date AS month
        FROM report_window(p_reporting_month) w
    ),
    node AS (
        -- the selection; below facility level, its facility ancestor; unknown id: no row
        SELECT COALESCE(
                   (SELECT l.ancestor_id
                    FROM org_unit_lineage l
                    JOIN hierarchy_config hc ON hc.var_name = 'facility' AND hc.level = l.ancestor_level
                    JOIN org_units ou ON ou.id = l.org_unit_id AND ou.level > hc.level
                    WHERE l.org_unit_id = p_org_unit_id),
                   COALESCE(p_org_unit_id, 0)) AS id
        WHERE COALESCE(p_org_unit_id, 0) = 0
           OR EXISTS (SELECT 1 FROM org_units ou WHERE ou.id = p_org_unit_id)
    ),
    d AS (
        SELECT node.id, s.drug_category::text AS category,
               round(s.category_patient_days, 1) AS patient_days, s.ord
        FROM node
        CROSS JOIN m
        CROSS JOIN LATERAL heart360tk_reporting.drug_stock_patient_days_all(m.month, NULLIF(node.id, 0))
             WITH ORDINALITY AS s(drug_category, category_patient_days, reporting_n, cohort_n,
                                  normalized_stock, patients_n, ord)
    )
    SELECT d.id, d.category, d.patient_days, COALESCE(d.patient_days < t.stock_days_below, FALSE)
    FROM d CROSS JOIN t
    ORDER BY d.ord;
$$;

-- ----------------------------------------------------------------------------
-- chat_call_plan (story 6.1, CR-6, EP-10)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chat_call_plan(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id          integer,
    overdue_with_phone_n bigint,
    week_1               bigint,
    week_2               bigint,
    week_3               bigint,
    week_4               bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    SELECT
        r.org_unit_id,
        r.overdue_with_phone_n,
        LEAST(r.calls_per_week, GREATEST(r.overdue_with_phone_n,                        0))::bigint,
        LEAST(r.calls_per_week, GREATEST(r.overdue_with_phone_n - 1 * r.calls_per_week, 0))::bigint,
        LEAST(r.calls_per_week, GREATEST(r.overdue_with_phone_n - 2 * r.calls_per_week, 0))::bigint,
        LEAST(r.calls_per_week, GREATEST(r.overdue_with_phone_n - 3 * r.calls_per_week, 0))::bigint
    FROM report_calling(p_reporting_month, p_org_unit_id) r
    WHERE r.is_selected;
$$;

-- ----------------------------------------------------------------------------
-- chat_facility_rank_district (story 6.2, AD-31 visit_first and Also check)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chat_facility_rank_district(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id    integer,
    org_unit_name  text,
    uncontrolled_n bigint,
    breaches       text[],
    also_check     boolean,
    rank           integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('chattogram', 'control_below_pct')      AS control_below_pct,
               h360_threshold('chattogram', 'uncontrolled_above_pct') AS uncontrolled_above_pct,
               h360_threshold('chattogram', 'missed_visit_above_pct') AS missed_visit_above_pct,
               h360_threshold('chattogram', 'ltfu_above_pct')         AS ltfu_above_pct,
               h360_threshold('common', 'high_control_pct')           AS high_control_pct
    ),
    fac AS (
        SELECT hc.level FROM hierarchy_config hc WHERE hc.var_name = 'facility'
    ),
    c AS (
        SELECT s.*
        FROM chat_control_summary(p_reporting_month, p_org_unit_id) s
        CROSS JOIN fac
        WHERE s.level >= fac.level
    ),
    fl AS (
        SELECT DISTINCT f.org_unit_id
        FROM report_flags(p_reporting_month, p_org_unit_id) f
        WHERE f.report IN ('fudging', 'titration')
    )
    SELECT
        c.org_unit_id,
        c.org_unit_name,
        c.uncontrolled_n,
        ARRAY(
            SELECT b.key
            FROM (VALUES
                (1, 'control_below_pct',      c.controlled_pct   <  t.control_below_pct),
                (2, 'uncontrolled_above_pct', c.uncontrolled_pct >  t.uncontrolled_above_pct),
                (3, 'missed_visit_above_pct', c.missed_visit_pct >  t.missed_visit_above_pct),
                (4, 'ltfu_above_pct',         c.ltfu_pct         >  t.ltfu_above_pct)
            ) AS b(ord, key, hit)
            WHERE b.hit
            ORDER BY b.ord
        ) AS breaches,
        (COALESCE(c.controlled_pct >= t.high_control_pct, FALSE) AND fl.org_unit_id IS NOT NULL) AS also_check,
        row_number() OVER (ORDER BY c.uncontrolled_n DESC NULLS LAST, c.org_unit_name, c.org_unit_id)::integer AS rank
    FROM c
    CROSS JOIN t
    LEFT JOIN fl ON fl.org_unit_id = c.org_unit_id
    ORDER BY rank;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION report_flags(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION chat_control_summary(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION chat_drug_stock_gate(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION chat_call_plan(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION chat_facility_rank_district(date, integer) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
    v_fn   TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_flags(date, integer) TO %I', v_role);
        END IF;
    END LOOP;

    FOREACH v_fn IN ARRAY ARRAY['chat_control_summary', 'chat_drug_stock_gate', 'chat_call_plan',
                                'chat_facility_rank_district'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'h360_api') THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.%I(date, integer) TO h360_api', v_fn);
        END IF;
        -- chat_* is h360_api only; the REVOKE keeps the Grafana reader out even if a grant slipped in.
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader') THEN
            EXECUTE format('REVOKE ALL ON FUNCTION heart360tk_schema.%I(date, integer) FROM heart360tk_reader', v_fn);
        END IF;
    END LOOP;
END $$;

COMMIT;
