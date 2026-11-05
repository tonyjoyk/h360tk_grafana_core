BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

CREATE TABLE IF NOT EXISTS drug_stock_submission (
    org_unit_id     INTEGER NOT NULL REFERENCES org_units (id),
    reporting_month DATE NOT NULL,
    rxnorm_code     VARCHAR(64) NOT NULL,
    country_code    VARCHAR(64) NOT NULL,
    programme_code  VARCHAR(64) NOT NULL,
    in_stock        NUMERIC,
    submitted_at    TIMESTAMPTZ,
    pulled_at       TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (org_unit_id, reporting_month, rxnorm_code),
    CONSTRAINT drug_stock_submission_protocol_drug_fkey
        FOREIGN KEY (country_code, programme_code, rxnorm_code)
        REFERENCES protocol_drugs (country_code, programme_code, rxnorm_code),
    CONSTRAINT drug_stock_submission_reporting_month_first
        CHECK (reporting_month = date_trunc('month', reporting_month)::date)
);

CREATE TABLE IF NOT EXISTS drug_stock_submission_reject (
    org_unit_id     TEXT,
    reporting_month TEXT,
    drug_code       TEXT,
    in_stock        TEXT,
    submitted_at    TEXT,
    reason          TEXT NOT NULL,
    pulled_at       TIMESTAMPTZ NOT NULL
);

CREATE OR REPLACE FUNCTION drug_stock_pull_apply(rows jsonb)
RETURNS TABLE (accepted integer, rejected integer)
LANGUAGE plpgsql
SET search_path = heart360tk_schema
AS $$
DECLARE
    v_row             jsonb;
    v_org_text        text;
    v_month_text      text;
    v_drug_text       text;
    v_stock_text      text;
    v_submitted_text  text;
    v_month_trim      text;
    v_org_id          integer;
    v_month           date;
    v_mon             integer;
    v_stock           numeric;
    v_submitted       timestamptz;
    v_country         varchar(64);
    v_programme       varchar(64);
    v_reason          text;
    v_accepted        integer := 0;
    v_rejected        integer := 0;
    v_pulled_at       timestamptz := transaction_timestamp();
BEGIN
    IF current_user <> 'heart360tk' THEN
        RAISE EXCEPTION 'drug stock pull writer must be heart360tk';
    END IF;

    IF rows IS NULL OR jsonb_typeof(rows) <> 'array' THEN
        RAISE EXCEPTION 'drug stock pull expects a JSON array of long rows';
    END IF;

    SELECT s.country_code, s.programme_code
      INTO v_country, v_programme
      FROM deploy_setting s
     WHERE s.setting_name = 'active_programme';

    IF v_country IS NULL OR v_programme IS NULL THEN
        RAISE EXCEPTION 'active_programme deploy setting is missing';
    END IF;

    FOR v_row IN
        SELECT jsonb_array_elements(rows)
    LOOP
        v_org_text := NULL;
        v_month_text := NULL;
        v_drug_text := NULL;
        v_stock_text := NULL;
        v_submitted_text := NULL;
        v_org_id := NULL;
        v_month := NULL;
        v_stock := NULL;
        v_submitted := NULL;
        v_reason := NULL;

        IF jsonb_typeof(v_row) IS DISTINCT FROM 'object' THEN
            v_reason := 'invalid_row';
        ELSE
            v_org_text := v_row->>'org_unit_id';
            v_month_text := v_row->>'reporting_month';
            v_drug_text := v_row->>'drug_code';
            v_stock_text := v_row->>'in_stock';
            v_submitted_text := v_row->>'submitted_at';

            v_month_trim := btrim(COALESCE(v_month_text, ''));
            IF v_month_trim ~ '^[0-9]{4}-[0-9]{2}$' THEN
                v_mon := substring(v_month_trim, 6, 2)::integer;
                IF v_mon < 1 OR v_mon > 12 THEN
                    v_reason := 'invalid_reporting_month';
                ELSE
                    BEGIN
                        v_month := make_date(substring(v_month_trim, 1, 4)::integer, v_mon, 1);
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_reason := 'invalid_reporting_month';
                    END;
                END IF;
            ELSIF v_month_trim ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
                v_mon := substring(v_month_trim, 6, 2)::integer;
                IF v_mon < 1 OR v_mon > 12 THEN
                    v_reason := 'invalid_reporting_month';
                ELSE
                    BEGIN
                        v_month := date_trunc('month', v_month_trim::date)::date;
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_reason := 'invalid_reporting_month';
                    END;
                END IF;
            ELSE
                v_reason := 'invalid_reporting_month';
            END IF;

            IF v_reason IS NULL THEN
                IF v_org_text IS NULL OR btrim(v_org_text) !~ '^[0-9]+$' THEN
                    v_reason := 'unknown_org_unit';
                ELSE
                    BEGIN
                        v_org_id := btrim(v_org_text)::integer;
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_reason := 'unknown_org_unit';
                    END;
                    IF v_reason IS NULL AND NOT EXISTS (
                        SELECT 1 FROM org_units WHERE id = v_org_id
                    ) THEN
                        v_reason := 'unknown_org_unit';
                    END IF;
                END IF;
            END IF;

            IF v_reason IS NULL THEN
                IF v_drug_text IS NULL OR btrim(v_drug_text) = '' OR NOT EXISTS (
                    SELECT 1
                    FROM active_stock_tracked_drugs d
                    WHERE d.rxnorm_code = btrim(v_drug_text)
                ) THEN
                    v_reason := 'drug_not_active';
                END IF;
            END IF;

            IF v_reason IS NULL THEN
                IF v_stock_text IS NULL OR btrim(v_stock_text) IN ('', '?') THEN
                    v_stock := NULL;
                ELSE
                    BEGIN
                        v_stock := btrim(v_stock_text)::numeric;
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_reason := 'invalid_in_stock';
                    END;
                END IF;
            END IF;

            IF v_reason IS NULL THEN
                IF v_submitted_text IS NULL OR btrim(v_submitted_text) = '' THEN
                    v_submitted := NULL;
                ELSE
                    BEGIN
                        v_submitted := btrim(v_submitted_text)::timestamptz;
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_reason := 'invalid_submitted_at';
                    END;
                END IF;
            END IF;
        END IF;

        IF v_reason IS NOT NULL THEN
            DELETE FROM drug_stock_submission_reject
            WHERE org_unit_id IS NOT DISTINCT FROM v_org_text
              AND reporting_month IS NOT DISTINCT FROM v_month_text
              AND drug_code IS NOT DISTINCT FROM v_drug_text
              AND reason = v_reason;

            INSERT INTO drug_stock_submission_reject (
                org_unit_id, reporting_month, drug_code, in_stock, submitted_at, reason, pulled_at
            ) VALUES (
                v_org_text, v_month_text, v_drug_text, v_stock_text, v_submitted_text,
                v_reason, v_pulled_at
            );
            v_rejected := v_rejected + 1;
        ELSE
            INSERT INTO drug_stock_submission (
                org_unit_id, reporting_month, rxnorm_code,
                country_code, programme_code,
                in_stock, submitted_at, pulled_at
            ) VALUES (
                v_org_id, v_month, btrim(v_drug_text),
                v_country, v_programme,
                v_stock, v_submitted, v_pulled_at
            )
            ON CONFLICT (org_unit_id, reporting_month, rxnorm_code)
            DO UPDATE SET
                in_stock = EXCLUDED.in_stock,
                submitted_at = EXCLUDED.submitted_at,
                pulled_at = EXCLUDED.pulled_at,
                country_code = EXCLUDED.country_code,
                programme_code = EXCLUDED.programme_code;
            v_accepted := v_accepted + 1;
        END IF;
    END LOOP;

    RETURN QUERY SELECT v_accepted, v_rejected;
END;
$$;

REVOKE ALL ON TABLE drug_stock_submission FROM PUBLIC;
REVOKE ALL ON TABLE drug_stock_submission_reject FROM PUBLIC;
REVOKE ALL ON TABLE drug_stock_submission FROM grafana;
REVOKE ALL ON TABLE drug_stock_submission_reject FROM grafana;
REVOKE ALL ON FUNCTION drug_stock_pull_apply(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION drug_stock_pull_apply(jsonb) FROM grafana;
GRANT EXECUTE ON FUNCTION drug_stock_pull_apply(jsonb) TO heart360tk;

COMMIT;
