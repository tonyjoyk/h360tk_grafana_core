-- Seed 30: overdue calls for 2026-05 through 2026-10 (story 4.6, AD-34).
-- Each month calls the facility share of that month's start-of-month
-- overdue-with-phone list. Early calls are those within 14 days of becoming
-- overdue. About half of early calls and about a quarter of later calls are
-- patients who have a visit within 30 days. A visit already on the calendar
-- counts. A visit is inserted only to fill that share.
-- Outcomes: about 50% Agreed to visit, 30% Call again later, 20% removed.
-- PHC-C removals are mostly Wrong phone number. No Died. No Pending to call.
SET ROLE heart360tk;
SET search_path TO heart360tk_schema, public;

CREATE TABLE IF NOT EXISTS demo_seed_marker (
    seed       text PRIMARY KEY,
    anchor     date NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION demo_seed_hash(p_key text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT (
        (get_byte(decode(md5(p_key), 'hex'), 0)::bigint << 24)
      + (get_byte(decode(md5(p_key), 'hex'), 1)::bigint << 16)
      + (get_byte(decode(md5(p_key), 'hex'), 2)::bigint << 8)
      +  get_byte(decode(md5(p_key), 'hex'), 3)::bigint
    );
$fn$;

DO $do$
DECLARE
    v_anchor date;
    v_month  date;
    v_n      integer;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '30_calls') THEN
        RAISE NOTICE '30_calls already applied';
        RETURN;
    END IF;

    SELECT COALESCE(
        (SELECT MAX(encounter_date)::date FROM encounters),
        DATE '2026-10-13'
    ) INTO v_anchor;

    CREATE TEMP TABLE demo_seed_call_plan (
        month          date NOT NULL,
        patient_id     bigint NOT NULL,
        call_date      date NOT NULL,
        is_early       boolean NOT NULL,
        do_return      boolean NOT NULL,
        result_type    text,
        removed_reason text NOT NULL,
        org_unit_id    integer,
        PRIMARY KEY (month, patient_id)
    );

    FOR v_month IN
        SELECT gs::date
        FROM generate_series(DATE '2026-05-01', DATE '2026-10-01', INTERVAL '1 month') AS gs
    LOOP
        WITH leaf_fac AS (
            SELECT leaf.id AS org_unit_id, anc.facility_id, anc.facility_name
            FROM org_units leaf
            JOIN LATERAL (
                WITH RECURSIVE up AS (
                    SELECT id, parent_id, level, name
                    FROM org_units
                    WHERE id = leaf.id
                    UNION ALL
                    SELECT o.id, o.parent_id, o.level, o.name
                    FROM org_units o
                    JOIN up ON up.parent_id = o.id
                )
                SELECT id AS facility_id, name AS facility_name
                FROM up
                WHERE level = 3
                LIMIT 1
            ) AS anc ON true
            WHERE anc.facility_name IN ('PHC-A', 'PHC-B', 'PHC-C', 'PHC-D', 'PHC-E', 'PHC-F')
        ),
        visits AS (
            SELECT p.patient_id,
                   p.org_unit_id,
                   f.facility_id,
                   f.facility_name,
                   max(e.encounter_date) AS last_dt
            FROM patients p
            JOIN encounters e
              ON e.patient_id = p.patient_id
             AND e.encounter_date < v_month
            JOIN leaf_fac f ON f.org_unit_id = p.org_unit_id
            WHERE p.patient_status = 'ALIVE'
              AND length(regexp_replace(COALESCE(p.phone_number, ''), '[^0-9]', '', 'g')) >= 8
            GROUP BY p.patient_id, p.org_unit_id, f.facility_id, f.facility_name
            HAVING max(e.encounter_date) < v_month - INTERVAL '45 days'
        ),
        open_list AS (
            SELECT v.*
            FROM visits v
            WHERE NOT EXISTS (
                SELECT 1
                FROM (
                    SELECT cr.result_type
                    FROM call_results cr
                    WHERE cr.patient_id = v.patient_id
                      AND cr.call_date > v.last_dt::date
                      AND cr.call_date < v_month
                    ORDER BY cr.call_date DESC, cr.call_id DESC
                    LIMIT 1
                ) AS last_call
                WHERE last_call.result_type = 'removed_from_overdue_list'
            )
        ),
        targets AS (
            SELECT facility_id,
                   round(share * n)::integer AS n_call,
                   round(
                       early_rate * round(share * n)
                   )::integer AS n_early
            FROM (
                SELECT facility_id,
                       count(*) AS n,
                       CASE facility_name
                           WHEN 'PHC-A' THEN 0.11
                           WHEN 'PHC-B' THEN 0.08
                           WHEN 'PHC-C' THEN 0.06
                           WHEN 'PHC-D' THEN 0.06
                           WHEN 'PHC-E' THEN 0.04
                           WHEN 'PHC-F' THEN 0.09
                       END AS share,
                       CASE facility_name
                           WHEN 'PHC-A' THEN 0.60
                           WHEN 'PHC-F' THEN 0.45
                           ELSE 0.38
                       END AS early_rate
                FROM open_list
                GROUP BY facility_id, facility_name
            ) AS sized
        ),
        marked AS (
            SELECT o.*,
                   (o.last_dt::date >= v_month - 59 AND o.last_dt::date < v_month - 45) AS can_early,
                   t.n_call,
                   t.n_early
            FROM open_list o
            JOIN targets t ON t.facility_id = o.facility_id
        ),
        early_pool AS (
            SELECT m.*,
                   EXISTS (
                       SELECT 1
                       FROM encounters e
                       WHERE e.patient_id = m.patient_id
                         AND e.encounter_date::date >= v_month
                         AND e.encounter_date::date <= v_month + 30
                   ) AS already_back
            FROM marked m
            WHERE can_early
              AND n_call > 0
        ),
        early_quota AS (
            SELECT facility_id,
                   n_take,
                   n_back,
                   LEAST((n_take - round(0.50 * n_take)::integer), n_fresh) AS non_ret
            FROM (
                SELECT facility_id,
                       LEAST(MAX(n_early), MAX(n_call), count(*))::integer AS n_take,
                       count(*) FILTER (WHERE already_back)::integer AS n_back,
                       count(*) FILTER (WHERE NOT already_back)::integer AS n_fresh
                FROM early_pool
                GROUP BY facility_id
            ) AS sized
        ),
        early_slots AS (
            SELECT facility_id,
                   non_ret,
                   LEAST(n_back, n_take - non_ret) AS from_back,
                   (n_take - non_ret) - LEAST(n_back, n_take - non_ret) AS from_fresh_ret
            FROM early_quota
        ),
        early_chosen AS (
            SELECT p.patient_id,
                   p.org_unit_id,
                   p.facility_id,
                   p.facility_name,
                   v_month AS call_date,
                   true AS is_early,
                   (NOT p.already_back AND p.rn <= s.from_fresh_ret) AS do_return
            FROM (
                SELECT pool.*,
                       row_number() OVER (
                           PARTITION BY facility_id, already_back
                           ORDER BY md5(patient_id::text || ':call-early:' || v_month::text)
                       ) AS rn
                FROM early_pool pool
            ) AS p
            JOIN early_slots s ON s.facility_id = p.facility_id
            WHERE (p.already_back AND p.rn <= s.from_back)
               OR (NOT p.already_back AND p.rn <= s.from_fresh_ret + s.non_ret)
        ),
        late_need AS (
            SELECT t.facility_id,
                   GREATEST(t.n_call - COALESCE(got.n_early_got, 0), 0)::integer AS n_want
            FROM targets t
            LEFT JOIN (
                SELECT facility_id, count(*)::integer AS n_early_got
                FROM early_chosen
                GROUP BY facility_id
            ) AS got ON got.facility_id = t.facility_id
        ),
        late_base AS (
            SELECT m.patient_id,
                   m.org_unit_id,
                   m.facility_id,
                   m.facility_name,
                   m.can_early,
                   dates.call_date,
                   n.n_want
            FROM marked m
            JOIN late_need n ON n.facility_id = m.facility_id
            CROSS JOIN LATERAL (
                SELECT LEAST(
                           (v_month + INTERVAL '1 month' - INTERVAL '1 day')::date,
                           GREATEST(v_month + 11, m.last_dt::date + 60)
                       ) AS call_date
            ) AS dates
            WHERE n.n_want > 0
              AND NOT EXISTS (
                  SELECT 1 FROM early_chosen e WHERE e.patient_id = m.patient_id
              )
              AND dates.call_date >= v_month
              AND dates.call_date < v_month + INTERVAL '1 month'
              AND dates.call_date > m.last_dt::date + 59
        ),
        late_ranked AS (
            SELECT b.*,
                   row_number() OVER (
                       PARTITION BY b.facility_id
                       ORDER BY b.can_early,
                                md5(b.patient_id::text || ':call-late-pool:' || v_month::text)
                   ) AS pool_rn
            FROM late_base b
        ),
        late_pool AS (
            SELECT r.patient_id,
                   r.org_unit_id,
                   r.facility_id,
                   r.facility_name,
                   r.call_date,
                   r.n_want,
                   EXISTS (
                       SELECT 1
                       FROM encounters e
                       WHERE e.patient_id = r.patient_id
                         AND e.encounter_date::date >= r.call_date
                         AND e.encounter_date::date <= r.call_date + 30
                   ) AS already_back
            FROM late_ranked r
            WHERE NOT r.can_early
               OR r.pool_rn <= r.n_want
        ),
        late_quota AS (
            SELECT facility_id,
                   n_take,
                   n_back,
                   LEAST((n_take - round(0.25 * n_take)::integer), n_fresh) AS non_ret
            FROM (
                SELECT facility_id,
                       LEAST(MAX(n_want), count(*))::integer AS n_take,
                       count(*) FILTER (WHERE already_back)::integer AS n_back,
                       count(*) FILTER (WHERE NOT already_back)::integer AS n_fresh
                FROM late_pool
                GROUP BY facility_id
            ) AS sized
        ),
        late_slots AS (
            SELECT facility_id,
                   non_ret,
                   LEAST(n_back, n_take - non_ret) AS from_back,
                   (n_take - non_ret) - LEAST(n_back, n_take - non_ret) AS from_fresh_ret
            FROM late_quota
        ),
        late_chosen AS (
            SELECT p.patient_id,
                   p.org_unit_id,
                   p.facility_id,
                   p.facility_name,
                   p.call_date,
                   false AS is_early,
                   (NOT p.already_back AND p.rn <= s.from_fresh_ret) AS do_return
            FROM (
                SELECT pool.*,
                       row_number() OVER (
                           PARTITION BY facility_id, already_back
                           ORDER BY md5(patient_id::text || ':call-late:' || v_month::text)
                       ) AS rn
                FROM late_pool pool
            ) AS p
            JOIN late_slots s ON s.facility_id = p.facility_id
            WHERE (p.already_back AND p.rn <= s.from_back)
               OR (NOT p.already_back AND p.rn <= s.from_fresh_ret + s.non_ret)
        ),
        picked AS (
            SELECT patient_id, org_unit_id, facility_id, facility_name,
                   call_date, is_early, do_return
            FROM early_chosen
            UNION ALL
            SELECT patient_id, org_unit_id, facility_id, facility_name,
                   call_date, is_early, do_return
            FROM late_chosen
        ),
        scored AS (
            SELECT p.*,
                   row_number() OVER (
                       PARTITION BY facility_id
                       ORDER BY md5(patient_id::text || ':outcome:' || v_month::text)
                   ) AS orn,
                   count(*) OVER (PARTITION BY facility_id) AS n_picked
            FROM picked p
        )
        INSERT INTO demo_seed_call_plan (
            month, patient_id, call_date, is_early, do_return, result_type, removed_reason, org_unit_id
        )
        SELECT
            v_month,
            patient_id,
            call_date,
            is_early,
            do_return,
            CASE
                WHEN orn > n_picked - round(0.20 * n_picked) THEN 'removed_from_overdue_list'
                ELSE NULL
            END,
            CASE
                WHEN orn <= round(0.50 * n_picked) THEN 'Agreed to visit'
                WHEN orn <= n_picked - round(0.20 * n_picked) THEN 'Call again later'
                WHEN facility_name = 'PHC-C'
                     AND demo_seed_hash(patient_id::text || ':why:' || v_month::text) % 5 < 4
                    THEN 'Wrong phone number'
                WHEN facility_name = 'PHC-C' THEN 'Refused to return'
                ELSE (ARRAY[
                    'Refused to return',
                    'Moved out of catchment area',
                    'Multiple failed contact attempts',
                    'Transferred to another puskesmas',
                    'Already visited puskesmas',
                    'Other reason'
                ])[1 + (demo_seed_hash(patient_id::text || ':why:' || v_month::text) % 6)]
            END,
            org_unit_id
        FROM scored
        ON CONFLICT DO NOTHING;

        INSERT INTO call_results (patient_id, call_date, result_type, removed_reason, org_unit_id)
        SELECT patient_id, call_date, result_type, removed_reason, org_unit_id
        FROM demo_seed_call_plan
        WHERE month = v_month
        ON CONFLICT DO NOTHING;

        INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
        SELECT patient_id, (call_date + 10)::timestamp + TIME '15:00', org_unit_id
        FROM demo_seed_call_plan
        WHERE month = v_month
          AND do_return
          AND call_date + 10 <= DATE '2026-10-13'
        ON CONFLICT DO NOTHING;

        -- The return visit needs its own prescription. Copy the patient's
        -- latest text so the regimen walk does not step backwards.
        INSERT INTO prescriptions (encounter_id, obat_raw, source)
        SELECT e.id,
               COALESCE(
                   (
                       SELECT pr.obat_raw
                       FROM prescriptions pr
                       JOIN encounters prev ON prev.id = pr.encounter_id
                       WHERE prev.patient_id = e.patient_id
                         AND prev.encounter_date < e.encounter_date
                       ORDER BY prev.encounter_date DESC, prev.id DESC
                       LIMIT 1
                   ),
                   'Amlodipine 5 mg - 1 x 1 Tablet Sehari'
               ),
               'demo'
        FROM encounters e
        JOIN demo_seed_call_plan pl
          ON pl.patient_id = e.patient_id
         AND e.encounter_date = (pl.call_date + 10)::timestamp + TIME '15:00'
        WHERE pl.month = v_month
          AND pl.do_return
        ON CONFLICT DO NOTHING;
    END LOOP;

    SELECT count(*) INTO v_n FROM call_results;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('30_calls', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '30_calls applied, % call rows', v_n;
END
$do$;
