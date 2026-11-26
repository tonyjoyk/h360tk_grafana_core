-- 0.6.12_to_0.6.13: overdue calling + new patients reports (CR-6; stories 5.5 and 5.6)
--
-- h360_calling_patients(month, org)  one row per (patient, month) for every month that overlaps the
--                                    AD-26 window: the patient is overdue at the start of that month,
--                                    plus that month's first call (CR-6 "Called") and its return.
-- report_calling(month, org)         CR-6 calling measures and flags per report row (AD-27).
-- report_new_patients(month, org)    CR-6 new-patient loss and usable phone per report row (AD-27).
--
-- Rules (CR-6, CLINICAL-RULES sections 1, 2 and 6):
--   Month M           M_start = first day of the reporting month, M_end = its last day.
--   Last visit        the latest encounter with encounter_date < M_start.
--   Overdue           alive; last visit < M_start - calling.overdue_days; the latest call_results row
--                     with last_visit::date < call_date < M_start is not removed_from_overdue_list.
--                     Same rule as HEART360_OVERDUE_PATIENTS and seed 30_calls; no diagnosis filter.
--   With a phone      phone_number has 8 or more digits (as HEART360_OVERDUE_START_OF_MONTH).
--   Called            overdue with a phone, and a first call_results row in [M_start, M_end] whose
--                     removed_reason IS DISTINCT FROM 'Pending to call'.
--                     So that called_n can never exceed HEART360_OVERDUE_PATIENTS_CALLED (AC 4), a
--                     patient also needs that view's own test on the month's first row of any kind:
--                     not removed with reason Died. Demo data has no Died rows, so this changes nothing.
--   Early             call_date - (last_visit::date + overdue_days) <= calling.early_days.
--   Outcome           Agreed to visit / Call again later / Removed (result_type removed_from_overdue_list).
--   Returns (A63)     first calls (the Called rule, each month) with call_date in [window_start,
--                     window_end]. Known when call_date + calling.return_days <= the newest
--                     encounter_date::date in the database (not report_window.data_end, which stops at
--                     window_end); returned = an encounter in [call_date, call_date + return_days].
--                     Calls whose outcome is Removed are left out of the return measures: the patient
--                     is off the list, so no return is expected. CLINICAL-RULES fixture C5 (removed on
--                     08-01, inside the 2026-09 window) needs this to give "1 of 2 known".
--   calls_per_week    ceil(overdue_with_phone_n / 4) (EP-10).
--   New patients      alive, first encounter in [window_end - 179, window_end - 90] (A53). Lost = no
--                     encounter in (first, first + 90 days]. Usable phone = 8 or more digits and never a
--                     call_results row with removed_reason 'Wrong phone number' (A54).
--   Flags             compare the displayed (1 decimal) percent with report_flag_thresholds; too_few
--                     forces flag = false. report_calling has no phone flag (EP-12).
--
-- report_new_patients needs a minimum for too_few (story 5.6: "fewer than 10 new patients") that
-- CLINICAL-RULES section 2 does not list. It is added here as ('new_patients', 'min_patients', 10),
-- source A37, ON CONFLICT DO NOTHING.
--
-- h360_calling_patients is an invoker helper owned by heart360tk with no EXECUTE grant (patient level).
-- The report functions are STABLE SECURITY DEFINER, SET jit = off (see 0.6.8_to_0.6.9), and are
-- granted to heart360tk_reader and h360_api.
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

INSERT INTO report_flag_thresholds (report, key, value) VALUES
    ('new_patients', 'min_patients', 10)
ON CONFLICT (report, key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- h360_calling_patients: one row per (patient, month overlapping the window) where the
-- patient is overdue at the start of that month. is_report_month marks M itself.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h360_calling_patients(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    patient_id      bigint,
    org_unit_id     integer,
    month_start     date,
    is_report_month boolean,
    has_phone       boolean,
    last_visit      timestamp,
    called          boolean,
    call_date       date,
    days_to_call    integer,
    is_early        boolean,
    outcome         text,
    in_return_set   boolean,
    return_known    boolean,
    returned        boolean
)
LANGUAGE sql
STABLE
ROWS 5000
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH w AS (
        SELECT r.window_start, r.window_end,
               date_trunc('month', r.window_end)::date AS report_month,
               (SELECT max(e.encounter_date)::date FROM encounters e) AS newest_date
        FROM report_window(p_reporting_month) r
    ),
    t AS (
        SELECT h360_threshold('calling', 'overdue_days')::integer AS overdue_days,
               h360_threshold('calling', 'early_days')::integer   AS early_days,
               h360_threshold('calling', 'return_days')::integer  AS return_days
    ),
    months AS (
        SELECT gs::date AS m_start,
               (gs + interval '1 month' - interval '1 day')::date AS m_end
        FROM w,
             generate_series(date_trunc('month', w.window_start::timestamp),
                             w.report_month::timestamp, interval '1 month') gs
    ),
    pat AS (
        SELECT p.patient_id, p.org_unit_id,
               length(regexp_replace(COALESCE(p.phone_number, ''), '[^0-9]', '', 'g')) >= 8 AS has_phone
        FROM patients p
        WHERE p.patient_status IS DISTINCT FROM 'DEAD'
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
    ),
    last_visit AS (
        SELECT m.m_start, m.m_end, e.patient_id, max(e.encounter_date) AS last_visit
        FROM months m
        JOIN encounters e ON e.encounter_date < m.m_start
        JOIN pat ON pat.patient_id = e.patient_id
        GROUP BY m.m_start, m.m_end, e.patient_id
    ),
    overdue AS (
        SELECT lv.m_start, lv.m_end, lv.patient_id, lv.last_visit, pat.org_unit_id, pat.has_phone
        FROM last_visit lv
        JOIN pat ON pat.patient_id = lv.patient_id
        CROSS JOIN t
        WHERE lv.last_visit < lv.m_start - t.overdue_days
          AND NOT EXISTS (
              SELECT 1
              FROM (SELECT cr.result_type
                    FROM call_results cr
                    WHERE cr.patient_id = lv.patient_id
                      AND cr.call_date > lv.last_visit::date
                      AND cr.call_date < lv.m_start
                    ORDER BY cr.call_date DESC, cr.call_id DESC
                    LIMIT 1) lc
              WHERE lower(lc.result_type) = 'removed_from_overdue_list')
    ),
    calls AS (
        SELECT o.*,
               fc.call_date, fc.result_type, fc.removed_reason,
               (o.has_phone
                AND fc.call_date IS NOT NULL
                AND COALESCE(NOT (lower(fa.result_type) = 'removed_from_overdue_list'
                                  AND lower(fa.removed_reason) = 'died'), FALSE)) AS called
        FROM overdue o
        LEFT JOIN LATERAL (
            SELECT cr.call_date, cr.result_type, cr.removed_reason
            FROM call_results cr
            WHERE cr.patient_id = o.patient_id
              AND cr.call_date BETWEEN o.m_start AND o.m_end
              AND cr.removed_reason IS DISTINCT FROM 'Pending to call'
            ORDER BY cr.call_date, cr.call_id
            LIMIT 1
        ) fc ON TRUE
        LEFT JOIN LATERAL (
            -- HEART360_OVERDUE_PATIENTS_CALLED looks at the month's first row of any kind.
            SELECT cr.result_type, cr.removed_reason
            FROM call_results cr
            WHERE cr.patient_id = o.patient_id
              AND cr.call_date BETWEEN o.m_start AND o.m_end
            ORDER BY cr.call_date, cr.call_id
            LIMIT 1
        ) fa ON TRUE
    ),
    shaped AS (
        SELECT c.*,
               CASE WHEN c.called THEN c.call_date - (c.last_visit::date + t.overdue_days) END AS days_to_call,
               CASE WHEN NOT c.called THEN NULL
                    WHEN lower(c.result_type) = 'removed_from_overdue_list' THEN 'Removed'
                    WHEN c.removed_reason = 'Agreed to visit' THEN 'Agreed to visit'
                    WHEN c.removed_reason = 'Call again later' THEN 'Call again later'
                    ELSE 'Other'
               END AS outcome
        FROM calls c CROSS JOIN t
    )
    SELECT
        s.patient_id,
        s.org_unit_id,
        s.m_start,
        s.m_start = w.report_month,
        s.has_phone,
        s.last_visit,
        s.called,
        CASE WHEN s.called THEN s.call_date END,
        s.days_to_call,
        s.days_to_call <= t.early_days,
        s.outcome,
        r.in_set,
        r.in_set AND s.call_date + t.return_days <= w.newest_date,
        r.in_set AND s.call_date + t.return_days <= w.newest_date
            AND EXISTS (SELECT 1 FROM encounters e
                        WHERE e.patient_id = s.patient_id
                          AND e.encounter_date >= s.call_date
                          AND e.encounter_date <  s.call_date + t.return_days + 1)
    FROM shaped s
    CROSS JOIN w
    CROSS JOIN t
    CROSS JOIN LATERAL (
        SELECT (s.called
                AND s.outcome <> 'Removed'
                AND s.call_date BETWEEN w.window_start AND w.window_end) AS in_set
    ) r
    WHERE s.m_start = w.report_month OR r.in_set;
$$;

-- ----------------------------------------------------------------------------
-- report_calling (CR-6). Columns: CLINICAL-RULES section 1.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_calling(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id            integer,
    org_unit_name          text,
    level                  integer,
    is_selected            boolean,
    too_few                boolean,
    flag                   boolean,
    flag_reason            text,
    overdue_n              bigint,
    overdue_with_phone_n   bigint,
    called_n               bigint,
    called_pct             numeric,
    early_n                bigint,
    early_pct              numeric,
    agreed_n               bigint,
    call_again_n           bigint,
    removed_n              bigint,
    return_known_n         bigint,
    returned_n             bigint,
    returned_pct           numeric,
    returned_early_pct     numeric,
    returned_later_pct     numeric,
    return_not_yet_known_n bigint,
    calls_per_week         bigint
)
LANGUAGE sql
STABLE
ROWS 20
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('calling', 'min_overdue_phone') AS min_overdue_phone,
               h360_threshold('calling', 'called_below_pct')  AS called_below_pct,
               h360_threshold('calling', 'early_days')        AS early_days,
               h360_threshold('calling', 'early_below_pct')   AS early_below_pct
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*) FILTER (WHERE c.is_report_month)                                     AS overdue_n,
            count(*) FILTER (WHERE c.is_report_month AND c.has_phone)                     AS overdue_with_phone_n,
            count(*) FILTER (WHERE c.is_report_month AND c.called)                        AS called_n,
            count(*) FILTER (WHERE c.is_report_month AND c.called AND c.is_early)         AS early_n,
            count(*) FILTER (WHERE c.is_report_month AND c.outcome = 'Agreed to visit')   AS agreed_n,
            count(*) FILTER (WHERE c.is_report_month AND c.outcome = 'Call again later')  AS call_again_n,
            count(*) FILTER (WHERE c.is_report_month AND c.outcome = 'Removed')           AS removed_n,
            count(*) FILTER (WHERE c.return_known)                                        AS return_known_n,
            count(*) FILTER (WHERE c.returned)                                            AS returned_n,
            count(*) FILTER (WHERE c.return_known AND c.is_early)                         AS early_known_n,
            count(*) FILTER (WHERE c.returned AND c.is_early)                             AS early_returned_n,
            count(*) FILTER (WHERE c.return_known AND NOT c.is_early)                     AS later_known_n,
            count(*) FILTER (WHERE c.returned AND NOT c.is_early)                         AS later_returned_n,
            count(*) FILTER (WHERE c.in_return_set AND NOT c.return_known)                AS return_not_yet_known_n
        FROM h360_calling_patients(p_reporting_month, p_org_unit_id) c
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = c.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.overdue_n, 0)              AS overdue_n,
            COALESCE(g.overdue_with_phone_n, 0)   AS overdue_with_phone_n,
            COALESCE(g.called_n, 0)               AS called_n,
            round(100.0 * g.called_n / NULLIF(g.overdue_with_phone_n, 0), 1) AS called_pct,
            COALESCE(g.early_n, 0)                AS early_n,
            round(100.0 * g.early_n / NULLIF(g.called_n, 0), 1)             AS early_pct,
            COALESCE(g.agreed_n, 0)               AS agreed_n,
            COALESCE(g.call_again_n, 0)           AS call_again_n,
            COALESCE(g.removed_n, 0)              AS removed_n,
            COALESCE(g.return_known_n, 0)         AS return_known_n,
            COALESCE(g.returned_n, 0)             AS returned_n,
            round(100.0 * g.returned_n / NULLIF(g.return_known_n, 0), 1)             AS returned_pct,
            round(100.0 * g.early_returned_n / NULLIF(g.early_known_n, 0), 1)        AS returned_early_pct,
            round(100.0 * g.later_returned_n / NULLIF(g.later_known_n, 0), 1)        AS returned_later_pct,
            COALESCE(g.return_not_yet_known_n, 0) AS return_not_yet_known_n
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
    ),
    f AS (
        SELECT
            r.*,
            r.overdue_with_phone_n < t.min_overdue_phone AS too_few,
            r.called_pct < t.called_below_pct            AS called_hit,
            r.early_pct  < t.early_below_pct             AS early_hit,
            t.early_days
        FROM r CROSS JOIN t
    )
    SELECT
        f.org_unit_id,
        f.org_unit_name,
        f.level,
        f.is_selected,
        f.too_few,
        (NOT f.too_few AND (COALESCE(f.called_hit, FALSE) OR COALESCE(f.early_hit, FALSE))) AS flag,
        CASE WHEN NOT f.too_few THEN
            NULLIF(concat_ws(' ',
                CASE WHEN f.called_hit THEN 'Few overdue patients are called: '
                                            || to_char(f.called_pct, 'FM9990.0') || '%.' END,
                CASE WHEN f.early_hit THEN 'Most calls are late: '
                                           || to_char(f.early_pct, 'FM9990.0') || '% within '
                                           || to_char(f.early_days, 'FM9999') || ' days.' END), '')
        END AS flag_reason,
        f.overdue_n::bigint,
        f.overdue_with_phone_n::bigint,
        f.called_n::bigint,
        f.called_pct,
        f.early_n::bigint,
        f.early_pct,
        f.agreed_n::bigint,
        f.call_again_n::bigint,
        f.removed_n::bigint,
        f.return_known_n::bigint,
        f.returned_n::bigint,
        f.returned_pct,
        f.returned_early_pct,
        f.returned_later_pct,
        f.return_not_yet_known_n::bigint,
        ceil(f.overdue_with_phone_n / 4.0)::bigint AS calls_per_week   -- four weeks (header, calls_per_week)
    FROM f
    ORDER BY f.row_order;
$$;

-- ----------------------------------------------------------------------------
-- report_new_patients (CR-6, A53, A54). Columns: CLINICAL-RULES section 1.
-- The cohort bounds (179 and 90 days) and the 90-day return period are the A53 definition,
-- not flag thresholds.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_new_patients(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id          integer,
    org_unit_name        text,
    level                integer,
    is_selected          boolean,
    too_few              boolean,
    flag                 boolean,
    flag_reason          text,
    new_patients_n       bigint,
    new_returned_n       bigint,
    new_loss_pct         numeric,
    new_usable_phone_n   bigint,
    new_usable_phone_pct numeric
)
LANGUAGE sql
STABLE
ROWS 20
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH w AS (
        SELECT * FROM report_window(p_reporting_month)
    ),
    t AS (
        SELECT h360_threshold('new_patients', 'min_patients')    AS min_patients,
               h360_threshold('new_patients', 'phone_below_pct') AS phone_below_pct
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    pat AS (
        SELECT p.patient_id, p.org_unit_id, p.phone_number
        FROM patients p
        WHERE p.patient_status IS DISTINCT FROM 'DEAD'
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
    ),
    firsts AS (
        SELECT e.patient_id, min(e.encounter_date) AS first_dt
        FROM encounters e
        JOIN pat ON pat.patient_id = e.patient_id
        GROUP BY e.patient_id
    ),
    cohort AS (
        SELECT
            pat.patient_id,
            pat.org_unit_id,
            EXISTS (SELECT 1 FROM encounters e
                    WHERE e.patient_id = pat.patient_id
                      AND e.encounter_date >  f.first_dt
                      AND e.encounter_date <= f.first_dt + interval '90 days') AS came_back,
            (length(regexp_replace(COALESCE(pat.phone_number, ''), '[^0-9]', '', 'g')) >= 8
             AND NOT EXISTS (SELECT 1 FROM call_results cr
                             WHERE cr.patient_id = pat.patient_id
                               AND cr.removed_reason = 'Wrong phone number')) AS usable_phone
        FROM firsts f
        JOIN pat ON pat.patient_id = f.patient_id
        CROSS JOIN w
        WHERE f.first_dt::date BETWEEN w.window_end - 179 AND w.window_end - 90
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*)                                AS new_patients_n,
            count(*) FILTER (WHERE c.came_back)     AS new_returned_n,
            count(*) FILTER (WHERE NOT c.came_back) AS new_lost_n,
            count(*) FILTER (WHERE c.usable_phone)  AS new_usable_phone_n
        FROM cohort c
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = c.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.new_patients_n, 0)     AS new_patients_n,
            COALESCE(g.new_returned_n, 0)     AS new_returned_n,
            round(100.0 * g.new_lost_n / NULLIF(g.new_patients_n, 0), 1)         AS new_loss_pct,
            COALESCE(g.new_usable_phone_n, 0) AS new_usable_phone_n,
            round(100.0 * g.new_usable_phone_n / NULLIF(g.new_patients_n, 0), 1) AS new_usable_phone_pct
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
    ),
    f AS (
        SELECT r.*,
               r.new_patients_n < t.min_patients            AS too_few,
               r.new_usable_phone_pct < t.phone_below_pct   AS phone_hit
        FROM r CROSS JOIN t
    )
    SELECT
        f.org_unit_id,
        f.org_unit_name,
        f.level,
        f.is_selected,
        f.too_few,
        (NOT f.too_few AND COALESCE(f.phone_hit, FALSE)) AS flag,
        CASE WHEN NOT f.too_few AND f.phone_hit THEN
            'Few new patients have a usable phone number: ' || to_char(f.new_usable_phone_pct, 'FM9990.0') || '%.'
        END AS flag_reason,
        f.new_patients_n::bigint,
        f.new_returned_n::bigint,
        f.new_loss_pct,
        f.new_usable_phone_n::bigint,
        f.new_usable_phone_pct
    FROM f
    ORDER BY f.row_order;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION h360_calling_patients(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_calling(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_new_patients(date, integer) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_calling(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_new_patients(date, integer) TO %I', v_role);
        END IF;
    END LOOP;
END $$;

COMMIT;
