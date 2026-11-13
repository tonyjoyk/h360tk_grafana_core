-- 0.6.5_to_0.6.6: security: read-only roles, grants, h360_access_allows, save_call_result (AD-14, AD-15, AD-16)
--
-- Roles (Grant matrix in the architecture spine):
--   heart360tk_reader  postgres-hypertension   SELECT both schemas, read helpers, read-only sessions
--   heart360tk_cached  postgres-hypertension-cached   existing SELECT grants, read-only sessions
--   grafana_reader     postgres-grafana        heart360tk reads `grafana` had; grafana_schema column
--                                              grants live in db_grants/grafana_reader_grants.sql
--   h360_api           h360-api                EXECUTE h360_access_allows, save_call_result only
-- Passwords are local-demo literals; db_grants/apply.sh resets h360_api from H360_API_DB_PASSWORD.
--
-- One transaction, idempotent, safe to re-run.
BEGIN;

-- Role DDL and ALTER ROLE ... SET need the superuser session that runs the init scripts.
RESET ROLE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader') THEN
        CREATE ROLE heart360tk_reader LOGIN PASSWORD 'h360tk_reader_mvp';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader') THEN
        CREATE ROLE grafana_reader LOGIN PASSWORD 'grafana_reader_mvp';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'h360_api') THEN
        CREATE ROLE h360_api LOGIN PASSWORD 'h360_api_mvp';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_cached') THEN
        CREATE ROLE heart360tk_cached LOGIN PASSWORD 'Y2FjaGVkX3JlYWRvbmx5X3VzZXI=';
    END IF;
END $$;

ALTER ROLE heart360tk_reader NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN;
ALTER ROLE heart360tk_cached NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN;
ALTER ROLE grafana_reader    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN;
ALTER ROLE h360_api          NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN;

-- heart360tk_reader resolves names exactly as the owner role did, so panel SQL is unchanged.
ALTER ROLE heart360tk_reader SET search_path = heart360tk_schema, heart360tk_reporting, public;
ALTER ROLE grafana_reader    SET search_path = grafana_schema, public;
ALTER ROLE h360_api          SET search_path = heart360tk_schema, public;

-- Second layer only: a session can switch this off, so privileges below are what block writes.
-- grafana_reader and h360_api stay read-write: start_async_refresh and save_call_result are
-- definer functions that write, and a read-only transaction would refuse them too.
ALTER ROLE heart360tk_reader SET default_transaction_read_only = on;
ALTER ROLE heart360tk_cached SET default_transaction_read_only = on;

-- No login role may inherit the owner's privileges.
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['heart360tk_reader', 'heart360tk_cached', 'grafana_reader', 'h360_api'] LOOP
        IF EXISTS (
            SELECT 1 FROM pg_auth_members m
            WHERE m.roleid = 'heart360tk'::regrole AND m.member = r::regrole
        ) THEN
            EXECUTE format('REVOKE heart360tk FROM %I', r);
        END IF;
    END LOOP;
END $$;

-- ============================================================================
-- AD-15: no routine is executable by PUBLIC unless granted below.
-- The global form is required: the IN SCHEMA form cannot revoke the global PUBLIC default.
-- ============================================================================
ALTER DEFAULT PRIVILEGES FOR ROLE heart360tk REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA heart360tk_schema    FROM PUBLIC;
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA heart360tk_reporting FROM PUBLIC;

-- The Grafana server role owns grafana_schema only; it no longer backs a datasource.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana') THEN
        REVOKE ALL ON ALL TABLES    IN SCHEMA heart360tk_schema    FROM grafana;
        REVOKE ALL ON ALL TABLES    IN SCHEMA heart360tk_reporting FROM grafana;
        REVOKE ALL ON ALL ROUTINES  IN SCHEMA heart360tk_schema    FROM grafana;
        REVOKE ALL ON ALL ROUTINES  IN SCHEMA heart360tk_reporting FROM grafana;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA heart360tk_schema    FROM grafana;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA heart360tk_reporting FROM grafana;
        REVOKE ALL ON SCHEMA heart360tk_schema    FROM grafana;
        REVOKE ALL ON SCHEMA heart360tk_reporting FROM grafana;
    END IF;
END $$;

-- ============================================================================
-- Table and schema grants
-- ============================================================================
GRANT USAGE ON SCHEMA heart360tk_schema, heart360tk_reporting TO heart360tk_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA heart360tk_schema    TO heart360tk_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA heart360tk_reporting TO heart360tk_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE heart360tk IN SCHEMA heart360tk_schema
    GRANT SELECT ON TABLES TO heart360tk_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE heart360tk IN SCHEMA heart360tk_reporting
    GRANT SELECT ON TABLES TO heart360tk_reader;

-- heart360tk_cached keeps its existing grants: all of heart360tk_reporting, a few schema tables.
GRANT USAGE ON SCHEMA heart360tk_schema, heart360tk_reporting TO heart360tk_cached;
GRANT SELECT ON ALL TABLES IN SCHEMA heart360tk_reporting TO heart360tk_cached;
ALTER DEFAULT PRIVILEGES FOR ROLE heart360tk IN SCHEMA heart360tk_reporting
    GRANT SELECT ON TABLES TO heart360tk_cached;

-- grafana_reader gets the heart360tk reads the `grafana` role had.
GRANT USAGE ON SCHEMA heart360tk_schema, heart360tk_reporting TO grafana_reader;
GRANT SELECT ON heart360tk_schema.org_units, heart360tk_schema.hierarchy_config,
    heart360tk_schema.org_unit_lineage TO grafana_reader;
DO $$
BEGIN
    IF to_regclass('heart360tk_reporting.drug_stock_patient_days') IS NOT NULL THEN
        GRANT SELECT ON heart360tk_reporting.drug_stock_patient_days TO grafana_reader;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'grafana_schema') THEN
        GRANT USAGE ON SCHEMA grafana_schema TO grafana_reader;
    END IF;
END $$;

-- h360_api: schema usage only; every table is reached through definer functions.
GRANT USAGE ON SCHEMA heart360tk_schema TO h360_api;

-- ============================================================================
-- Routine grants for existing functions. Anything not listed (refresh, purge,
-- upsert_org_unit*, drug_stock_pull_apply, h360tk_admin_clean_data) is owner-only.
-- ============================================================================
DO $$
DECLARE
    v_grant record;
BEGIN
    FOR v_grant IN
        SELECT g.sig, g.grantee
        FROM (VALUES
            -- invoker read helpers used by panel SQL
            ('heart360tk_schema.get_descendant_ids(integer)',                       'heart360tk_reader'),
            ('heart360tk_schema.get_ancestor_name(integer, integer)',               'heart360tk_reader'),
            ('heart360tk_schema.get_breadcrumb_path(integer)',                      'heart360tk_reader'),
            ('heart360tk_schema.build_drill_url(integer)',                          'heart360tk_reader'),
            ('heart360tk_schema.get_child_level_name(integer)',                     'heart360tk_reader'),
            ('heart360tk_schema.get_access_groups(integer, character varying)',     'heart360tk_reader'),
            ('heart360tk_reporting.drug_stock_on_hand_matrix(date, integer)',       'heart360tk_reader'),
            ('heart360tk_schema.get_descendant_ids(integer)',                       'heart360tk_cached'),
            ('heart360tk_schema.get_ancestor_name(integer, integer)',               'heart360tk_cached'),
            ('heart360tk_schema.get_breadcrumb_path(integer)',                      'heart360tk_cached'),
            ('heart360tk_schema.build_drill_url(integer)',                          'heart360tk_cached'),
            ('heart360tk_schema.get_child_level_name(integer)',                     'heart360tk_cached'),
            ('heart360tk_schema.get_access_groups(integer, character varying)',     'heart360tk_cached'),
            ('heart360tk_reporting.drug_stock_on_hand_matrix(date, integer)',       'heart360tk_cached'),
            ('heart360tk_schema.get_access_groups(integer, character varying)',     'grafana_reader'),
            ('heart360tk_schema.get_user_visible_org_units(integer)',               'grafana_reader'),
            ('heart360tk_reporting.start_async_refresh(text)',                      'grafana_reader')
        ) AS g(sig, grantee)
    LOOP
        IF to_regprocedure(v_grant.sig) IS NOT NULL THEN
            EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO %I', v_grant.sig, v_grant.grantee);
        END IF;
    END LOOP;
END $$;

-- Existing definer function: pin its search path (it only uses qualified names).
DO $$
BEGIN
    IF to_regprocedure('heart360tk_reporting.start_async_refresh(text)') IS NOT NULL THEN
        ALTER FUNCTION heart360tk_reporting.start_async_refresh(text)
            SET search_path = heart360tk_reporting, pg_temp;
    END IF;
END $$;

-- ============================================================================
-- Objects owned by heart360tk
-- ============================================================================
SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

-- One row per accepted save_call_result call. No foreign keys, so purges of patients or
-- org units do not erase the audit trail.
CREATE TABLE IF NOT EXISTS call_results_audit (
    audit_id        BIGSERIAL PRIMARY KEY,
    call_id         BIGINT,
    patient_id      BIGINT NOT NULL,
    org_unit_id     INTEGER,
    call_date       DATE NOT NULL,
    status          VARCHAR(255) NOT NULL,
    result_type     VARCHAR(255),
    previous_status VARCHAR(255),
    actor_login     TEXT NOT NULL,
    actor_id        BIGINT,
    actor_is_admin  BOOLEAN NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_call_results_audit_patient_id  ON call_results_audit(patient_id);
CREATE INDEX IF NOT EXISTS idx_call_results_audit_recorded_at ON call_results_audit(recorded_at);

REVOKE ALL ON TABLE call_results_audit FROM PUBLIC;
GRANT SELECT ON TABLE call_results_audit TO heart360tk_reader;

-- ----------------------------------------------------------------------------
-- h360_access_allows: the program dashboard `isAllowed` variable, clause for clause.
--   p_is_admin     Grafana isGrafanaAdmin (grafana_schema."user".is_admin)
--   p_team_names   the user's Grafana team names
--   p_org_unit_id  the node; NULL or 0 means "all places"
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION h360_access_allows(
    p_is_admin boolean,
    p_team_names text[],
    p_org_unit_id integer
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
AS $$
DECLARE
    v_node integer := NULLIF(p_org_unit_id, 0);
BEGIN
    IF COALESCE(p_is_admin, false) THEN
        RETURN true;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM unnest(COALESCE(p_team_names, ARRAY[]::text[])) AS t(name)
        WHERE (
                v_node IS NULL
                AND EXISTS (
                    SELECT 1
                    FROM hierarchy_config hc
                    WHERE t.name IN (
                        'heart360tk_' || hc.var_name || '_view_aggregated_ALL',
                        'heart360tk_' || hc.var_name || '_view_patients_ALL'
                    )
                )
            )
            OR (
                v_node IS NOT NULL
                AND (
                    t.name IN (
                        SELECT (SELECT group_name FROM get_access_groups(lin.ancestor_id, 'aggregated') LIMIT 1)
                        FROM org_unit_lineage lin
                        WHERE lin.org_unit_id = v_node
                        UNION
                        SELECT (SELECT group_name FROM get_access_groups(lin.ancestor_id, 'patients') LIMIT 1)
                        FROM org_unit_lineage lin
                        WHERE lin.org_unit_id = v_node
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM hierarchy_config hc
                        WHERE t.name IN (
                            'heart360tk_' || hc.var_name || '_view_aggregated_ALL',
                            'heart360tk_' || hc.var_name || '_view_patients_ALL'
                        )
                          AND hc.level <= (
                            SELECT level FROM org_units
                            WHERE id = v_node
                            LIMIT 1
                          )
                    )
                )
            )
    );
END;
$$;

COMMENT ON FUNCTION h360_access_allows(boolean, text[], integer) IS
    'Program dashboard isAllowed rule: admin; an _ALL team when no node; a team of the node or an ancestor (get_access_groups aggregated|patients); an _ALL team at a level <= the node level.';

REVOKE ALL ON FUNCTION h360_access_allows(boolean, text[], integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION h360_access_allows(boolean, text[], integer) TO h360_api;

-- ----------------------------------------------------------------------------
-- save_call_result: the only runtime write. Same upsert the Overdue tab ran, behind the
-- access rule, plus one audit row. Identity arguments come from h360-api, which takes them
-- from Grafana /api/user and /api/user/teams.
-- Returns {"ok": true, ...} or {"ok": false, "error": <code>, "message": <sentence>} with
-- codes bad_request, not_found, bad_status, forbidden. Rejections write nothing.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION save_call_result(
    p_actor_login text,
    p_actor_id bigint,
    p_is_admin boolean,
    p_team_names text[],
    p_patient_id bigint,
    p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
AS $$
DECLARE
    v_statuses constant text[] := ARRAY[
        'Pending to call',
        'Agreed to visit',
        'Call again later',
        'Already visited puskesmas',
        'Multiple failed contact attempts',
        'Wrong phone number',
        'Moved out of catchment area',
        'Transferred to another puskesmas',
        'Refused to return',
        'Died',
        'Other reason'
    ];
    v_is_admin    boolean := COALESCE(p_is_admin, false);
    v_org_unit_id integer;
    v_result_type text;
    v_previous    text;
    v_call_id     bigint;
    v_audit_id    bigint;
BEGIN
    IF NULLIF(btrim(COALESCE(p_actor_login, '')), '') IS NULL OR p_patient_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'bad_request',
            'message', 'The request is missing the user or the patient.');
    END IF;

    SELECT p.org_unit_id INTO v_org_unit_id
    FROM patients p
    WHERE p.patient_id = p_patient_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_found',
            'message', 'No patient has this ID.');
    END IF;

    IF p_status IS NULL OR NOT (p_status = ANY (v_statuses)) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'bad_status',
            'message', 'This call result is not one of the overdue list options.');
    END IF;

    -- The Overdue tab offers no status options on a central node.
    IF COALESCE(current_setting('app.is_central_node', true), 'false') = 'true' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'forbidden',
            'message', 'Call results cannot be saved on the central node.');
    END IF;

    -- A patient without a place is in no overdue list; only an admin may record it.
    IF NOT (
        v_is_admin
        OR (v_org_unit_id IS NOT NULL AND h360_access_allows(false, p_team_names, v_org_unit_id))
    ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'forbidden',
            'message', 'You do not have access to this patient''s place.');
    END IF;

    v_result_type := CASE
        WHEN p_status IN ('Agreed to visit', 'Pending to call', 'Call again later') THEN NULL
        ELSE 'removed_from_overdue_list'
    END;

    SELECT cr.removed_reason INTO v_previous
    FROM call_results cr
    WHERE cr.patient_id = p_patient_id AND cr.call_date = CURRENT_DATE;

    INSERT INTO call_results (patient_id, call_date, result_type, removed_reason, org_unit_id)
    VALUES (p_patient_id, CURRENT_DATE, v_result_type, p_status, v_org_unit_id)
    ON CONFLICT (patient_id, call_date) DO UPDATE SET
        result_type = EXCLUDED.result_type,
        removed_reason = EXCLUDED.removed_reason
    RETURNING call_id INTO v_call_id;

    INSERT INTO call_results_audit (
        call_id, patient_id, org_unit_id, call_date, status, result_type, previous_status,
        actor_login, actor_id, actor_is_admin
    )
    VALUES (
        v_call_id, p_patient_id, v_org_unit_id, CURRENT_DATE, p_status, v_result_type, v_previous,
        btrim(p_actor_login), p_actor_id, v_is_admin
    )
    RETURNING audit_id INTO v_audit_id;

    RETURN jsonb_build_object(
        'ok', true,
        'patient_id', p_patient_id::text,
        'call_date', to_char(CURRENT_DATE, 'YYYY-MM-DD'),
        'status', p_status,
        'result_type', v_result_type,
        'org_unit_id', v_org_unit_id,
        'call_id', v_call_id,
        'audit_id', v_audit_id
    );
END;
$$;

COMMENT ON FUNCTION save_call_result(text, bigint, boolean, text[], bigint, text) IS
    'Overdue call result write for h360-api: upsert on (patient_id, CURRENT_DATE) as the Overdue tab did, gated by h360_access_allows on the patient org unit, with one call_results_audit row.';

REVOKE ALL ON FUNCTION save_call_result(text, bigint, boolean, text[], bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_call_result(text, bigint, boolean, text[], bigint, text) TO h360_api;

COMMIT;
