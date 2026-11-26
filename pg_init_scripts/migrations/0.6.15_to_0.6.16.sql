-- 0.6.15_to_0.6.16: UX audit report fixes (story 7.9 group J; UX-03, UX-04, UX-05, UX-06, UX-11, UX-25)
--
-- What changes, by finding:
--
-- UX-04  refresh_all_reporting_tables (heart360tk_reporting) empties each cache table with DELETE instead of
--        TRUNCATE. TRUNCATE takes an ACCESS EXCLUSIVE lock held until the whole refresh commits (about 12 s
--        on the demo), so every reader of heart360_patients_category waited, and TRUNCATE is not MVCC-safe:
--        a reader whose snapshot predates the commit then saw the table empty. That was the strip's
--        `0 patients` at all locations and its 6.7 s load (report_flags.patients_n = h360_control_summary).
--        DELETE never blocks readers and they keep seeing the previous rows until the refresh commits.
--        report_flags itself is unchanged (0.6 s at all locations).
--
-- UX-03  report_adherence_summary(month, org, include_new): the report_adherence rows (same rows, too_few,
--        flag and flag_reason, CR-2) with the HTN-tab control on every row:
--          under_care_n, controlled_n, control_pct   = h360_control_summary (HTN tab, Stepping up, chat).
--        The CR-2 measure keeps its own, plainly named columns:
--          cohort_n, cohort_controlled_n, cohort_controlled_pct  (patients seen in the 90 days, BP under
--          140/90 at their latest visit there; = report_adherence controlled_n / controlled_pct).
--        Counts with their percents: off_protocol_n, one_medicine_n, step_3_plus_n (Steps 3-6).
--        report_adherence itself is unchanged: its return type cannot change without breaking a re-run of
--        the migration chain (verify_upgrade_path), and its controlled_pct is the CR-2 cohort number. The
--        Right medicines tab should read report_adherence_summary.
--
-- UX-05  report_adherence_steps(month, org, include_new): the Excel step table (protocol_engine.py
--        write_protocol_report_table), selection only, 13 rows in this order (row_key):
--          protocol_total   Protocol medicines            all protocol-only patients (steps + other mix)
--          steps_total      On a protocol step            Steps 1-6
--          step_1 .. step_6 Step n · <medicines>          label built from htn_ladder_steps + medicines
--          other_protocol   Other mix of protocol medicines
--          non_protocol     Medicine outside the protocol
--          no_htn_medicine  No BP medicine at last visit  (Unrecognized: no_htn_medicine, no_prescription)
--          unreadable       Could not read the entry      (Unrecognized: unreadable)
--          grand_total      All patients
--        Columns (tool column in brackets):
--          patients_n            [B] alive I10 patients in the subtree with any visit up to window_end,
--                                    by the bucket of their latest visit up to window_end
--          patients_pct          [C] patients_n / all patients
--          step_share_pct        [D] patients_n / patients on Steps 1-6 (step rows and steps_total only)
--          cohort_n              [E] the CR-2 cohort: latest visit in the 90-day window, registered before
--                                    it unless include_new. Equals report_adherence_buckets / cohort_n.
--          cohort_controlled_n   [F] of cohort_n, BP under 140/90 at that visit
--          cohort_controlled_pct [G] F / E  (% controlled among patients on that row)
--          controlled_share_pct  [H] F / F(steps_total), step rows only, as the tool computes it
--          controlled_share_cum_pct  running sum of H from Step 1 to Step n (`Control so far`)
--        Cells the tool leaves blank are NULL. Percents 1 decimal, NULL when the denominator is 0.
--
-- UX-06  report_titration_monthly(month, org) and report_statins_monthly(month, org): one row per
--        (month, report row) for the 9 months ending at the reporting month. Each month's row is that
--        month's own report (report_titration: the 90 days ending at that month's end; report_statins:
--        eligible at that month's end), so the newest row equals the tab's headline. average_* is the
--        network average: every place in the database pooled (numerator sum / denominator sum), the
--        meaning the Metabase reports used.
--          titration: follow_up_n (high-BP visits counted), titrated_n (stepped up), rate_pct
--          statins:   eligible_n, on_statin_n, rate_pct
--
-- UX-25  BP Fudging PRD: report_fudging_quarterly(month, org) and report_fudging_share(month, org).
--          Readings   every blood_pressures row of an encounter in the quarter, patient attributed by
--                     patients.org_unit_id (A52), as h360_bp_readings. Bands half-open: 130 <= s < 140,
--                     140 <= s < 150.
--          Quarters   the last 4 completed quarters ending on or before window_end (is_complete), plus the
--                     quarter in progress up to window_end when the reporting month is not a quarter end
--                     (is_complete = false, so the tab can show it as `so far` or leave it out).
--          ratio      round(n_130_139 / n_140_149, 2); NULL when n_140_149 = 0.
--          band       too_few  n_130_139 + n_140_149 < fudging.min_readings
--                     flag     n_140_149 = 0, or ratio >= fudging.flag_ratio (2.0)
--                     yellow   ratio >= fudging.warn_ratio (1.8)
--                     green    otherwise
--          share      per quarter, of the facility rows in scope with enough readings (checked_n), how many
--                     are flagged (flagged_n) and flagged_pct.
--        New threshold rows: (fudging, warn_ratio, 1.8) and (fudging, flag_ratio, 2.0).
--        report_fudging, report_fudging_histogram and report_flags are NOT changed: report_fudging keeps
--        the CR-4 3-month 135-139/140-144 score. Moving the flag to the PRD now would drop the planted
--        PHC-E pattern (it sits in the quarter in progress, audit section 5b), flag PHC-A and PHC-B on
--        Q3 2026, and fail verify_seed_targets. The owner's seed decision (group N) comes first; then
--        report_fudging can read report_fudging_quarterly's newest complete quarter.
--
-- UX-11  report_calling (same columns, new return rule) and report_calling_return(month, org). One return
--        rule, the Hypertension tab's:
--          denominator  patients called in the month (called_n: overdue with a phone at the start of the
--                       month, first call in the month)
--          returned     a visit within calling.return_days (30) of that first call, whole days
--          open         called, not returned yet, and call_date + return_days is after the newest visit
--                       in the database (they may still come back)
--        report_calling_return gives the plainly named columns per report row: called_month_n,
--        returned_month_n, returned_month_pct, return_open_n, returned_early_pct, returned_later_pct.
--        report_calling keeps its column names, which now follow the same rule, so the current tab shows
--        the same numbers: return_known_n = called_month_n, returned_n = returned_month_n,
--        returned_pct = returned_month_pct, return_not_yet_known_n = return_open_n,
--        returned_early_pct / returned_later_pct = the same rule split by early and later calls.
--        Calls whose outcome is Removed are no longer left out (the Hypertension tab counts them).
--        The 90-day return set of 0.6.12_to_0.6.13 is gone. The program dashboard's 15-day
--        HEART360_OVERDUE_RETURNED_TO_CARE row should read these columns per month (group A).
--
-- Every report_* function here is STABLE SECURITY DEFINER, owned by heart360tk, SET jit = off, granted
-- to heart360tk_reader and h360_api (none is patient level). Thresholds come from report_flag_thresholds
-- through h360_threshold; no threshold literal in this file.
--
-- One transaction, idempotent, safe to re-run. Threshold rows are inserted ON CONFLICT DO NOTHING.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

INSERT INTO report_flag_thresholds (report, key, value) VALUES
    ('fudging', 'warn_ratio', 1.8),
    ('fudging', 'flag_ratio', 2.0)
ON CONFLICT (report, key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- UX-04: cache refresh without TRUNCATE (same table list, log rows and error handling as 01)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION heart360tk_reporting.refresh_all_reporting_tables()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id bigint;
    start_time timestamp;
    end_time timestamp;
    v_table_name text;
    v_rows_affected integer;
    v_tables text[] := ARRAY[
        'heart360_patients_category',
        'heart360_patients_under_care',
        'heart360_patients_registered',
        'heart360_blood_sugar_controlled',
        'heart360_blood_sugar_severity',
        'heart360_blood_sugar_missed_visits',
        'heart360_dm_bp_control',
        'heart360_dm_patients_under_care',
        'heart360_overdue_patients',
        'heart360_overdue_start_of_month',
        'heart360_overdue_patients_called',
        'heart360_overdue_returned_to_care',
        'heart360_cohort_patient_details',
        'heart360_dm_patients_catagory'
    ];
    i integer;
BEGIN
    v_batch_id := EXTRACT(EPOCH FROM clock_timestamp())::bigint;

    FOR i IN 1..array_length(v_tables, 1)
    LOOP
        v_table_name := v_tables[i];

        BEGIN
            start_time := clock_timestamp();
            RAISE NOTICE 'Refreshing %', v_table_name;

            -- DELETE, not TRUNCATE: readers are never blocked and never see an empty table (UX-04).
            EXECUTE format('DELETE FROM heart360tk_reporting.%I', v_table_name);
            EXECUTE format('INSERT INTO heart360tk_reporting.%I SELECT * FROM heart360tk_schema.%I', v_table_name, v_table_name);
            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

            end_time := clock_timestamp();
            INSERT INTO heart360tk_reporting.reporting_table_refresh_log
                (reporting_table_name, last_refreshed_at, refresh_duration, status, refresh_batch_id)
            VALUES (v_table_name, end_time, end_time - start_time, 'success: ' || v_rows_affected || ' rows', v_batch_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO heart360tk_reporting.reporting_table_refresh_log
                (reporting_table_name, last_refreshed_at, refresh_duration, status, refresh_batch_id)
            VALUES (v_table_name, now(), NULL, 'failed: ' || SQLERRM, v_batch_id);
        END;
    END LOOP;

END;
$$;

-- ----------------------------------------------------------------------------
-- UX-03: report_adherence_summary, the adherence rows with the HTN-tab control on every row
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_adherence_summary(p_reporting_month date, p_org_unit_id integer,
                                                    p_include_new boolean DEFAULT false)
RETURNS TABLE (
    org_unit_id           integer,
    org_unit_name         text,
    level                 integer,
    is_selected           boolean,
    too_few               boolean,
    flag                  boolean,
    flag_reason           text,
    cohort_n              bigint,
    cohort_controlled_n   bigint,
    cohort_controlled_pct numeric,
    off_protocol_n        bigint,
    off_protocol_pct      numeric,
    one_medicine_n        bigint,
    one_medicine_pct      numeric,
    step_3_plus_n         bigint,
    step_3_plus_pct       numeric,
    under_care_n          bigint,
    controlled_n          bigint,
    control_pct           numeric
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
            count(*)                                                               AS cohort_n,
            count(*) FILTER (WHERE a.controlled)                                   AS cohort_controlled_n,
            count(*) FILTER (WHERE a.bucket IN ('Non-Protocol', 'Other Protocol')) AS off_protocol_n,
            count(*) FILTER (WHERE a.step_no IN (1, 2))                            AS one_medicine_n,
            count(*) FILTER (WHERE a.step_no >= 3)                                 AS step_3_plus_n
        FROM h360_adherence_patients(p_reporting_month, p_org_unit_id, p_include_new) a
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = a.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.cohort_n, 0)            AS cohort_n,
            COALESCE(g.cohort_controlled_n, 0) AS cohort_controlled_n,
            round(100.0 * g.cohort_controlled_n / NULLIF(g.cohort_n, 0), 1) AS cohort_controlled_pct,
            COALESCE(g.off_protocol_n, 0)      AS off_protocol_n,
            round(100.0 * g.off_protocol_n / NULLIF(g.cohort_n, 0), 1)      AS off_protocol_pct,
            COALESCE(g.one_medicine_n, 0)      AS one_medicine_n,
            round(100.0 * g.one_medicine_n / NULLIF(g.cohort_n, 0), 1)      AS one_medicine_pct,
            COALESCE(g.step_3_plus_n, 0)       AS step_3_plus_n,
            round(100.0 * g.step_3_plus_n / NULLIF(g.cohort_n, 0), 1)       AS step_3_plus_pct,
            c.under_care_n,
            c.controlled_n,
            c.controlled_pct                   AS control_pct
        FROM units u
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id
        LEFT JOIN LATERAL h360_control_summary(p_reporting_month, u.org_unit_id) c ON TRUE
    ),
    f AS (
        SELECT
            r.*,
            r.cohort_n < t.min_cohort                AS too_few,
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
        f.cohort_controlled_n::bigint,
        f.cohort_controlled_pct,
        f.off_protocol_n::bigint,
        f.off_protocol_pct,
        f.one_medicine_n::bigint,
        f.one_medicine_pct,
        f.step_3_plus_n::bigint,
        f.step_3_plus_pct,
        f.under_care_n,
        f.controlled_n,
        f.control_pct
    FROM f
    ORDER BY f.row_order;
$$;

-- ----------------------------------------------------------------------------
-- UX-05: report_adherence_steps, the Excel step table
-- ----------------------------------------------------------------------------
-- Plain label of one step from the ladder tuple and the protocol medicines, e.g.
-- `Amlodipine 10 mg + Lisinopril or Telmisartan (standard dose)`. A class with one dose for all its
-- drugs at that level prints the dose; otherwise `(standard dose)` / `(full dose)`. A thiazide step
-- whose tuple without the thiazide is a two-class step reads `Step k + <thiazide>`.
CREATE OR REPLACE FUNCTION h360_ladder_step_labels()
RETURNS TABLE (step_no integer, label text)
LANGUAGE sql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
    WITH steps AS (
        SELECT DISTINCT ON (s.step_no) s.step_no, s.ccb_level, s.raas_level, s.thz_level
        FROM htn_ladder_steps s
        ORDER BY s.step_no, s.ccb_level, s.raas_level, s.thz_level
    ),
    part AS (
        SELECT c.ladder_class, c.lvl,
               CASE WHEN count(DISTINCT CASE c.lvl WHEN 1 THEN m.start_mg_day ELSE m.full_mg_day END) = 1
                    THEN string_agg(m.drug_name, ' or ' ORDER BY m.drug_class, m.drug_name) || ' '
                         || trim_scale(min(CASE c.lvl WHEN 1 THEN m.start_mg_day ELSE m.full_mg_day END))::text || ' mg'
                    ELSE string_agg(m.drug_name, ' or ' ORDER BY m.drug_class, m.drug_name)
                         || CASE c.lvl WHEN 1 THEN ' (standard dose)' ELSE ' (full dose)' END
               END AS txt
        FROM (VALUES ('CCB', 1), ('CCB', 2), ('RAAS', 1), ('RAAS', 2), ('THIAZIDE', 1), ('THIAZIDE', 2)) c(ladder_class, lvl)
        JOIN medicines m ON m.htn_role = 'protocol' AND m.ladder_class = c.ladder_class
        GROUP BY c.ladder_class, c.lvl
    )
    SELECT
        s.step_no,
        'Step ' || s.step_no || ' · ' ||
        CASE WHEN s.thz_level > 0 AND s.ccb_level > 0 AND s.raas_level > 0 AND b.step_no IS NOT NULL
             THEN 'Step ' || b.step_no || ' + ' || pt.txt
             ELSE concat_ws(' + ', pc.txt, pr.txt, pt.txt)
        END
    FROM steps s
    LEFT JOIN part pc ON pc.ladder_class = 'CCB'      AND pc.lvl = s.ccb_level
    LEFT JOIN part pr ON pr.ladder_class = 'RAAS'     AND pr.lvl = s.raas_level
    LEFT JOIN part pt ON pt.ladder_class = 'THIAZIDE' AND pt.lvl = s.thz_level
    LEFT JOIN steps b ON b.ccb_level = s.ccb_level AND b.raas_level = s.raas_level AND b.thz_level = 0;
$$;

CREATE OR REPLACE FUNCTION report_adherence_steps(p_reporting_month date, p_org_unit_id integer,
                                                  p_include_new boolean DEFAULT false)
RETURNS TABLE (
    row_order                integer,
    row_key                  text,
    label                    text,
    step_no                  integer,
    patients_n               bigint,
    patients_pct             numeric,
    step_share_pct           numeric,
    cohort_n                 bigint,
    cohort_controlled_n      bigint,
    cohort_controlled_pct    numeric,
    controlled_share_pct     numeric,
    controlled_share_cum_pct numeric
)
LANGUAGE sql
STABLE
ROWS 13
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH w AS (
        SELECT * FROM report_window(p_reporting_month)
    ),
    pts AS (
        SELECT p.patient_id
        FROM patients p
        WHERE p.patient_status IS DISTINCT FROM 'DEAD'
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
          AND EXISTS (SELECT 1 FROM patient_diagnoses pd
                      WHERE pd.patient_id = p.patient_id AND pd.diagnosis_code = 'I10')
    ),
    last_enc AS (
        SELECT DISTINCT ON (e.patient_id) e.patient_id, e.id, e.encounter_date
        FROM encounters e
        JOIN pts ON pts.patient_id = e.patient_id
        CROSS JOIN w
        WHERE e.encounter_date < w.window_end + 1
        ORDER BY e.patient_id, e.encounter_date DESC, e.id DESC
    ),
    reg AS (
        SELECT e.patient_id, min(e.encounter_date)::date AS registration_date
        FROM encounters e
        JOIN pts ON pts.patient_id = e.patient_id
        GROUP BY e.patient_id
    ),
    cls AS (
        -- the same joins as h360_adherence_patients, so cohort counts equal report_adherence_buckets
        SELECT
            CASE WHEN v.step_no IS NOT NULL THEN 'step_' || v.step_no
                 WHEN v.bucket = 'Other Protocol' THEN 'other_protocol'
                 WHEN v.bucket = 'Non-Protocol' THEN 'non_protocol'
                 WHEN v.reason = 'unreadable' THEN 'unreadable'
                 ELSE 'no_htn_medicine'
            END AS row_key,
            (l.encounter_date >= w.window_start
             AND (COALESCE(p_include_new, FALSE) OR r.registration_date < w.window_start)) AS in_cohort,
            COALESCE(bp.systolic_bp < 140 AND bp.diastolic_bp < 90, FALSE) AS controlled
        FROM last_enc l
        JOIN reg r ON r.patient_id = l.patient_id
        JOIN visit_step v ON v.encounter_id = l.id
        LEFT JOIN blood_pressures bp ON bp.encounter_id = l.id
        CROSS JOIN w
    ),
    keys AS (
        SELECT * FROM (VALUES
            ('step_1', 1), ('step_2', 2), ('step_3', 3), ('step_4', 4), ('step_5', 5), ('step_6', 6),
            ('other_protocol', NULL), ('non_protocol', NULL), ('no_htn_medicine', NULL), ('unreadable', NULL)
        ) k(row_key, step_no)
    ),
    b AS (
        SELECT k.row_key, k.step_no,
               count(c.row_key)                                   AS p,
               count(c.row_key) FILTER (WHERE c.in_cohort)                  AS c,
               count(c.row_key) FILTER (WHERE c.in_cohort AND c.controlled) AS t
        FROM keys k
        LEFT JOIN cls c ON c.row_key = k.row_key
        GROUP BY k.row_key, k.step_no
    ),
    tot AS (
        SELECT
            sum(p) FILTER (WHERE step_no IS NOT NULL) AS sp, sum(c) FILTER (WHERE step_no IS NOT NULL) AS sc,
            sum(t) FILTER (WHERE step_no IS NOT NULL) AS st,
            sum(p) FILTER (WHERE step_no IS NOT NULL OR row_key = 'other_protocol') AS pp,
            sum(c) FILTER (WHERE step_no IS NOT NULL OR row_key = 'other_protocol') AS pc,
            sum(t) FILTER (WHERE step_no IS NOT NULL OR row_key = 'other_protocol') AS pt,
            sum(p) AS ap, sum(c) AS ac, sum(t) AS tt
        FROM b
    ),
    rws AS (
        SELECT 1 AS row_order, 'protocol_total' AS row_key, 'Protocol medicines' AS label, NULL::integer AS step_no,
               tot.pp AS p, NULL::numeric AS d_base, tot.pc AS c, tot.pt AS t, NULL::numeric AS h_base
        FROM tot
        UNION ALL
        SELECT 2, 'steps_total', 'On a protocol step', NULL, tot.sp, tot.sp, tot.sc, tot.st, NULL FROM tot
        UNION ALL
        SELECT 2 + b.step_no, b.row_key, COALESCE(lb.label, 'Step ' || b.step_no), b.step_no,
               b.p, tot.sp, b.c, b.t, tot.st
        FROM b CROSS JOIN tot
        LEFT JOIN h360_ladder_step_labels() lb ON lb.step_no = b.step_no
        WHERE b.step_no IS NOT NULL
        UNION ALL
        SELECT CASE b.row_key WHEN 'other_protocol' THEN 9 WHEN 'non_protocol' THEN 10
                              WHEN 'no_htn_medicine' THEN 11 ELSE 12 END,
               b.row_key,
               CASE b.row_key WHEN 'other_protocol' THEN 'Other mix of protocol medicines'
                              WHEN 'non_protocol' THEN 'Medicine outside the protocol'
                              WHEN 'no_htn_medicine' THEN 'No BP medicine at last visit'
                              ELSE 'Could not read the entry' END,
               NULL, b.p, NULL, b.c, b.t, NULL
        FROM b
        WHERE b.step_no IS NULL
        UNION ALL
        SELECT 13, 'grand_total', 'All patients', NULL, tot.ap, NULL, tot.ac, tot.tt, NULL FROM tot
    )
    SELECT
        r.row_order,
        r.row_key,
        r.label,
        r.step_no,
        r.p::bigint,
        round(100.0 * r.p / NULLIF(tot.ap, 0), 1),
        round(100.0 * r.p / NULLIF(r.d_base, 0), 1),
        r.c::bigint,
        r.t::bigint,
        round(100.0 * r.t / NULLIF(r.c, 0), 1),
        round(100.0 * r.t / NULLIF(r.h_base, 0), 1),
        CASE WHEN r.step_no IS NOT NULL THEN
            round(100.0 * sum(r.t) OVER (PARTITION BY r.step_no IS NOT NULL ORDER BY r.row_order)
                  / NULLIF(r.h_base, 0), 1)
        END
    FROM rws r
    CROSS JOIN tot
    WHERE EXISTS (SELECT 1 FROM h360_report_units(p_org_unit_id))   -- unknown org unit: no rows
    ORDER BY r.row_order;
$$;

-- ----------------------------------------------------------------------------
-- UX-06: monthly series with the network average
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_titration_monthly(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    month_date          date,
    org_unit_id         integer,
    org_unit_name       text,
    level               integer,
    is_selected         boolean,
    too_few             boolean,
    follow_up_n         bigint,
    titrated_n          bigint,
    rate_pct            numeric,
    average_follow_up_n bigint,
    average_titrated_n  bigint,
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
        SELECT h360_threshold('titration', 'min_visits') AS min_visits
    ),
    months AS (
        SELECT (date_trunc('month', w.window_end) - make_interval(months => g))::date AS month_date
        FROM report_window(p_reporting_month) w, generate_series(0, 8) g
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    v AS (
        -- every place once per month; the report rows and the network average are cut from it
        SELECT mo.month_date, tv.org_unit_id, tv.excluded, tv.stepped_up
        FROM months mo
        CROSS JOIN LATERAL h360_titration_visits(mo.month_date, NULL) tv
    ),
    net AS (
        SELECT v.month_date,
               count(*) FILTER (WHERE v.excluded IS NULL) AS d,
               count(*) FILTER (WHERE v.stepped_up)       AS n
        FROM v GROUP BY v.month_date
    ),
    agg AS (
        SELECT v.month_date, m.report_org_unit_id,
               count(*) FILTER (WHERE v.excluded IS NULL) AS d,
               count(*) FILTER (WHERE v.stepped_up)       AS n
        FROM v
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = v.org_unit_id
        GROUP BY v.month_date, m.report_org_unit_id
    )
    SELECT
        mo.month_date, u.org_unit_id, u.org_unit_name, u.level, u.is_selected,
        COALESCE(g.d, 0) < t.min_visits,
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

-- Statins: one pass over the 9 month ends with the CR-5 rules of h360_statin_patients (alive; age at
-- least statins.min_age at the month end; E11, or MI/STROKE on or before the month end; a visit in the
-- 365 days to the month end; on a statin = the latest encounter with a prescription up to the month end
-- has a statin line). The newest month equals report_statins.
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
        SELECT h360_threshold('statins', 'min_age')::integer AS min_age,
               h360_threshold('statins', 'min_eligible')     AS min_eligible
    ),
    months AS (
        SELECT mo::date AS month_date, (mo + interval '1 month' - interval '1 day')::date AS w_end
        FROM (SELECT date_trunc('month', w.window_end) - make_interval(months => g) AS mo
              FROM report_window(p_reporting_month) w, generate_series(0, 8) g) x
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    risk AS (
        SELECT p.patient_id, p.org_unit_id, p.birth_date,
               EXISTS (SELECT 1 FROM patient_diagnoses pd
                       WHERE pd.patient_id = p.patient_id AND pd.diagnosis_code = 'E11') AS has_dm,
               (SELECT min(h.event_date) FROM patient_cvd_history h
                WHERE h.patient_id = p.patient_id AND h.event_type IN ('MI', 'STROKE')) AS cvd_date
        FROM patients p
        WHERE p.patient_status IS DISTINCT FROM 'DEAD'
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULL) d)
    ),
    el AS (
        SELECT mo.month_date, mo.w_end, r.patient_id, r.org_unit_id
        FROM months mo
        CROSS JOIN risk r
        CROSS JOIN t
        WHERE (r.has_dm OR r.cvd_date <= mo.w_end)
          AND r.birth_date <= mo.w_end - make_interval(years => t.min_age)
          AND EXISTS (SELECT 1 FROM encounters e
                      WHERE e.patient_id = r.patient_id
                        AND e.encounter_date >= mo.w_end - 364
                        AND e.encounter_date <  mo.w_end + 1)
    ),
    st AS (
        SELECT el.month_date, el.org_unit_id,
               COALESCE((
                   SELECT EXISTS (SELECT 1 FROM prescription_lines l
                                  JOIN medicines md ON md.drug_name = l.drug_name
                                  WHERE l.encounter_id = lr.id AND md.is_statin)
                   FROM (SELECT e.id FROM encounters e
                         JOIN prescriptions pr ON pr.encounter_id = e.id
                         WHERE e.patient_id = el.patient_id AND e.encounter_date < el.w_end + 1
                         ORDER BY e.encounter_date DESC, e.id DESC
                         LIMIT 1) lr), FALSE) AS on_statin
        FROM el
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
-- UX-25: BP Fudging PRD, quarterly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report_fudging_quarterly(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id   integer,
    org_unit_name text,
    level         integer,
    is_selected   boolean,
    quarter_start date,
    quarter_end   date,
    quarter_label text,
    is_complete   boolean,
    too_few       boolean,
    flag          boolean,
    n_130_139     bigint,
    n_140_149     bigint,
    ratio         numeric,
    band          text
)
LANGUAGE sql
STABLE
ROWS 40
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    WITH t AS (
        SELECT h360_threshold('fudging', 'min_readings') AS min_readings,
               h360_threshold('fudging', 'warn_ratio')   AS warn_ratio,
               h360_threshold('fudging', 'flag_ratio')   AS flag_ratio
    ),
    w AS (
        SELECT r.window_end,
               (date_trunc('quarter', r.window_end + 1) - interval '3 months')::date AS last_q
        FROM report_window(p_reporting_month) r
    ),
    qs AS (
        SELECT (w.last_q - make_interval(months => 3 * g))::date AS q_start, TRUE AS is_complete
        FROM w, generate_series(0, 3) g
        UNION ALL
        SELECT date_trunc('quarter', w.window_end)::date, FALSE
        FROM w
        WHERE date_trunc('quarter', w.window_end)::date > w.last_q
    ),
    q AS (
        SELECT qs.q_start,
               LEAST((qs.q_start + interval '3 months')::date - 1, w.window_end) AS q_end,
               qs.is_complete,
               'Q' || extract(quarter FROM qs.q_start) || ' ' || extract(year FROM qs.q_start) AS label
        FROM qs CROSS JOIN w
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    rd AS (
        SELECT p.org_unit_id, e.encounter_date, bp.systolic_bp
        FROM encounters e
        JOIN blood_pressures bp ON bp.encounter_id = e.id
        JOIN patients p ON p.patient_id = e.patient_id
        CROSS JOIN w
        WHERE e.encounter_date >= (SELECT min(q.q_start) FROM q)
          AND e.encounter_date <  w.window_end + 1
          AND bp.systolic_bp >= 130 AND bp.systolic_bp < 150
          AND p.org_unit_id IN (SELECT d.id FROM get_descendant_ids(NULLIF(p_org_unit_id, 0)) d)
    ),
    agg AS (
        SELECT m.report_org_unit_id, q.q_start,
               count(*) FILTER (WHERE rd.systolic_bp < 140)  AS a,
               count(*) FILTER (WHERE rd.systolic_bp >= 140) AS b
        FROM rd
        JOIN q ON rd.encounter_date >= q.q_start AND rd.encounter_date < q.q_end + 1
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = rd.org_unit_id
        GROUP BY m.report_org_unit_id, q.q_start
    ),
    r AS (
        SELECT u.*, q.q_start, q.q_end, q.label, q.is_complete,
               COALESCE(g.a, 0) AS a, COALESCE(g.b, 0) AS b,
               CASE WHEN COALESCE(g.b, 0) > 0 THEN round(g.a::numeric / g.b, 2) END AS ratio
        FROM units u
        CROSS JOIN q
        LEFT JOIN agg g ON g.report_org_unit_id = u.org_unit_id AND g.q_start = q.q_start
    ),
    f AS (
        SELECT r.*,
               CASE WHEN r.a + r.b < t.min_readings THEN 'too_few'
                    WHEN r.b = 0 OR r.ratio >= t.flag_ratio THEN 'flag'
                    WHEN r.ratio >= t.warn_ratio THEN 'yellow'
                    ELSE 'green' END AS band
        FROM r CROSS JOIN t
    )
    SELECT f.org_unit_id, f.org_unit_name, f.level, f.is_selected,
           f.q_start, f.q_end, f.label, f.is_complete,
           f.band = 'too_few', f.band = 'flag',
           f.a::bigint, f.b::bigint, f.ratio, f.band
    FROM f
    ORDER BY f.row_order, f.q_start;
$$;

-- Per quarter: of the facility rows in scope (level at or below the facility level, as report_flags)
-- with enough readings, how many have a ratio at fudging.flag_ratio or more.
CREATE OR REPLACE FUNCTION report_fudging_share(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    quarter_start date,
    quarter_label text,
    is_complete   boolean,
    facilities_n  bigint,
    checked_n     bigint,
    flagged_n     bigint,
    flagged_pct   numeric
)
LANGUAGE sql
STABLE
ROWS 5
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    SELECT
        q.quarter_start,
        q.quarter_label,
        q.is_complete,
        count(*)::bigint,
        count(*) FILTER (WHERE NOT q.too_few)::bigint,
        count(*) FILTER (WHERE q.flag)::bigint,
        round(100.0 * count(*) FILTER (WHERE q.flag) / NULLIF(count(*) FILTER (WHERE NOT q.too_few), 0), 1)
    FROM report_fudging_quarterly(p_reporting_month, p_org_unit_id) q
    JOIN hierarchy_config hc ON hc.var_name = 'facility'
    WHERE q.level >= hc.level
    GROUP BY q.quarter_start, q.quarter_label, q.is_complete
    ORDER BY q.quarter_start;
$$;

-- ----------------------------------------------------------------------------
-- UX-11: report_calling with one return rule
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
        SELECT h360_threshold('calling', 'min_overdue_phone')      AS min_overdue_phone,
               h360_threshold('calling', 'called_below_pct')       AS called_below_pct,
               h360_threshold('calling', 'early_days')             AS early_days,
               h360_threshold('calling', 'early_below_pct')        AS early_below_pct,
               h360_threshold('calling', 'return_days')::integer   AS return_days,
               (SELECT max(e.encounter_date)::date FROM encounters e) AS newest_date
    ),
    units AS (
        SELECT * FROM h360_report_units(p_org_unit_id)
    ),
    c AS (
        SELECT cp.org_unit_id, cp.has_phone, cp.called, cp.is_early, cp.outcome,
               rt.back,
               (cp.called AND NOT rt.back AND cp.call_date + t.return_days > t.newest_date) AS open
        FROM h360_calling_patients(p_reporting_month, p_org_unit_id) cp
        CROSS JOIN t
        CROSS JOIN LATERAL (
            SELECT (cp.called AND EXISTS (
                        SELECT 1 FROM encounters e
                        WHERE e.patient_id = cp.patient_id
                          AND e.encounter_date >= cp.call_date
                          AND e.encounter_date <  cp.call_date + t.return_days + 1)) AS back
        ) rt
        WHERE cp.is_report_month
    ),
    agg AS (
        SELECT
            m.report_org_unit_id,
            count(*)                                                      AS overdue_n,
            count(*) FILTER (WHERE c.has_phone)                           AS overdue_with_phone_n,
            count(*) FILTER (WHERE c.called)                              AS called_n,
            count(*) FILTER (WHERE c.called AND c.is_early)               AS early_n,
            count(*) FILTER (WHERE c.outcome = 'Agreed to visit')         AS agreed_n,
            count(*) FILTER (WHERE c.outcome = 'Call again later')        AS call_again_n,
            count(*) FILTER (WHERE c.outcome = 'Removed')                 AS removed_n,
            count(*) FILTER (WHERE c.back)                            AS returned_n,
            count(*) FILTER (WHERE c.back AND c.is_early)             AS early_returned_n,
            count(*) FILTER (WHERE c.called AND NOT c.is_early)           AS later_n,
            count(*) FILTER (WHERE c.back AND NOT c.is_early)         AS later_returned_n,
            count(*) FILTER (WHERE c.open)                                AS open_n
        FROM c
        JOIN h360_report_member(p_org_unit_id) m ON m.member_org_unit_id = c.org_unit_id
        GROUP BY m.report_org_unit_id
    ),
    r AS (
        SELECT
            u.org_unit_id, u.org_unit_name, u.level, u.is_selected, u.row_order,
            COALESCE(g.overdue_n, 0)            AS overdue_n,
            COALESCE(g.overdue_with_phone_n, 0) AS overdue_with_phone_n,
            COALESCE(g.called_n, 0)             AS called_n,
            round(100.0 * g.called_n / NULLIF(g.overdue_with_phone_n, 0), 1) AS called_pct,
            COALESCE(g.early_n, 0)              AS early_n,
            round(100.0 * g.early_n / NULLIF(g.called_n, 0), 1)             AS early_pct,
            COALESCE(g.agreed_n, 0)             AS agreed_n,
            COALESCE(g.call_again_n, 0)         AS call_again_n,
            COALESCE(g.removed_n, 0)            AS removed_n,
            COALESCE(g.returned_n, 0)           AS returned_n,
            round(100.0 * g.returned_n / NULLIF(g.called_n, 0), 1)             AS returned_pct,
            round(100.0 * g.early_returned_n / NULLIF(g.early_n, 0), 1)        AS returned_early_pct,
            round(100.0 * g.later_returned_n / NULLIF(g.later_n, 0), 1)        AS returned_later_pct,
            COALESCE(g.open_n, 0)               AS open_n
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
        f.called_n::bigint      AS return_known_n,
        f.returned_n::bigint,
        f.returned_pct,
        f.returned_early_pct,
        f.returned_later_pct,
        f.open_n::bigint        AS return_not_yet_known_n,
        ceil(f.overdue_with_phone_n / 4.0)::bigint AS calls_per_week
    FROM f
    ORDER BY f.row_order;
$$;

-- The return measures of report_calling under their plain names (UX-11).
CREATE OR REPLACE FUNCTION report_calling_return(p_reporting_month date, p_org_unit_id integer)
RETURNS TABLE (
    org_unit_id        integer,
    org_unit_name      text,
    level              integer,
    is_selected        boolean,
    too_few            boolean,
    called_month_n     bigint,
    returned_month_n   bigint,
    returned_month_pct numeric,
    return_open_n      bigint,
    returned_early_pct numeric,
    returned_later_pct numeric
)
LANGUAGE sql
STABLE
ROWS 20
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
SET jit = off
AS $$
    SELECT c.org_unit_id, c.org_unit_name, c.level, c.is_selected, c.too_few,
           c.called_n, c.returned_n, c.returned_pct, c.return_not_yet_known_n,
           c.returned_early_pct, c.returned_later_pct
    FROM report_calling(p_reporting_month, p_org_unit_id) c;
$$;

-- ----------------------------------------------------------------------------
-- Privileges (AD-15, AD-27, grant matrix)
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION h360_ladder_step_labels() FROM PUBLIC;
REVOKE ALL ON FUNCTION report_adherence_summary(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_adherence_steps(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_titration_monthly(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_statins_monthly(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_fudging_quarterly(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_fudging_share(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_calling(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION report_calling_return(date, integer) FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['heart360tk_reader', 'h360_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_adherence_summary(date, integer, boolean) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_adherence_steps(date, integer, boolean) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_titration_monthly(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_statins_monthly(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_fudging_quarterly(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_fudging_share(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_calling(date, integer) TO %I', v_role);
            EXECUTE format('GRANT EXECUTE ON FUNCTION heart360tk_schema.report_calling_return(date, integer) TO %I', v_role);
        END IF;
    END LOOP;
END $$;

COMMIT;
