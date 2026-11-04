BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

CREATE TABLE IF NOT EXISTS drug_stock_form_cohort (
    org_unit_id INTEGER PRIMARY KEY REFERENCES org_units (id) ON DELETE CASCADE
);

CREATE OR REPLACE VIEW drug_stock_form_facility_export AS
SELECT ou.id, ou.name
FROM drug_stock_form_cohort c
JOIN org_units ou ON ou.id = c.org_unit_id
ORDER BY ou.name, ou.id;

-- A month choice records YYYY-MM. A date records YYYY-MM-DD. Both become the first of that month.
CREATE OR REPLACE FUNCTION drug_stock_form_long_rows(wide jsonb)
RETURNS TABLE (
    org_unit_id    INTEGER,
    reporting_month DATE,
    drug_code      VARCHAR,
    in_stock       NUMERIC,
    submitted_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SET search_path = heart360tk_schema
AS $$
DECLARE
    v_org_unit_id     INTEGER;
    v_reporting_month DATE;
    v_submitted_at    TIMESTAMPTZ;
    v_month_text      TEXT;
BEGIN
    IF wide IS NULL OR jsonb_typeof(wide) <> 'object' THEN
        RAISE EXCEPTION 'wide form response must be a JSON object';
    END IF;

    IF wide->>'facility' IS NULL OR btrim(wide->>'facility') !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'facility value must be org_units.id';
    END IF;
    v_org_unit_id := (wide->>'facility')::integer;

    v_month_text := btrim(wide->>'reporting_month');
    IF v_month_text IS NULL OR v_month_text = '' THEN
        RAISE EXCEPTION 'reporting_month is required';
    ELSIF v_month_text ~ '^[0-9]{4}-[0-9]{2}$' THEN
        v_reporting_month := to_date(v_month_text, 'YYYY-MM');
    ELSE
        v_reporting_month := date_trunc('month', v_month_text::date)::date;
    END IF;

    IF wide->>'submitted_at' IS NULL OR btrim(wide->>'submitted_at') = '' THEN
        v_submitted_at := NULL;
    ELSE
        v_submitted_at := (wide->>'submitted_at')::timestamptz;
    END IF;

    RETURN QUERY
    SELECT
        v_org_unit_id,
        v_reporting_month,
        d.rxnorm_code,
        CASE
            WHEN wide -> d.rxnorm_code::text IS NULL
              OR jsonb_typeof(wide -> d.rxnorm_code::text) = 'null' THEN NULL::numeric
            WHEN jsonb_typeof(wide -> d.rxnorm_code::text) = 'string'
              AND btrim(wide ->> d.rxnorm_code::text) = '' THEN NULL::numeric
            ELSE btrim(wide ->> d.rxnorm_code::text)::numeric
        END,
        v_submitted_at
    FROM active_stock_tracked_drugs d
    ORDER BY d.rxnorm_code;
END;
$$;

COMMIT;
