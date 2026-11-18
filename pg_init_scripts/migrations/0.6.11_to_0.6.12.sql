-- 0.6.11_to_0.6.12: statins report (CR-5; stories 5.8 and 5.9)
--
-- h360_statin_patients(month, org)    CR-5 eligible patients in the subtree, one row each, with the reason,
--                                     age and last visit at window_end and whether the latest prescription
--                                     on or before window_end has a statin line (medicines.is_statin).
-- report_statins(month, org)          CR-5 measures and flag per report row (AD-27 standard columns, then
--                                     eligible_n, on_statin_n, on_statin_pct, not_on_statin_n).
-- report_statins_patients(month, org) patient list: eligible patients not on a statin, only when the
--                                     selection is at facility level (hierarchy_config 'facility', level 3)
--                                     or below; otherwise no rows. Its count equals not_on_statin_n of the
--                                     selection row of report_statins for the same month and place.
--
-- Eligible (CR-5): alive (patient_status IS DISTINCT FROM 'DEAD'); an encounter in
-- [window_end - 364, window_end]; birth_date <= window_end - statins.min_age years; and an E11 diagnosis
-- or a patient_cvd_history MI or STROKE row with event_date <= window_end.
-- On a statin (CR-5): the patient's latest encounter on or before window_end that has a prescriptions row
-- has a line whose drug is_statin. An eligible patient with no such encounter is not on a statin.
--
-- Grants (AD-27, grant matrix): report_statins to heart360tk_reader and h360_api;
-- report_statins_patients (patient level) to heart360tk_reader only, and never to h360_api.
-- h360_statin_patients is an invoker helper with no EXECUTE grant: the definer report functions call it
-- as heart360tk.
--
-- Thresholds come from report_flag_thresholds (statins.min_eligible, statins.flag_below_pct,
-- statins.min_age) through h360_threshold. jit = off as in 0.6.8_to_0.6.9.
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

-- ----------------------------------------------------------------------------
-- h360_statin_patients (CR-5): eligible patients and statin status
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h360_statin_patients(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    patient_id      bigint,
    patient_name    text,
    org_unit_id     integer,
    age             integer,
    reason_eligible text,
    last_visit_date date,
    on_statin       boolean
)
LANGUAGE sql
STABLE
ROWS 2000
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH w AS (
        SELECT r.window_end FROM report_window(p_reporting_month) r
    ),
    t AS (
        SELECT h360_threshold('statins', 'min_age')::integer AS min_age
    ),
    base AS (
        SELECT
            p.patient_id,
            p.patient_name::text AS patient_name,
            p.org_unit_id,
            p.birth_date,
            EXISTS (SELECT 1 FROM patient_diagnoses pd
                    WHERE pd.patient_id = p.patient_id AND pd.diagnosis_code = 'E11') AS has_dm,
            EXISTS (SELECT 1 FROM patient_cvd_history h
                    WHERE h.patient_id = p.patient_id
                      AND h.event_type IN ('MI', 'STROKE')
                      AND h.event_date <= w.window_end) AS has_cvd
        FROM patients p
        CROSS JOIN w
        CROSS JOIN t
        WHERE p.patient_status IS DISTINCT FROM 'DEAD'
          AND p.birth_date <= w.window_end - make_interval(years => t.min_age)
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
    ),
    risk AS (
        SELECT b.* FROM base b WHERE b.has_dm OR b.has_cvd
    ),
    last_visit AS (
        SELECT e.patient_id, max(e.encounter_date)::date AS last_visit_date
        FROM encounters e
        JOIN risk r ON r.patient_id = e.patient_id
        CROSS JOIN w
        WHERE e.encounter_date < w.window_end + 1
        GROUP BY e.patient_id
    ),
    eligible AS (
        SELECT r.*, v.last_visit_date
        FROM risk r
        JOIN last_visit v ON v.patient_id = r.patient_id
        CROSS JOIN w
        WHERE v.last_visit_date >= w.window_end - 364
    ),
    latest_rx AS (
        SELECT DISTINCT ON (e.patient_id) e.patient_id, e.id AS encounter_id
        FROM encounters e
        JOIN eligible el ON el.patient_id = e.patient_id
        JOIN prescriptions pr ON pr.encounter_id = e.id
        CROSS JOIN w
        WHERE e.encounter_date < w.window_end + 1
        ORDER BY e.patient_id, e.encounter_date DESC, e.id DESC
    )
    SELECT
        el.patient_id,
        el.patient_name,
        el.org_unit_id,
        date_part('year', age(w.window_end, el.birth_date))::integer,
        CASE WHEN el.has_dm AND el.has_cvd THEN 'Both'
             WHEN el.has_dm THEN 'Diabetes'
             ELSE 'Heart attack or stroke' END,
        el.last_visit_date,
        COALESCE(EXISTS (
            SELECT 1
            FROM prescription_lines l
            JOIN medicines m ON m.drug_name = l.drug_name
            WHERE l.encounter_id = lr.encounter_id AND m.is_statin
        ), FALSE)
    FROM eligible el
    CROSS JOIN w
    LEFT JOIN latest_rx lr ON lr.patient_id = el.patient_id;
$$;

-- ----------------------------------------------------------------------------
-- report_statins (story 5.8). Columns: CLINICAL-RULES section 1. The flag compares the displayed
-- (1 decimal) percent with statins.flag_below_pct; too_few (eligible < statins.min_eligible)
-- forces flag = false.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_statins(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id     integer,
    org_unit_name   text,
    level           integer,
    is_selected     boolean,
    too_few         boolean,
    flag            boolean,
    flag_reason     text,
    eligible_n      bigint,
    on_statin_n     bigint,
    on_statin_pct   numeric,
    not_on_statin_n bigint
)
LANGUAGE sql
STABLE
ROWS 10
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('statins', 'min_eligible')   AS min_eligible,
               h360_threshold('statins', 'flag_below_pct') AS flag_below_pct
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*)                             AS eligible_n,
            count(*) FILTER (WHERE s.on_statin)  AS on_statin_n
        FROM h360_statin_patients(p_reporting_month, p_org_unit_id) s
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = s.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.eligible_n, 0)  AS eligible_n,
            COALESCE(g.on_statin_n, 0) AS on_statin_n,
            round(100.0 * g.on_statin_n / NULLIF(g.eligible_n, 0), 1) AS on_statin_pct
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
    ),
    f AS (
        SELECT
            r.*,
            r.eligible_n < t.min_eligible                       AS too_few,
            COALESCE(r.on_statin_pct < t.flag_below_pct, FALSE) AS low_hit
        FROM r CROSS JOIN t
    )
    SELECT
        f.org_unit_id,
        f.org_unit_name,
        f.level,
        f.is_selected,
        f.too_few,
        (NOT f.too_few AND f.low_hit) AS flag,
        CASE WHEN NOT f.too_few AND f.low_hit THEN
            'Few eligible patients are on a statin: ' || to_char(f.on_statin_pct, 'FM9990.0') || '%.'
        END AS flag_reason,
        f.eligible_n::bigint,
        f.on_statin_n::bigint,
        f.on_statin_pct,
        (f.eligible_n - f.on_statin_n)::bigint AS not_on_statin_n
    FROM f
    ORDER BY f.row_order;
$$;

-- ----------------------------------------------------------------------------
-- report_statins_patients (story 5.9). No standard columns. Rows only for a selection at
-- facility level or below (0, NULL, an unknown id or a level above facility: no rows).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_statins_patients(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    patient_id      bigint,
    patient_name    text,
    age             integer,
    reason_eligible text,
    last_visit_date date,
    org_unit_name   text
)
LANGUAGE sql
STABLE
ROWS 200
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    SELECT
        s.patient_id,
        s.patient_name,
        s.age,
        s.reason_eligible,
        s.last_visit_date,
        ou.name::text
    FROM h360_statin_patients(p_reporting_month, p_org_unit_id) s
    LEFT JOIN org_units ou ON ou.id = s.org_unit_id
    WHERE NOT s.on_statin
      AND EXISTS (
          SELECT 1
          FROM org_units sel
          JOIN hierarchy_config hc ON hc.var_name = 'facility'
          WHERE sel.id = p_org_unit_id
            AND sel.level >= hc.level
      )
    ORDER BY ou.name, s.patient_name, s.patient_id;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION h360_statin_patients(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_statins(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_statins_patients(date, integer) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_statins(date, integer) TO %I', v_role);
        END IF;
    END LOOP;

    -- Patient level: heart360tk_reader only. The REVOKE keeps h360_api out even if a grant slipped in.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_schema.report_statins_patients(date, integer) TO heart360tk_reader';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'h360_api') THEN
        EXECUTE 'REVOKE ALL ON FUNCTION heart360tk_schema.report_statins_patients(date, integer) FROM h360_api';
        EXECUTE 'REVOKE ALL ON FUNCTION heart360tk_schema.h360_statin_patients(date, integer) FROM h360_api';
    END IF;
END $$;

COMMIT;
