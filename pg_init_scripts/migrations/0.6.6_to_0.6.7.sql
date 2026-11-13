-- 0.6.6_to_0.6.7: drug stock fixes: latest wins by submitted_at, history, patient-days (AD-19, AD-22)
--
-- Ingest contract (unchanged signature, extended row keys):
--   heart360tk_schema.drug_stock_pull_apply(rows jsonb) RETURNS TABLE (accepted integer, rejected integer)
--   rows is a JSON array of objects. Keys, all text or JSON numbers:
--     org_unit_id      org_units.id (digits)
--     reporting_month  YYYY-MM or YYYY-MM-DD, stored as the first of the month
--     drug_code        protocol_drugs.rxnorm_code of an active stock-tracked drug
--     in_stock         number; blank, '?' or missing = NULL (AD-12)
--     submitted_at     ISO 8601 timestamp, with an offset; blank = NULL
--     submitted_by     Form "Email address"; trimmed and lower-cased; blank = NULL.
--                      submitter_email is accepted as an alias.
--     sheet_row        1-based sheet row; blank = NULL
--   Only heart360tk may call it. Every accepted row is appended to
--   drug_stock_submission_history; drug_stock_submission keeps the latest.
--
-- Latest wins (AD-19). Rows are applied in (submitted_at NULLS FIRST, sheet_row
-- NULLS FIRST, array position) order. A row replaces the stored row when the
-- stored submitted_at is NULL, or when the row has a submitted_at and
-- (submitted_at, sheet_row) >= the stored pair, with a NULL sheet_row lowest.
-- A row with the same submitted_at and sheet_row as the stored row (a re-pull)
-- replaces it, so the later-ingested row wins a full tie.
BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_schema;

ALTER TABLE drug_stock_submission
    ADD COLUMN IF NOT EXISTS submitted_by TEXT,
    ADD COLUMN IF NOT EXISTS sheet_row    INTEGER;

ALTER TABLE drug_stock_submission_reject
    ADD COLUMN IF NOT EXISTS submitted_by TEXT,
    ADD COLUMN IF NOT EXISTS sheet_row    TEXT;

-- in_stock is part of the key so a long-layout row without submitted_at or
-- sheet_row still records a changed value; NULLS NOT DISTINCT stops re-pulls
-- of such rows from duplicating.
CREATE TABLE IF NOT EXISTS drug_stock_submission_history (
    history_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    org_unit_id     INTEGER NOT NULL REFERENCES org_units (id),
    reporting_month DATE NOT NULL,
    rxnorm_code     VARCHAR(64) NOT NULL,
    country_code    VARCHAR(64) NOT NULL,
    programme_code  VARCHAR(64) NOT NULL,
    in_stock        NUMERIC,
    submitted_at    TIMESTAMPTZ,
    submitted_by    TEXT,
    sheet_row       INTEGER,
    pulled_at       TIMESTAMPTZ NOT NULL,
    CONSTRAINT drug_stock_submission_history_protocol_drug_fkey
        FOREIGN KEY (country_code, programme_code, rxnorm_code)
        REFERENCES protocol_drugs (country_code, programme_code, rxnorm_code),
    CONSTRAINT drug_stock_submission_history_reporting_month_first
        CHECK (reporting_month = date_trunc('month', reporting_month)::date),
    CONSTRAINT drug_stock_submission_history_once
        UNIQUE NULLS NOT DISTINCT
        (org_unit_id, reporting_month, rxnorm_code, submitted_at, sheet_row, in_stock)
);

COMMENT ON TABLE drug_stock_submission_history IS
    'Append-only. Every row accepted by drug_stock_pull_apply, once per (org_unit_id, reporting_month, rxnorm_code, submitted_at, sheet_row, in_stock). drug_stock_submission holds the latest per key (AD-19).';
COMMENT ON COLUMN drug_stock_submission.submitted_by IS
    'Google Form collected email of the submitter (A33), lower-cased. NULL when the source has none.';
COMMENT ON COLUMN drug_stock_submission.sheet_row IS
    '1-based sheet row of the winning row. Breaks submitted_at ties; NULL sorts lowest.';

-- Rows already stored before this migration become the first history rows.
INSERT INTO drug_stock_submission_history (
    org_unit_id, reporting_month, rxnorm_code, country_code, programme_code,
    in_stock, submitted_at, submitted_by, sheet_row, pulled_at
)
SELECT
    org_unit_id, reporting_month, rxnorm_code, country_code, programme_code,
    in_stock, submitted_at, submitted_by, sheet_row, pulled_at
FROM drug_stock_submission
ORDER BY submitted_at NULLS FIRST, sheet_row NULLS FIRST, pulled_at
ON CONFLICT ON CONSTRAINT drug_stock_submission_history_once DO NOTHING;

CREATE OR REPLACE FUNCTION drug_stock_pull_parse(p_row jsonb)
RETURNS TABLE (
    raw_org_unit_id     text,
    raw_reporting_month text,
    raw_drug_code       text,
    raw_in_stock        text,
    raw_submitted_at    text,
    raw_submitted_by    text,
    raw_sheet_row       text,
    org_unit_id         integer,
    reporting_month     date,
    rxnorm_code         varchar(64),
    in_stock            numeric,
    submitted_at        timestamptz,
    submitted_by        text,
    sheet_row           integer,
    reason              text
)
LANGUAGE plpgsql
STABLE
SET search_path = heart360tk_schema, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_org_text       text;
    v_month_text     text;
    v_drug_text      text;
    v_stock_text     text;
    v_submitted_text text;
    v_by_text        text;
    v_row_text       text;
    v_month_trim     text;
    v_mon            integer;
    v_org_id         integer;
    v_month          date;
    v_stock          numeric;
    v_submitted      timestamptz;
    v_by             text;
    v_sheet_row      integer;
    v_reason         text;
BEGIN
    IF jsonb_typeof(p_row) IS DISTINCT FROM 'object' THEN
        RETURN QUERY SELECT
            NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
            NULL::integer, NULL::date, NULL::varchar(64), NULL::numeric,
            NULL::timestamptz, NULL::text, NULL::integer, 'invalid_row'::text;
        RETURN;
    END IF;

    v_org_text := p_row->>'org_unit_id';
    v_month_text := p_row->>'reporting_month';
    v_drug_text := p_row->>'drug_code';
    v_stock_text := p_row->>'in_stock';
    v_submitted_text := p_row->>'submitted_at';
    v_by_text := COALESCE(
        NULLIF(btrim(p_row->>'submitted_by'), ''),
        NULLIF(btrim(p_row->>'submitter_email'), ''),
        p_row->>'submitted_by',
        p_row->>'submitter_email'
    );
    v_row_text := p_row->>'sheet_row';

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
                SELECT 1 FROM org_units ou WHERE ou.id = v_org_id
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

    IF v_reason IS NULL THEN
        IF v_row_text IS NULL OR btrim(v_row_text) = '' THEN
            v_sheet_row := NULL;
        ELSIF btrim(v_row_text) !~ '^[0-9]{1,9}$' OR btrim(v_row_text)::integer < 1 THEN
            v_reason := 'invalid_sheet_row';
        ELSE
            v_sheet_row := btrim(v_row_text)::integer;
        END IF;
    END IF;

    v_by := NULLIF(lower(btrim(COALESCE(v_by_text, ''))), '');

    RETURN QUERY SELECT
        v_org_text, v_month_text, v_drug_text, v_stock_text,
        v_submitted_text, v_by_text, v_row_text,
        CASE WHEN v_reason IS NULL THEN v_org_id END,
        CASE WHEN v_reason IS NULL THEN v_month END,
        CASE WHEN v_reason IS NULL THEN btrim(v_drug_text)::varchar(64) END,
        CASE WHEN v_reason IS NULL THEN v_stock END,
        CASE WHEN v_reason IS NULL THEN v_submitted END,
        v_by,
        CASE WHEN v_reason IS NULL THEN v_sheet_row END,
        v_reason;
END;
$$;

COMMENT ON FUNCTION drug_stock_pull_parse(jsonb) IS
    'Parses one drug_stock_pull_apply row. reason is NULL for an accepted row, else the reject reason.';

CREATE OR REPLACE FUNCTION drug_stock_pull_apply(rows jsonb)
RETURNS TABLE (accepted integer, rejected integer)
LANGUAGE plpgsql
SET search_path = heart360tk_schema, pg_temp
AS $$
DECLARE
    r                 record;
    v_country         varchar(64);
    v_programme       varchar(64);
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

    FOR r IN
        SELECT p.*, e.ord
        FROM jsonb_array_elements(rows) WITH ORDINALITY AS e(elem, ord)
        CROSS JOIN LATERAL drug_stock_pull_parse(e.elem) AS p
        ORDER BY p.submitted_at ASC NULLS FIRST, p.sheet_row ASC NULLS FIRST, e.ord
    LOOP
        IF r.reason IS NOT NULL THEN
            DELETE FROM drug_stock_submission_reject j
            WHERE j.org_unit_id IS NOT DISTINCT FROM r.raw_org_unit_id
              AND j.reporting_month IS NOT DISTINCT FROM r.raw_reporting_month
              AND j.drug_code IS NOT DISTINCT FROM r.raw_drug_code
              AND j.sheet_row IS NOT DISTINCT FROM r.raw_sheet_row
              AND j.reason = r.reason;

            INSERT INTO drug_stock_submission_reject (
                org_unit_id, reporting_month, drug_code, in_stock, submitted_at,
                reason, pulled_at, submitted_by, sheet_row
            ) VALUES (
                r.raw_org_unit_id, r.raw_reporting_month, r.raw_drug_code, r.raw_in_stock,
                r.raw_submitted_at, r.reason, v_pulled_at, r.raw_submitted_by, r.raw_sheet_row
            );
            v_rejected := v_rejected + 1;
        ELSE
            INSERT INTO drug_stock_submission_history (
                org_unit_id, reporting_month, rxnorm_code, country_code, programme_code,
                in_stock, submitted_at, submitted_by, sheet_row, pulled_at
            ) VALUES (
                r.org_unit_id, r.reporting_month, r.rxnorm_code, v_country, v_programme,
                r.in_stock, r.submitted_at, r.submitted_by, r.sheet_row, v_pulled_at
            )
            ON CONFLICT ON CONSTRAINT drug_stock_submission_history_once DO NOTHING;

            INSERT INTO drug_stock_submission AS cur (
                org_unit_id, reporting_month, rxnorm_code,
                country_code, programme_code,
                in_stock, submitted_at, pulled_at, submitted_by, sheet_row
            ) VALUES (
                r.org_unit_id, r.reporting_month, r.rxnorm_code,
                v_country, v_programme,
                r.in_stock, r.submitted_at, v_pulled_at, r.submitted_by, r.sheet_row
            )
            ON CONFLICT (org_unit_id, reporting_month, rxnorm_code)
            DO UPDATE SET
                in_stock = EXCLUDED.in_stock,
                submitted_at = EXCLUDED.submitted_at,
                submitted_by = EXCLUDED.submitted_by,
                sheet_row = EXCLUDED.sheet_row,
                pulled_at = EXCLUDED.pulled_at,
                country_code = EXCLUDED.country_code,
                programme_code = EXCLUDED.programme_code
            WHERE cur.submitted_at IS NULL
               OR (
                   EXCLUDED.submitted_at IS NOT NULL
                   AND (EXCLUDED.submitted_at, COALESCE(EXCLUDED.sheet_row, 0))
                       >= (cur.submitted_at, COALESCE(cur.sheet_row, 0))
               );
            v_accepted := v_accepted + 1;
        END IF;
    END LOOP;

    RETURN QUERY SELECT v_accepted, v_rejected;
END;
$$;

COMMENT ON FUNCTION drug_stock_pull_apply(jsonb) IS
    'Only writer of drug stock rows. Appends every accepted row to drug_stock_submission_history; keeps the latest by (submitted_at, sheet_row) on drug_stock_submission (AD-19). accepted counts valid rows, including older rows that did not replace the stored one.';

-- A cohort must not hold a node and its descendant, or subtree N counts the
-- same patients twice. This view lists such pairs; it must stay empty.
CREATE OR REPLACE VIEW drug_stock_form_cohort_overlap AS
WITH RECURSIVE below AS (
    SELECT c.org_unit_id AS ancestor_id, o.id AS descendant_id
    FROM drug_stock_form_cohort c
    JOIN org_units o ON o.parent_id = c.org_unit_id
    UNION ALL
    SELECT b.ancestor_id, o.id
    FROM below b
    JOIN org_units o ON o.parent_id = b.descendant_id
)
SELECT b.ancestor_id, b.descendant_id
FROM below b
JOIN drug_stock_form_cohort c ON c.org_unit_id = b.descendant_id;

-- Patient-Days (AD-9 as amended by AD-22).
-- A category is known for a facility-month only when every active
-- stock-tracked drug of the category has a stored non-NULL in_stock. Otherwise
-- category_patient_days is NULL (A50). patients_n is the sum of
-- cumulative_number_of_patients over the facility and all its descendants at
-- ref_month = reporting_month (A51); NULL when the subtree has no row.
CREATE OR REPLACE VIEW heart360tk_reporting.drug_stock_patient_days AS
WITH RECURSIVE subtree AS (
    SELECT c.org_unit_id AS facility_id, c.org_unit_id AS org_unit_id
    FROM heart360tk_schema.drug_stock_form_cohort c
    UNION ALL
    SELECT t.facility_id, o.id
    FROM subtree t
    JOIN heart360tk_schema.org_units o ON o.parent_id = t.org_unit_id
),
active AS (
    SELECT
        s.country_code,
        s.programme_code,
        d.drug_category,
        d.rxnorm_code,
        d.drug_name,
        d.dosage,
        p.dose_factor,
        c.load_factor,
        c.category_coeff
    FROM heart360tk_schema.deploy_setting s
    JOIN heart360tk_schema.active_stock_tracked_drugs d
      ON d.country_code = s.country_code
     AND d.programme_code = s.programme_code
    JOIN heart360tk_schema.protocol_drugs p
      ON p.country_code = d.country_code
     AND p.programme_code = d.programme_code
     AND p.rxnorm_code = d.rxnorm_code
    LEFT JOIN heart360tk_schema.coeff_config c
      ON c.country_code = s.country_code
     AND c.programme_code = s.programme_code
     AND c.drug_category = d.drug_category
    WHERE s.setting_name = 'active_programme'
),
months AS (
    SELECT DISTINCT sub.reporting_month
    FROM heart360tk_schema.drug_stock_submission sub
    JOIN heart360tk_schema.deploy_setting s
      ON s.setting_name = 'active_programme'
     AND s.country_code = sub.country_code
     AND s.programme_code = sub.programme_code
),
reported AS (
    SELECT sub.org_unit_id, sub.reporting_month
    FROM heart360tk_schema.drug_stock_submission sub
    GROUP BY sub.org_unit_id, sub.reporting_month
),
subtree_n AS (
    SELECT
        t.facility_id,
        reg.ref_month,
        SUM(reg.cumulative_number_of_patients)::numeric AS patients_n
    FROM subtree t
    JOIN heart360tk_reporting.heart360_patients_registered reg
      ON reg.org_unit_id = t.org_unit_id
    JOIN months
      ON months.reporting_month = reg.ref_month
    GROUP BY t.facility_id, reg.ref_month
),
base AS (
    SELECT
        cohort.org_unit_id,
        ou.name AS facility_name,
        months.reporting_month,
        active.drug_category,
        active.rxnorm_code,
        active.drug_name,
        active.dosage,
        (reported.org_unit_id IS NOT NULL) AS submission_present,
        sub.in_stock,
        active.dose_factor,
        n.patients_n,
        active.load_factor,
        active.category_coeff,
        CASE
            WHEN sub.in_stock IS NULL THEN NULL
            ELSE sub.in_stock * active.dose_factor
        END AS normalized_stock
    FROM heart360tk_schema.drug_stock_form_cohort cohort
    JOIN heart360tk_schema.org_units ou
      ON ou.id = cohort.org_unit_id
    CROSS JOIN months
    CROSS JOIN active
    LEFT JOIN reported
      ON reported.org_unit_id = cohort.org_unit_id
     AND reported.reporting_month = months.reporting_month
    LEFT JOIN heart360tk_schema.drug_stock_submission sub
      ON sub.org_unit_id = cohort.org_unit_id
     AND sub.reporting_month = months.reporting_month
     AND sub.rxnorm_code = active.rxnorm_code
     AND sub.country_code = active.country_code
     AND sub.programme_code = active.programme_code
    LEFT JOIN subtree_n n
      ON n.facility_id = cohort.org_unit_id
     AND n.ref_month = months.reporting_month
),
scored AS (
    SELECT
        base.*,
        bool_and(in_stock IS NOT NULL) OVER w AS category_known,
        SUM(normalized_stock) OVER w AS category_sum
    FROM base
    WINDOW w AS (PARTITION BY org_unit_id, reporting_month, drug_category)
)
SELECT
    org_unit_id,
    facility_name,
    reporting_month,
    drug_category,
    rxnorm_code,
    drug_name,
    dosage,
    submission_present,
    in_stock,
    dose_factor,
    patients_n,
    load_factor,
    category_coeff,
    normalized_stock,
    CASE
        WHEN NOT category_known THEN NULL
        WHEN patients_n IS NULL OR patients_n = 0 THEN NULL
        WHEN load_factor IS NULL OR category_coeff IS NULL THEN NULL
        WHEN load_factor = 0 OR category_coeff = 0 THEN NULL
        ELSE category_sum / (patients_n * load_factor * category_coeff)
    END AS category_patient_days,
    category_known,
    CASE WHEN category_known THEN category_sum END AS category_normalized_stock
FROM scored;

COMMENT ON VIEW heart360tk_reporting.drug_stock_patient_days IS
    'Patient-Days = sum(in_stock * dose_factor) / (patients_n * load_factor * category_coeff). patients_n sums registered cumulative_number_of_patients over the facility subtree (A51). A category with any NULL or missing in_stock is unknown: category_known false, category_patient_days NULL (A50). patients_n NULL or 0 yields NULL.';

-- The All row (AD-22). Sums only facilities whose category_patient_days is a
-- number, so unknown categories and facilities without N never dilute it.
-- reporting_n = facilities counted; cohort_n = cohort facilities in scope.
CREATE OR REPLACE FUNCTION heart360tk_reporting.drug_stock_patient_days_all(
    p_reporting_month date,
    p_org_unit_id integer
)
RETURNS TABLE (
    drug_category         varchar(64),
    category_patient_days numeric,
    reporting_n           integer,
    cohort_n              integer,
    normalized_stock      numeric,
    patients_n            numeric
)
LANGUAGE sql
STABLE
SET search_path = heart360tk_reporting, heart360tk_schema, pg_temp
AS $$
    WITH scoped AS (
        SELECT v.*
        FROM heart360tk_reporting.drug_stock_patient_days v
        WHERE v.reporting_month = p_reporting_month
          AND (
              COALESCE(p_org_unit_id, 0) = 0
              OR v.org_unit_id IN (
                  SELECT d.id
                  FROM heart360tk_schema.get_descendant_ids(p_org_unit_id) AS d
              )
          )
    ),
    per_facility AS (
        SELECT
            s.org_unit_id,
            s.drug_category,
            MAX(s.category_patient_days) AS category_patient_days,
            MAX(s.category_normalized_stock) AS normalized_stock,
            MAX(s.patients_n) AS patients_n,
            MAX(s.load_factor) AS load_factor,
            MAX(s.category_coeff) AS category_coeff
        FROM scoped s
        GROUP BY s.org_unit_id, s.drug_category
    ),
    cohort AS (
        SELECT COUNT(DISTINCT s.org_unit_id)::integer AS n
        FROM scoped s
    ),
    counted AS (
        SELECT
            f.drug_category,
            COUNT(f.category_patient_days)::integer AS reporting_n,
            SUM(f.normalized_stock) FILTER (WHERE f.category_patient_days IS NOT NULL) AS normalized_stock,
            SUM(f.patients_n) FILTER (WHERE f.category_patient_days IS NOT NULL) AS patients_n,
            MAX(f.load_factor) AS load_factor,
            MAX(f.category_coeff) AS category_coeff
        FROM per_facility f
        GROUP BY f.drug_category
    )
    SELECT
        c.drug_category,
        CASE
            WHEN c.reporting_n = 0 THEN NULL
            ELSE c.normalized_stock / (c.patients_n * c.load_factor * c.category_coeff)
        END,
        c.reporting_n,
        (SELECT n FROM cohort),
        c.normalized_stock,
        c.patients_n
    FROM counted c
    ORDER BY CASE c.drug_category
        WHEN 'CCB' THEN 1 WHEN 'ARB' THEN 2 WHEN 'Diuretic' THEN 3 ELSE 4
    END, c.drug_category;
$$;

COMMENT ON FUNCTION heart360tk_reporting.drug_stock_patient_days_all(date, integer) IS
    'All row per category: sum(category_normalized_stock) / (sum(patients_n) * load_factor * category_coeff) over the facilities in scope whose category_patient_days is not NULL. reporting_n counts them; cohort_n counts cohort facilities in scope. 0 or NULL scope = all.';

-- StockOnHandMatrix, unchanged columns. The All row now reads
-- drug_stock_patient_days_all and also appears for p_org_unit_id = 0.
CREATE OR REPLACE FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(
    p_reporting_month date,
    p_org_unit_id integer
)
RETURNS TABLE (matrix json)
LANGUAGE sql
STABLE
SET search_path = heart360tk_reporting, heart360tk_schema, pg_temp
AS $$
    WITH scoped AS (
        SELECT v.*
        FROM heart360tk_reporting.drug_stock_patient_days v
        WHERE v.reporting_month = p_reporting_month
          AND (
              p_org_unit_id IS NULL
              OR v.org_unit_id IN (
                  SELECT d.id
                  FROM heart360tk_schema.get_descendant_ids(p_org_unit_id) AS d
              )
          )
    ),
    category_order(drug_category, cat_ord) AS (
        VALUES
            ('CCB'::varchar, 1),
            ('ARB'::varchar, 2),
            ('Diuretic'::varchar, 3),
            ('Other'::varchar, 4)
    ),
    drugs AS (
        SELECT DISTINCT
            s.drug_category,
            s.rxnorm_code,
            s.drug_name,
            s.dosage,
            c.cat_ord,
            (s.drug_name || ' ' || s.dosage) AS header
        FROM scoped s
        JOIN category_order c ON c.drug_category = s.drug_category
    ),
    drug_ranked AS (
        SELECT
            d.*,
            row_number() OVER (
                PARTITION BY d.drug_category
                ORDER BY
                    d.drug_name,
                    COALESCE(
                        substring(d.dosage FROM '^[0-9]+[.]?[0-9]*')::numeric,
                        0
                    ),
                    d.rxnorm_code
            ) AS drug_ord
        FROM drugs d
    ),
    columns AS (
        SELECT
            drug_category,
            header,
            rxnorm_code,
            NULL::varchar AS patient_days_category,
            cat_ord,
            drug_ord,
            0 AS kind_ord
        FROM drug_ranked
        UNION ALL
        SELECT
            drug_category,
            drug_category || ' Patient days',
            NULL::varchar,
            drug_category,
            cat_ord,
            0,
            1
        FROM drug_ranked
        GROUP BY drug_category, cat_ord
    ),
    facilities AS (
        SELECT
            org_unit_id,
            facility_name,
            bool_or(submission_present) AS submission_present
        FROM scoped
        GROUP BY org_unit_id, facility_name
    ),
    facility_days AS (
        SELECT
            org_unit_id,
            drug_category,
            MAX(category_patient_days) AS category_patient_days
        FROM scoped
        GROUP BY org_unit_id, drug_category
    ),
    all_days AS (
        SELECT a.drug_category, a.category_patient_days
        FROM heart360tk_reporting.drug_stock_patient_days_all(p_reporting_month, p_org_unit_id) a
    ),
    all_stock AS (
        SELECT rxnorm_code, SUM(in_stock) AS in_stock
        FROM scoped
        GROUP BY rxnorm_code
    ),
    facility_cells AS (
        SELECT
            f.org_unit_id::text AS org_key,
            f.facility_name,
            c.header,
            c.cat_ord,
            c.drug_ord,
            c.kind_ord,
            CASE
                WHEN c.patient_days_category IS NULL THEN to_json(
                    CASE
                        WHEN NOT f.submission_present THEN '?'
                        WHEN fs.in_stock IS NULL THEN chr(8212)
                        WHEN fs.in_stock = 0 THEN '0'
                        ELSE to_char(fs.in_stock, 'FM999999990.########')
                    END
                )
                WHEN NOT f.submission_present THEN 'null'::json
                WHEN fd.category_patient_days IS NULL THEN to_json(-1)
                ELSE to_json(fd.category_patient_days)
            END AS cell
        FROM facilities f
        CROSS JOIN columns c
        LEFT JOIN scoped fs
          ON fs.org_unit_id = f.org_unit_id
         AND fs.rxnorm_code = c.rxnorm_code
        LEFT JOIN facility_days fd
          ON fd.org_unit_id = f.org_unit_id
         AND fd.drug_category = c.patient_days_category
    ),
    all_cells AS (
        SELECT
            'all'::text AS org_key,
            'All'::text AS facility_name,
            c.header,
            c.cat_ord,
            c.drug_ord,
            c.kind_ord,
            CASE
                WHEN c.patient_days_category IS NULL THEN to_json(
                    CASE
                        WHEN a_s.in_stock IS NULL THEN chr(8212)
                        WHEN a_s.in_stock = 0 THEN '0'
                        ELSE to_char(a_s.in_stock, 'FM999999990.########')
                    END
                )
                WHEN a_d.category_patient_days IS NULL THEN to_json(-1)
                ELSE to_json(a_d.category_patient_days)
            END AS cell
        FROM columns c
        LEFT JOIN all_stock a_s ON a_s.rxnorm_code = c.rxnorm_code
        LEFT JOIN all_days a_d ON a_d.drug_category = c.patient_days_category
        WHERE COALESCE(p_org_unit_id, 0) = 0
          AND EXISTS (SELECT 1 FROM scoped)
    ),
    body AS (
        SELECT * FROM facility_cells
        UNION ALL
        SELECT * FROM all_cells
    ),
    rows AS (
        SELECT
            org_key,
            facility_name,
            (
                '{"Facility":' || to_json(facility_name)::text ||
                COALESCE(
                    ',' || string_agg(
                        to_json(header)::text || ':' || COALESCE(cell, 'null'::json)::text,
                        ',' ORDER BY cat_ord, kind_ord, drug_ord, header
                    ),
                    ''
                ) ||
                '}'
            )::json AS matrix
        FROM body
        GROUP BY org_key, facility_name
    ),
    ordered AS (
        SELECT matrix, facility_name AS sort_name, org_key
        FROM rows
        UNION ALL
        SELECT
            json_build_object('Facility', 'No facilities for this location.'),
            'No facilities for this location.',
            'empty'
        WHERE COALESCE(p_org_unit_id, 0) <> 0
          AND NOT EXISTS (SELECT 1 FROM scoped)
    )
    SELECT o.matrix
    FROM ordered o
    ORDER BY o.sort_name, o.org_key;
$$;

COMMENT ON FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(date, integer) IS
    'StockOnHandMatrix. Reads drug_stock_patient_days. Copies category_patient_days. The All row (scope NULL or 0) reads drug_stock_patient_days_all, which sums only facilities whose category is known. JSON null patient days is a missing submission. -1 marks a submitted but unknown category for the em dash.';

REVOKE ALL ON TABLE drug_stock_submission_history FROM PUBLIC;
REVOKE ALL ON FUNCTION drug_stock_pull_parse(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION drug_stock_pull_apply(jsonb) FROM PUBLIC;
REVOKE ALL ON heart360tk_schema.drug_stock_form_cohort_overlap FROM PUBLIC;
REVOKE ALL ON FUNCTION heart360tk_reporting.drug_stock_patient_days_all(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(date, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION drug_stock_pull_parse(jsonb) TO heart360tk;
GRANT EXECUTE ON FUNCTION drug_stock_pull_apply(jsonb) TO heart360tk;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana') THEN
        EXECUTE 'REVOKE ALL ON TABLE heart360tk_schema.drug_stock_submission_history FROM grafana';
        EXECUTE 'REVOKE ALL ON FUNCTION heart360tk_schema.drug_stock_pull_apply(jsonb) FROM grafana';
        EXECUTE 'REVOKE ALL ON FUNCTION heart360tk_schema.drug_stock_pull_parse(jsonb) FROM grafana';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_cached') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_reporting.drug_stock_patient_days_all(date, integer) TO heart360tk_cached';
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(date, integer) TO heart360tk_cached';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_reader') THEN
        EXECUTE 'GRANT SELECT ON TABLE heart360tk_schema.drug_stock_submission_history TO heart360tk_reader';
        EXECUTE 'GRANT SELECT ON heart360tk_schema.drug_stock_form_cohort_overlap TO heart360tk_reader';
        EXECUTE 'GRANT SELECT ON heart360tk_reporting.drug_stock_patient_days TO heart360tk_reader';
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_reporting.drug_stock_patient_days_all(date, integer) TO heart360tk_reader';
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(date, integer) TO heart360tk_reader';
        EXECUTE 'REVOKE ALL ON FUNCTION heart360tk_schema.drug_stock_pull_apply(jsonb) FROM heart360tk_reader';
        EXECUTE 'REVOKE ALL ON FUNCTION heart360tk_schema.drug_stock_pull_parse(jsonb) FROM heart360tk_reader';
    END IF;
END $$;

COMMIT;
