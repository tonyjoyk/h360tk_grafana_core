-- 0.6.17_to_0.6.18: database review fixes (review 2026-11)
--
-- search_path  drug_stock_pull_apply runs inside the SECURITY DEFINER save_drug_stock_entry with
--     search_path = heart360tk_schema and no pg_temp, so pg_temp was searched first and a caller's
--     temp table could shadow a table while it ran as the owner. drug_stock_on_hand_matrix had the
--     same gap. Both now end in pg_temp (0.6.6_to_0.6.7 is fixed too, for a fresh install).
--     TEMP on the database is revoked from PUBLIC and granted back to the two roles that use temp
--     tables: heart360tk (importer, seeds) and grafana (its own store). h360_api and the readers
--     no longer have it.
-- Unused SQL dropped (no dashboard, dashboard_src, h360-api or script calls them):
--     chat_home_unit, report_adherence_buckets, report_fudging_histogram, classify_visit_step,
--     drug_stock_form_long_rows. Their CREATEs stay in the older files; the chain re-run ends here.
-- grafana_reader loses SELECT on heart360tk_reporting.drug_stock_patient_days (no postgres-grafana
--     panel reads it; the stock board reads it as heart360tk_cached).
-- One rule each:
--     report_adherence(month, org, include_new)  same columns and numbers, now the CR-2 columns of
--         report_adherence_summary (controlled_n = cohort_controlled_n, controlled_pct =
--         cohort_controlled_pct).
--     report_statins_monthly(month, org)  same columns; each month's eligibility and statin status
--         come from h360_statin_patients(month, 0), so the newest month equals report_statins.
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- search_path ends in pg_temp
-- ----------------------------------------------------------------------------
ALTER FUNCTION drug_stock_pull_apply(jsonb) SET search_path = heart360tk_schema, pg_temp;
ALTER FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(date, integer)
    SET search_path = heart360tk_reporting, heart360tk_schema, pg_temp;

-- ----------------------------------------------------------------------------
-- Unused functions
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS chat_home_unit(boolean, text[]);
DROP FUNCTION IF EXISTS report_adherence_buckets(date, integer, boolean);
DROP FUNCTION IF EXISTS report_fudging_histogram(date, integer);
DROP FUNCTION IF EXISTS classify_visit_step(bigint);
DROP FUNCTION IF EXISTS drug_stock_form_long_rows(jsonb);

-- ----------------------------------------------------------------------------
-- report_adherence: the CR-2 columns of report_adherence_summary
-- ----------------------------------------------------------------------------
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
    SELECT s.org_unit_id, s.org_unit_name, s.level, s.is_selected, s.too_few, s.flag, s.flag_reason,
           s.cohort_n, s.cohort_controlled_n, s.cohort_controlled_pct, s.off_protocol_pct,
           s.one_medicine_pct
    FROM report_adherence_summary(p_reporting_month, p_org_unit_id, p_include_new) s;
$$;

-- ----------------------------------------------------------------------------
-- report_statins_monthly: h360_statin_patients per month end
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_statins_monthly(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    month_date          date,
    org_unit_id         integer,
    org_unit_name       text,
    level               integer,
    is_selected         boolean,
    too_few             boolean,
    eligible_n          bigint,
    on_statin_n         bigint,
    rate_pct            numeric,
    average_eligible_n  bigint,
    average_on_statin_n bigint,
    average_rate_pct    numeric
)
LANGUAGE sql
STABLE
ROWS 70
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('statins', 'min_eligible') AS min_eligible
    ),
    months AS (
        SELECT (date_trunc('month', w.window_end) - make_interval(months => g))::date AS month_date
        FROM report_window(p_reporting_month) w, generate_series(0, 8) g
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    -- Every place: the network average pools the whole database.
    st AS (
        SELECT mo.month_date, s.org_unit_id, s.on_statin
        FROM months mo
        CROSS JOIN LATERAL h360_statin_patients(mo.month_date, 0) s
    ),
    net AS (
        SELECT st.month_date, count(*) AS d, count(*) FILTER (WHERE st.on_statin) AS n
        FROM st GROUP BY st.month_date
    ),
    agg AS (
        SELECT st.month_date, m.report_org_unit_id,
               count(*) AS d, count(*) FILTER (WHERE st.on_statin) AS n
        FROM st
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = st.org_unit_id
        GROUP BY st.month_date, m.report_org_unit_id
    )
    SELECT
        mo.month_date, u.org_unit_id, u.org_unit_name, u.level, u.is_selected,
        COALESCE(g.d, 0) < t.min_eligible,
        COALESCE(g.d, 0)::bigint, COALESCE(g.n, 0)::bigint,
        round(100.0 * g.n / NULLIF(g.d, 0), 1),
        COALESCE(nt.d, 0)::bigint, COALESCE(nt.n, 0)::bigint,
        round(100.0 * nt.n / NULLIF(nt.d, 0), 1)
    FROM months mo
    CROSS JOIN units u
    CROSS JOIN t
    LEFT JOIN agg g ON g.month_date = mo.month_date AND g.report_org_unit_id = u.org_unit_id
    LEFT JOIN net nt ON nt.month_date = mo.month_date
    ORDER BY mo.month_date, u.row_order;
$$;

-- ----------------------------------------------------------------------------
-- Privileges
-- ----------------------------------------------------------------------------
RESET ROLE;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader')
       AND to_regclass('heart360tk_reporting.drug_stock_patient_days') IS NOT NULL THEN
        REVOKE SELECT ON heart360tk_reporting.drug_stock_patient_days FROM grafana_reader;
    END IF;

    EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
    FOREACH v_role IN ARRAY ARRAY['heart360tk', 'grafana'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT TEMPORARY ON DATABASE %I TO %I', current_database(), v_role);
        END IF;
    END LOOP;
END $$;

COMMIT;
