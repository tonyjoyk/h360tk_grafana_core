BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_reporting, heart360tk_schema;

-- StockOnHandMatrix. One JSON object per display row, read from
-- drug_stock_patient_days. Facility patient-days cells copy
-- category_patient_days. They do not recompute it.
-- The All row exists only when p_org_unit_id is null. Its patient-days
-- value is sum(normalized_stock) / (sum(patients_n) * load_factor * category_coeff)
-- on the sums already stored on the view, with the view's null guards.
-- A JSON null patient-days cell is a missing submission.
-- -1 is not a patient-days value. It marks a submitted null so a numeric
-- Grafana column can show an em dash and still threshold real numbers.
CREATE OR REPLACE FUNCTION drug_stock_on_hand_matrix(
    p_reporting_month date,
    p_org_unit_id integer
)
RETURNS TABLE (matrix json)
LANGUAGE sql
STABLE
SET search_path = heart360tk_reporting, heart360tk_schema
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
                        substring(d.dosage FROM '^[0-9]+([.][0-9]+)?')::numeric,
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
    per_facility_category AS (
        SELECT
            org_unit_id,
            drug_category,
            SUM(normalized_stock) AS normalized_stock,
            MAX(patients_n) AS patients_n,
            MAX(load_factor) AS load_factor,
            MAX(category_coeff) AS category_coeff
        FROM scoped
        GROUP BY org_unit_id, drug_category
    ),
    all_days AS (
        SELECT
            drug_category,
            CASE
                WHEN SUM(patients_n) IS NULL OR SUM(patients_n) = 0 THEN NULL
                WHEN MAX(load_factor) IS NULL OR MAX(category_coeff) IS NULL THEN NULL
                WHEN MAX(load_factor) = 0 OR MAX(category_coeff) = 0 THEN NULL
                WHEN SUM(normalized_stock) IS NULL THEN NULL
                ELSE SUM(normalized_stock)
                    / (SUM(patients_n) * MAX(load_factor) * MAX(category_coeff))
            END AS category_patient_days
        FROM per_facility_category
        GROUP BY drug_category
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
        WHERE p_org_unit_id IS NULL
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
        WHERE p_org_unit_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM scoped)
    )
    SELECT o.matrix
    FROM ordered o
    ORDER BY o.sort_name, o.org_key;
$$;

COMMENT ON FUNCTION drug_stock_on_hand_matrix(date, integer) IS
    'StockOnHandMatrix. Reads drug_stock_patient_days. Copies category_patient_days. All uses sum(normalized_stock) / (sum(patients_n) * load_factor * category_coeff). JSON null patient days is a missing submission. -1 marks a submitted null for the em dash.';

REVOKE ALL ON FUNCTION drug_stock_on_hand_matrix(date, integer) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'heart360tk_cached') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION heart360tk_reporting.drug_stock_on_hand_matrix(date, integer) TO heart360tk_cached';
    END IF;
END $$;

COMMIT;
