-- Seed 50: BP readings check on the BP Fudging PRD's terms (story 7.9, UX-25,
-- ux-audit-2026-11 section 5b, AD-34, A32).
--
-- The PRD ratio is, per completed quarter, all visits with systolic 130-139
-- divided by all visits with systolic 140-149. Seed 10 planted PHC-E's bunching
-- in the 2026-10 three-month window only, so on the PRD's last 4 completed
-- quarters (2025-Q4 to 2026-Q3) PHC-E looked normal and PHC-A and PHC-B were
-- flagged. This seed adds visits so that:
--   * PHC-E is flagged and rising: about 2.10 in 2026-Q2 and 2.35 in 2026-Q3
--     (extra 133-139 readings);
--   * PHC-A to D and F sit at or below 1.65 in each of the 4 quarters (extra
--     genuine 140-149 readings), under the 1.8 warning line.
--
-- How the other October 2026 targets (CLINICAL-RULES section 7) stay put. Each
-- new visit goes into a gap between two existing visits of the same patient,
-- e1 < new < e2, with e2 before 2026-08-01, so:
--   * it is never a patient's latest visit or latest prescription (control,
--     statins), never the first visit (new-patient cohort and its first date),
--     and patients whose first visit is in the 2026-10 new-patient cohort
--     (2026-05-05 to 2026-08-02) are skipped;
--   * it is before the 2026-10 window (2026-08-03 to 2026-10-31), so the
--     3-month bunching score and the stepping-up visits do not see it, and e2
--     stays the baseline of any later visit;
--   * e2 is before 2026-08-01, so "last visit before the month" for the calling
--     months Aug to Oct does not change.
-- Each new visit gets a BP row and one prescription that copies e1's text, so
-- the regimen does not change. Encounter org unit = the patient's org unit.
--
-- Counts are worked out from the database at run time, so they are
-- deterministic for a given cohort. Every choice is md5(id || ':' || salt).
-- Insert only; a second run hits the marker and stops.
SET ROLE heart360tk;
SET search_path TO heart360tk_schema, public;

CREATE TABLE IF NOT EXISTS demo_seed_marker (
    seed       text PRIMARY KEY,
    anchor     date NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

DO $do$
DECLARE
    c_gap_end   constant timestamp := TIMESTAMP '2026-08-01';
    c_np_from   constant date      := DATE '2026-05-05';
    c_np_to     constant date      := DATE '2026-08-02';
    c_others    constant numeric   := 1.65;  -- ceiling for PHC-A to D and F
    v_anchor    date;
    v_name      text;
    v_fac       integer;
    v_q         date;
    v_goal      numeric;
    v_a         integer;
    v_b         integer;
    v_add       integer;
    v_got       integer;
    v_total     integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM demo_seed_marker WHERE seed = '50_fudging_quarters') THEN
        RAISE NOTICE '50_fudging_quarters already applied';
        RETURN;
    END IF;

    SELECT COALESCE(
        (SELECT anchor FROM demo_seed_marker WHERE seed = '10_visits'),
        (SELECT MAX(encounter_date)::date FROM encounters),
        DATE '2026-10-13'
    ) INTO v_anchor;

    FOR v_name, v_fac IN
        SELECT n.name, ou.id
        FROM unnest(ARRAY['PHC-A','PHC-B','PHC-C','PHC-D','PHC-E','PHC-F']) AS n(name)
        JOIN LATERAL (
            SELECT id FROM org_units
            WHERE name = n.name AND level = 3
            ORDER BY id
            LIMIT 1
        ) AS ou ON true
        ORDER BY n.name
    LOOP
        FOR v_q IN
            SELECT gs::date
            FROM generate_series(DATE '2025-10-01', DATE '2026-07-01', INTERVAL '3 months') AS gs
        LOOP
            SELECT
                count(*) FILTER (WHERE bp.systolic_bp >= 130 AND bp.systolic_bp < 140),
                count(*) FILTER (WHERE bp.systolic_bp >= 140 AND bp.systolic_bp < 150)
              INTO v_a, v_b
            FROM encounters e
            JOIN blood_pressures bp ON bp.encounter_id = e.id
            JOIN patients p ON p.patient_id = e.patient_id
            WHERE p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
              AND e.encounter_date >= v_q
              AND e.encounter_date <  v_q + INTERVAL '3 months';

            IF v_name = 'PHC-E' THEN
                -- Leave 2025-Q4 and 2026-Q1 as they are; flag and rise after.
                v_goal := CASE v_q WHEN DATE '2026-04-01' THEN 2.10
                                   WHEN DATE '2026-07-01' THEN 2.35 END;
                IF v_goal IS NULL OR v_b = 0 THEN
                    CONTINUE;
                END IF;
                v_add := GREATEST(0, ceil(v_goal * v_b)::integer - v_a);
            ELSE
                v_add := GREATEST(0, ceil(v_a / c_others)::integer - v_b);
            END IF;
            v_add := LEAST(v_add, 400);
            IF v_add = 0 THEN
                CONTINUE;
            END IF;

            WITH pe AS (
                SELECT p.patient_id,
                       p.org_unit_id,
                       e.id             AS e1_id,
                       e.encounter_date AS e1_at,
                       lead(e.encounter_date) OVER w AS e2_at,
                       min(e.encounter_date) OVER (PARTITION BY p.patient_id) AS first_at
                FROM patients p
                JOIN encounters e ON e.patient_id = p.patient_id
                WHERE p.org_unit_id IN (SELECT id FROM get_descendant_ids(v_fac))
                  AND p.patient_status IS DISTINCT FROM 'DEAD'
                WINDOW w AS (PARTITION BY p.patient_id ORDER BY e.encounter_date, e.id)
            ),
            gaps AS (
                -- Days inside the quarter that lie strictly between e1 and e2.
                SELECT pe.*,
                       GREATEST(pe.e1_at::date + 1, v_q)                                AS d_from,
                       LEAST(pe.e2_at::date - 1, (v_q + INTERVAL '3 months')::date - 1) AS d_to
                FROM pe
                WHERE pe.e2_at IS NOT NULL
                  AND pe.e2_at < c_gap_end
                  AND pe.first_at::date NOT BETWEEN c_np_from AND c_np_to
                  AND EXISTS (SELECT 1 FROM prescriptions r WHERE r.encounter_id = pe.e1_id)
            ),
            picked AS (
                SELECT g.patient_id,
                       g.org_unit_id,
                       g.e1_id,
                       g.d_from
                         + (demo_seed_hash(g.e1_id::text || ':fudq-day') % (g.d_to - g.d_from + 1))::integer
                         + TIME '09:00'
                         + (demo_seed_hash(g.e1_id::text || ':fudq-min') % 480) * INTERVAL '1 minute'
                         AS visit_at,
                       CASE WHEN v_name = 'PHC-E'
                            THEN 133 + demo_seed_hash(g.e1_id::text || ':fudq-sbp') % 7
                            ELSE 140 + demo_seed_hash(g.e1_id::text || ':fudq-sbp') % 10
                       END AS sbp,
                       CASE WHEN v_name = 'PHC-E'
                            THEN 78 + demo_seed_hash(g.e1_id::text || ':fudq-dbp') % 10
                            ELSE 82 + demo_seed_hash(g.e1_id::text || ':fudq-dbp') % 12
                       END AS dbp
                FROM gaps g
                WHERE g.d_to >= g.d_from
                ORDER BY md5(g.e1_id::text || ':fudq:' || v_name)
                LIMIT v_add
            ),
            ins AS (
                INSERT INTO encounters (patient_id, encounter_date, org_unit_id)
                SELECT patient_id, visit_at, org_unit_id FROM picked
                ON CONFLICT DO NOTHING
                RETURNING id, patient_id, encounter_date
            ),
            ins_bp AS (
                INSERT INTO blood_pressures (encounter_id, systolic_bp, diastolic_bp)
                SELECT ins.id, picked.sbp, picked.dbp
                FROM ins
                JOIN picked ON picked.patient_id = ins.patient_id
                           AND picked.visit_at   = ins.encounter_date
                ON CONFLICT DO NOTHING
                RETURNING encounter_id
            )
            INSERT INTO prescriptions (encounter_id, obat_raw, source)
            SELECT ins.id, r.obat_raw, 'demo'
            FROM ins
            JOIN picked ON picked.patient_id = ins.patient_id
                       AND picked.visit_at   = ins.encounter_date
            JOIN prescriptions r ON r.encounter_id = picked.e1_id
            ON CONFLICT DO NOTHING;

            GET DIAGNOSTICS v_got = ROW_COUNT;
            v_total := v_total + v_got;
            RAISE NOTICE '50_fudging_quarters % %: 130-139 % / 140-149 %, added % of % (%)',
                v_name, to_char(v_q, 'YYYY-"Q"Q'), v_a, v_b, v_got, v_add,
                CASE WHEN v_name = 'PHC-E' THEN '133-139' ELSE '140-149' END;
        END LOOP;
    END LOOP;

    INSERT INTO demo_seed_marker (seed, anchor, applied_at)
    VALUES ('50_fudging_quarters', v_anchor, clock_timestamp())
    ON CONFLICT DO NOTHING;

    RAISE NOTICE '50_fudging_quarters applied, % visits', v_total;
END
$do$;
