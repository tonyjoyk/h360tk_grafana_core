-- 0.6.14_to_0.6.15: drug stock entry form write path (story 3.5, AD-16, AD-19, AD-21)
--
-- save_drug_stock_entry  the Drug Stock board's `Enter stock` form, through h360-api only.
--   Identity arguments come from h360-api, which takes them from Grafana /api/user and
--   /api/user/teams (AD-16). heart360tk cannot read grafana_schema, so the login, email,
--   admin flag and team names are arguments, as in save_call_result.
--   Rows go through drug_stock_pull_apply, the only writer of drug stock rows, so Latest Wins
--   and the history table apply exactly as for the Google Form pull (AD-19).
--   submitted_by = the Grafana email (the login when there is none); submitted_at = now().
--
-- Returns {"ok": true, accepted, rejected, stored, kept_newer, rejects: [...]} or
-- {"ok": false, "error": <code>, "message": <sentence>} with codes bad_request, forbidden,
-- not_found, not_facility, bad_month. A refused call writes nothing.
--   accepted    valid entries written to history (drug_stock_pull_apply's count)
--   rejected    entries refused here: not a protocol drug and strength, a repeat of a drug in
--               the same call, or a stock that is not a whole number from 0 to 1,000,000
--   stored      accepted entries that are now the facility's current value
--   kept_newer  accepted entries that stayed behind a newer submission (Latest Wins)
--
-- Grants: EXECUTE to h360_api only (Grant matrix).
-- One transaction, idempotent, safe to re-run.
BEGIN;

SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

CREATE OR REPLACE FUNCTION save_drug_stock_entry(
    p_actor_login text,
    p_actor_email text,
    p_is_admin boolean,
    p_team_names text[],
    p_org_unit_id integer,
    p_month date,
    p_entries jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = heart360tk_schema, pg_temp
AS $$
DECLARE
    v_max_stock  constant numeric := 1000000;
    v_max_rows   constant integer := 100;
    v_login      text := NULLIF(btrim(COALESCE(p_actor_login, '')), '');
    v_by         text;
    v_now        timestamptz := now();
    v_level      integer;
    v_fac_level  integer;
    v_entry      jsonb;
    v_code       text;
    v_stock_json jsonb;
    v_stock      numeric;
    v_reason     text;
    v_seen       text[] := ARRAY[]::text[];
    v_rows       jsonb := '[]'::jsonb;
    v_rejects    jsonb := '[]'::jsonb;
    v_accepted   integer := 0;
    v_rejected   integer := 0;
    v_stored     integer := 0;
BEGIN
    IF v_login IS NULL OR p_org_unit_id IS NULL OR p_month IS NULL
       OR p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array'
       OR jsonb_array_length(p_entries) = 0
       OR jsonb_array_length(p_entries) > v_max_rows THEN
        RETURN jsonb_build_object('ok', false, 'error', 'bad_request',
            'message', 'The request is missing the user, the place, the month or the stock.');
    END IF;

    -- Access first, so a refused caller learns nothing about the place.
    IF NOT h360_access_allows(COALESCE(p_is_admin, false), p_team_names, p_org_unit_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'forbidden',
            'message', 'You do not have access to this place.');
    END IF;

    SELECT ou.level INTO v_level FROM org_units ou WHERE ou.id = p_org_unit_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_found',
            'message', 'No place has this ID.');
    END IF;

    SELECT hc.level INTO v_fac_level FROM hierarchy_config hc WHERE hc.var_name = 'facility';
    IF v_level IS DISTINCT FROM COALESCE(v_fac_level, 3)
       OR NOT EXISTS (SELECT 1 FROM drug_stock_form_cohort c WHERE c.org_unit_id = p_org_unit_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_facility',
            'message', 'Pick one facility to enter stock.');
    END IF;

    IF p_month <> date_trunc('month', p_month)::date
       OR p_month > date_trunc('month', v_now)::date THEN
        RETURN jsonb_build_object('ok', false, 'error', 'bad_month',
            'message', 'The month must be the first day of this month or an earlier one.');
    END IF;

    v_by := COALESCE(NULLIF(lower(btrim(COALESCE(p_actor_email, ''))), ''), lower(v_login));

    FOR v_entry IN SELECT e FROM jsonb_array_elements(p_entries) AS e LOOP
        v_reason := NULL;
        v_code := NULL;
        v_stock := NULL;

        IF jsonb_typeof(v_entry) IS DISTINCT FROM 'object' THEN
            v_reason := 'invalid_entry';
        ELSE
            v_code := btrim(COALESCE(v_entry->>'drug_code', ''));
            v_stock_json := v_entry->'stock';
            IF v_code = '' OR NOT EXISTS (
                SELECT 1 FROM active_stock_tracked_drugs d WHERE d.rxnorm_code = v_code
            ) THEN
                v_reason := 'not_protocol_drug';
            ELSIF v_code = ANY (v_seen) THEN
                v_reason := 'repeated_drug';
            ELSIF v_stock_json IS NULL OR jsonb_typeof(v_stock_json) = 'null' THEN
                v_stock := NULL;  -- blank: not counted, stays unknown
            ELSIF jsonb_typeof(v_stock_json) <> 'number' THEN
                v_reason := 'invalid_stock';
            ELSE
                v_stock := (v_stock_json #>> '{}')::numeric;
                IF v_stock <> trunc(v_stock) OR v_stock < 0 OR v_stock > v_max_stock THEN
                    v_reason := 'invalid_stock';
                END IF;
            END IF;
        END IF;

        IF v_reason IS NOT NULL THEN
            v_rejected := v_rejected + 1;
            v_rejects := v_rejects || jsonb_build_array(jsonb_build_object(
                'drug_code', NULLIF(v_code, ''), 'reason', v_reason));
        ELSE
            v_seen := v_seen || v_code;
            v_rows := v_rows || jsonb_build_array(jsonb_build_object(
                'org_unit_id', p_org_unit_id::text,
                'reporting_month', to_char(p_month, 'YYYY-MM'),
                'drug_code', v_code,
                'in_stock', CASE WHEN v_stock IS NULL THEN NULL ELSE trunc(v_stock)::bigint::text END,
                'submitted_at', v_now,
                'submitted_by', v_by,
                'sheet_row', NULL
            ));
        END IF;
    END LOOP;

    IF jsonb_array_length(v_rows) > 0 THEN
        -- Runs as heart360tk (this function's owner), the only role the writer accepts.
        SELECT a.accepted, v_rejected + a.rejected
          INTO v_accepted, v_rejected
          FROM drug_stock_pull_apply(v_rows) AS a;

        SELECT count(*)::integer INTO v_stored
        FROM drug_stock_submission s
        WHERE s.org_unit_id = p_org_unit_id
          AND s.reporting_month = p_month
          AND s.rxnorm_code = ANY (v_seen)
          AND s.submitted_at = v_now
          AND s.submitted_by IS NOT DISTINCT FROM v_by;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'org_unit_id', p_org_unit_id,
        'month', to_char(p_month, 'YYYY-MM-DD'),
        'accepted', v_accepted,
        'rejected', v_rejected,
        'stored', v_stored,
        'kept_newer', v_accepted - v_stored,
        'rejects', v_rejects
    );
END;
$$;

COMMENT ON FUNCTION save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb) IS
    'Drug Stock board Enter stock form write for h360-api: gated by h360_access_allows on a cohort facility, validates protocol drug and whole-number stock 0..1,000,000 (NULL = not counted), writes through drug_stock_pull_apply (Latest Wins + history) with submitted_by = Grafana email and submitted_at = now().';

REVOKE ALL ON FUNCTION save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'h360_api') THEN
        GRANT EXECUTE ON FUNCTION heart360tk_schema.save_drug_stock_entry(text, text, boolean, text[], integer, date, jsonb) TO h360_api;
    END IF;
END $$;

COMMIT;
