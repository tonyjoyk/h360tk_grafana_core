SET ROLE heart360tk;
SET search_path TO heart360tk_schema;
-- ============================================================================
-- ORG_UNITS: Dynamic hierarchy table (replaces fixed facilities table)
-- Level 0 = root/country, 1 = region, 2 = district, etc.
-- Hierarchy depth is determined purely by ingestion data, not schema.
-- ============================================================================
CREATE TABLE IF NOT EXISTS org_units (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    level       INTEGER NOT NULL,
    parent_id   INTEGER REFERENCES org_units(id)
);

-- Unique constraints: handle NULL parent_id (root nodes) separately
CREATE UNIQUE INDEX IF NOT EXISTS org_units_unique_root
    ON org_units(name, level) WHERE parent_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS org_units_unique_child
    ON org_units(name, level, parent_id) WHERE parent_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_org_units_parent_id ON org_units(parent_id);
CREATE INDEX IF NOT EXISTS idx_org_units_level ON org_units(level);
CREATE INDEX IF NOT EXISTS idx_org_units_name ON org_units(name);

-- ============================================================================
-- CORE DATA TABLES
-- ============================================================================

-- 1. Patients Table
CREATE TABLE IF NOT EXISTS patients (
    patient_id          bigint PRIMARY KEY,
    patient_name        VARCHAR(255),
    gender              VARCHAR(255),
    phone_number        VARCHAR(255),
    patient_status      VARCHAR(10) NOT NULL CHECK (patient_status IN ('DEAD', 'ALIVE')),
    registration_date   TIMESTAMP NOT NULL,
    birth_date          Date,
    death_date          DATE,
    org_unit_id         INTEGER REFERENCES org_units(id)
);

CREATE INDEX IF NOT EXISTS idx_patients_org_unit_id ON patients(org_unit_id);

CREATE TABLE IF NOT EXISTS patient_diagnoses (
    id BIGSERIAL PRIMARY KEY,
    patient_id BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    diagnosis_code VARCHAR(10) NOT NULL,
    UNIQUE(patient_id, diagnosis_code),

    CHECK (diagnosis_code IN ('I10', 'E11'))
);

CREATE INDEX IF NOT EXISTS idx_patient_diagnoses_patient_id
ON patient_diagnoses(patient_id);

CREATE INDEX IF NOT EXISTS idx_patient_diagnoses_code
ON patient_diagnoses(diagnosis_code);

-- 2. Drop old BP Encounters Table (if exists)
DROP TABLE IF EXISTS bp_encounters CASCADE;

-- 3. Encounters Table
CREATE TABLE encounters (
    id              BIGSERIAL PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id),
    encounter_date  TIMESTAMP NOT NULL,
    org_unit_id     INTEGER REFERENCES org_units(id),
    UNIQUE(patient_id, encounter_date)
);

CREATE INDEX IF NOT EXISTS idx_encounters_patient_id ON encounters(patient_id);
CREATE INDEX IF NOT EXISTS idx_encounters_encounter_date ON encounters(encounter_date);
CREATE INDEX IF NOT EXISTS idx_encounters_org_unit_id ON encounters(org_unit_id);

-- 4. Blood Pressures Table
CREATE TABLE blood_pressures (
    id           BIGSERIAL PRIMARY KEY,
    encounter_id BIGINT NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
    systolic_bp  NUMERIC,
    diastolic_bp NUMERIC,
    UNIQUE (encounter_id)
);

CREATE INDEX IF NOT EXISTS idx_blood_pressures_encounter_id ON blood_pressures(encounter_id);

-- 5. Blood Sugars Table
CREATE TABLE blood_sugars (
    id                BIGSERIAL PRIMARY KEY,
    encounter_id      BIGINT NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
    blood_sugar_type  VARCHAR(50) DEFAULT 'RBS',
    blood_sugar_value NUMERIC,
    UNIQUE (encounter_id)
);

CREATE INDEX IF NOT EXISTS idx_blood_sugars_encounter_id ON blood_sugars(encounter_id);

-- 6. Scheduled Visits Table
CREATE TABLE IF NOT EXISTS scheduled_visits (
    scheduled_id   BIGSERIAL PRIMARY KEY,
    patient_id     BIGINT NOT NULL REFERENCES patients(patient_id),
    scheduled_date DATE NOT NULL,
    org_unit_id    INTEGER REFERENCES org_units(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_scheduled_visits_unique ON scheduled_visits(patient_id, scheduled_date);
CREATE INDEX IF NOT EXISTS idx_scheduled_visits_patient_id ON scheduled_visits(patient_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_visits_scheduled_date ON scheduled_visits(scheduled_date);
CREATE INDEX IF NOT EXISTS idx_scheduled_visits_org_unit_id ON scheduled_visits(org_unit_id);

-- 7. Call Results Table
CREATE TABLE IF NOT EXISTS call_results (
    call_id        BIGSERIAL PRIMARY KEY,
    patient_id     BIGINT NOT NULL REFERENCES patients(patient_id),
    call_date      DATE NOT NULL,
    result_type    VARCHAR(255),
    removed_reason VARCHAR(255),
    org_unit_id    INTEGER REFERENCES org_units(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_call_results_unique ON call_results(patient_id, call_date);
CREATE INDEX IF NOT EXISTS idx_call_results_patient_id ON call_results(patient_id);
CREATE INDEX IF NOT EXISTS idx_call_results_call_date ON call_results(call_date);
CREATE INDEX IF NOT EXISTS idx_call_results_org_unit_id ON call_results(org_unit_id);


-- ============================================================================
-- HELPER FUNCTIONS FOR DYNAMIC HIERARCHY
-- ============================================================================

-- Returns all descendant org_unit IDs (including the given ID itself).
-- NULL or 0 is the "All" sentinel used by the top-level dropdown and matches
-- every org unit, since no org unit is selected to scope the result to.
CREATE OR REPLACE FUNCTION get_descendant_ids(p_parent_id INTEGER)
RETURNS TABLE(id INTEGER)
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE descendants AS (
        SELECT ou.id FROM org_units ou
        WHERE COALESCE(p_parent_id, 0) <> 0 AND ou.id = p_parent_id
        UNION ALL
        SELECT o.id FROM org_units o JOIN descendants d ON o.parent_id = d.id
    )
    SELECT d.id FROM descendants d
    UNION ALL
    SELECT ou.id FROM org_units ou WHERE COALESCE(p_parent_id, 0) = 0;
$$;

-- Returns the ancestor name of a given org_unit at a specific level
CREATE OR REPLACE FUNCTION get_ancestor_name(p_org_unit_id INTEGER, p_target_level INTEGER)
RETURNS VARCHAR
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE ancestors AS (
        SELECT ou.id, ou.name, ou.level, ou.parent_id
        FROM org_units ou WHERE ou.id = p_org_unit_id
        UNION ALL
        SELECT o.id, o.name, o.level, o.parent_id
        FROM org_units o JOIN ancestors a ON a.parent_id = o.id
    )
    SELECT a.name FROM ancestors a WHERE a.level = p_target_level LIMIT 1;
$$;

-- Upsert a single org_unit and return its ID
CREATE OR REPLACE FUNCTION upsert_org_unit(p_name VARCHAR, p_level INTEGER, p_parent_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF p_parent_id IS NULL THEN
        INSERT INTO org_units (name, level, parent_id)
        VALUES (p_name, p_level, NULL)
        ON CONFLICT (name, level) WHERE parent_id IS NULL
        DO NOTHING;

        SELECT ou.id INTO v_id FROM org_units ou
        WHERE ou.name = p_name AND ou.level = p_level AND ou.parent_id IS NULL;
    ELSE
        INSERT INTO org_units (name, level, parent_id)
        VALUES (p_name, p_level, p_parent_id)
        ON CONFLICT (name, level, parent_id) WHERE parent_id IS NOT NULL
        DO NOTHING;

        SELECT ou.id INTO v_id FROM org_units ou
        WHERE ou.name = p_name AND ou.level = p_level AND ou.parent_id = p_parent_id;
    END IF;

    RETURN v_id;
END;
$$;

-- Upsert an entire hierarchy chain and return the leaf org_unit ID
-- p_names: array of org_unit names from top to bottom
-- p_levels: array of corresponding levels
CREATE OR REPLACE FUNCTION upsert_org_unit_chain(p_names VARCHAR[], p_levels INTEGER[])
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent_id INTEGER := NULL;
    v_id INTEGER;
    i INTEGER;
BEGIN
    FOR i IN 1..array_length(p_names, 1) LOOP
        v_id := upsert_org_unit(p_names[i], p_levels[i], v_parent_id);
        v_parent_id := v_id;
    END LOOP;
    RETURN v_id;
END;
$$;


-- Returns the breadcrumb path for a given org_unit as a string like "Region > District > Facility"
CREATE OR REPLACE FUNCTION get_breadcrumb_path(p_org_unit_id INTEGER)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE ancestors AS (
        SELECT ou.id, ou.name, ou.level, ou.parent_id
        FROM org_units ou WHERE ou.id = p_org_unit_id
        UNION ALL
        SELECT o.id, o.name, o.level, o.parent_id
        FROM org_units o JOIN ancestors a ON a.parent_id = o.id
    )
    SELECT string_agg(name, ' > ' ORDER BY level)
    FROM ancestors;
$$;

-- ============================================================================
-- ORG_UNIT_LINEAGE VIEW
-- For each org_unit, lists all its ancestors (including itself).
-- Used by Grafana queries to filter/group by any hierarchy level.
-- ============================================================================
CREATE OR REPLACE VIEW org_unit_lineage AS
WITH RECURSIVE lineage AS (
    SELECT ou.id AS org_unit_id, ou.id AS ancestor_id
    FROM org_units ou
    UNION ALL
    SELECT l.org_unit_id, o.parent_id
    FROM lineage l
    JOIN org_units o ON l.ancestor_id = o.id
    WHERE o.parent_id IS NOT NULL
)
SELECT
    l.org_unit_id,
    l.ancestor_id,
    o.level AS ancestor_level,
    o.name AS ancestor_name
FROM lineage l
JOIN org_units o ON l.ancestor_id = o.id;


-- ============================================================================
-- HIERARCHY_CONFIG: Maps each level to a display name and Grafana variable name.
-- Adding a row here + a matching Grafana variable makes the level appear
-- automatically in drill-down URLs, breadcrumbs, and level labels.
-- ============================================================================
CREATE TABLE IF NOT EXISTS hierarchy_config (
    level        INTEGER PRIMARY KEY,
    display_name VARCHAR(100) NOT NULL,
    var_name     VARCHAR(50)  NOT NULL
);

-- Seed default levels (upsert so re-running is safe)
INSERT INTO hierarchy_config (level, display_name, var_name) VALUES
    (1,  'Region',   'region'),
    (2,  'District', 'district'),
    (3,  'Facility',      'facility'),
    (4,  'Sub-Facility',  'sub_facility'),
    (5,  'Village',  'village'),
    (6,  'Level 6',  'level_6'),
    (7,  'Level 7',  'level_7'),
    (8,  'Level 8',  'level_8'),
    (9,  'Level 9',  'level_9'),
    (10, 'Level 10', 'level_10')
ON CONFLICT (level) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        var_name     = EXCLUDED.var_name;

-- ============================================================================
-- build_drill_url(child_org_unit_id)
-- Dynamically builds a Grafana drill-down URL from the org_unit lineage,
-- using hierarchy_config to map levels to variable names.
-- Works for ANY hierarchy depth — no hard-coded level references.
-- ============================================================================
CREATE OR REPLACE FUNCTION build_drill_url(p_child_id INTEGER)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT '/d/heart360_drilldown?' ||
           string_agg(
               'var-' || hc.var_name || '=' || lin.ancestor_id::text,
               '&' ORDER BY hc.level
           )
    FROM org_unit_lineage lin
    JOIN hierarchy_config hc ON lin.ancestor_level = hc.level
    WHERE lin.org_unit_id = p_child_id;
$$;

-- ============================================================================
-- get_child_level_name(parent_org_unit_id)
-- Returns the display name of the CHILD level for a given org_unit.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_child_level_name(p_org_unit_id INTEGER)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT CASE WHEN ou.level + 1 > 4 THEN 'Sub-unit'
                     ELSE hc.display_name END
         FROM org_units ou
         LEFT JOIN hierarchy_config hc ON hc.level = ou.level + 1
         WHERE ou.id = p_org_unit_id),
        'Sub-unit'
    );
$$;


-- ============================================================================
-- get_access_groups(org_unit_id, access_type)
-- Returns the Grafana group/team names corresponding to a given hierarchy node
-- and all of its descendants recursively.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_access_groups(p_org_unit_id INTEGER, p_access_type VARCHAR)
RETURNS TABLE(group_name VARCHAR)
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE descendants AS (
        SELECT ou.id, ou.name, ou.level
        FROM heart360tk_schema.org_units ou
        WHERE ou.id = p_org_unit_id
        
        UNION ALL
        
        SELECT o.id, o.name, o.level
        FROM heart360tk_schema.org_units o
        JOIN descendants d ON o.parent_id = d.id
    )
    SELECT CAST(
        'heart360tk_' || COALESCE(hc.var_name, 'level_' || d.level) || '_view_' || p_access_type || '_' || replace(lower(trim(d.name)), ' ', '_')
        AS VARCHAR
    ) AS group_name
    FROM descendants d
    LEFT JOIN heart360tk_schema.hierarchy_config hc ON d.level = hc.level;
$$;


CREATE OR REPLACE FUNCTION get_user_visible_org_units(p_user_id INTEGER)
RETURNS TABLE(id INTEGER, name VARCHAR, level INTEGER, parent_id INTEGER, is_granted BOOLEAN)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    -- MATERIALIZED so the grant set is resolved once, not once per org unit.
    WITH allowed AS MATERIALIZED (
        SELECT ou.id, ou.level
        FROM grafana_schema."user" u
        JOIN grafana_schema.team_member tm ON tm.user_id = u.id
        JOIN grafana_schema.team t ON tm.team_id = t.id
        JOIN heart360tk_schema.hierarchy_config hc
          ON t.name ~ ('^heart360tk_' || hc.var_name || '_view_(patients|aggregated)_')
          AND t.name NOT LIKE '%\_ALL' ESCAPE '\'
        JOIN heart360tk_schema.org_units ou
          ON ou.level = hc.level
          AND regexp_replace(lower(trim(ou.name)), '\s+', '_', 'g') =
              regexp_replace(t.name, '^heart360tk_' || hc.var_name || '_view_(patients|aggregated)_', '')
        WHERE u.id = p_user_id
          AND NOT u.is_admin
          AND NOT EXISTS (
              SELECT 1
              FROM grafana_schema.team_member tm2
              JOIN grafana_schema.team t2 ON tm2.team_id = t2.id
              WHERE tm2.user_id = u.id AND t2.name LIKE '%\_ALL' ESCAPE '\'
          )
    ),
    -- Reachable in one pass over the lineage in each direction, rather than
    -- re-checking the lineage once per org unit.
    reachable AS (
        SELECT lin.ancestor_id AS id            -- ancestors of a grant (incl. the grant)
        FROM heart360tk_schema.org_unit_lineage lin
        JOIN allowed a ON a.id = lin.org_unit_id
        UNION
        SELECT lin.org_unit_id AS id            -- descendants of a grant (incl. the grant)
        FROM heart360tk_schema.org_unit_lineage lin
        JOIN allowed a ON a.id = lin.ancestor_id
    )
    SELECT x.id, x.name, x.level, x.parent_id,
           EXISTS (SELECT 1 FROM allowed a WHERE a.id = x.id)
    FROM heart360tk_schema.org_units x
    WHERE NOT EXISTS (SELECT 1 FROM allowed)
       OR x.id IN (SELECT r.id FROM reachable r);
END;
$$;


-- ============================================================================
-- DROP OLD VIEWS
-- ============================================================================
DROP VIEW IF EXISTS HEART360_PATIENTS_REGISTERED CASCADE;
DROP VIEW IF EXISTS HEART360_PATIENTS_UNDER_CARE CASCADE;
DROP VIEW IF EXISTS HEART360_PATIENTS_CATEGORY CASCADE;
DROP VIEW IF EXISTS HEART360_OVERDUE_PATIENTS CASCADE;
DROP VIEW IF EXISTS HEART360_OVERDUE_START_OF_MONTH CASCADE;
DROP VIEW IF EXISTS HEART360_OVERDUE_PATIENTS_CALLED CASCADE;
DROP VIEW IF EXISTS HEART360_OVERDUE_RETURNED_TO_CARE CASCADE;
DROP VIEW IF EXISTS HEART360_BLOOD_SUGAR_CONTROLLED CASCADE;
DROP VIEW IF EXISTS HEART360_BLOOD_SUGAR_SEVERITY CASCADE;
DROP VIEW IF EXISTS HEART360_BLOOD_SUGAR_MISSED_VISITS CASCADE;
DROP VIEW IF EXISTS HEART360_COHORT_PATIENT_DETAILS CASCADE;
DROP VIEW IF EXISTS HEART360_DM_PATIENTS_UNDER_CARE CASCADE;
DROP VIEW IF EXISTS HEART360_DM_PATIENTS_CATAGORY CASCADE;


-- ============================================================================
-- VIEW 1: HEART360_PATIENTS_REGISTERED
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_PATIENTS_REGISTERED AS
WITH
KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS REF_MONTH
  FROM generate_series(
      date_trunc('month', (SELECT min(REGISTRATION_DATE) FROM patients)),
      date_trunc('month', current_date),
      '1 month'::interval
  ) AS t(series_date)
),
PATIENTS_BY_MONTH AS (
    SELECT
        DATE_TRUNC('month', REGISTRATION_DATE) AS REF_MONTH,
        p.org_unit_id,
        count(*) AS NB_NEW_PATIENTS
    FROM patients p
    WHERE LOWER(patient_status) <> 'dead'
      AND EXISTS (
          SELECT 1 FROM patient_diagnoses pd
          WHERE pd.patient_id = p.patient_id
            AND pd.diagnosis_code = 'I10'
      )
    GROUP BY DATE_TRUNC('month', REGISTRATION_DATE), p.org_unit_id
)
SELECT
    KNOWN_MONTHS.REF_MONTH,
    REFERENCE_BEFORE.org_unit_id,
    sum(REFERENCE_BEFORE.NB_NEW_PATIENTS) AS CUMULATIVE_NUMBER_OF_PATIENTS,
    sum(CASE WHEN KNOWN_MONTHS.REF_MONTH = REFERENCE_BEFORE.REF_MONTH THEN NB_NEW_PATIENTS ELSE NULL END) AS NB_NEW_PATIENTS
FROM KNOWN_MONTHS
LEFT OUTER JOIN PATIENTS_BY_MONTH REFERENCE_BEFORE
    ON KNOWN_MONTHS.REF_MONTH >= REFERENCE_BEFORE.REF_MONTH
GROUP BY 1, 2
ORDER BY KNOWN_MONTHS.REF_MONTH DESC;


-- ============================================================================
-- VIEW 2: HEART360_PATIENTS_UNDER_CARE
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_PATIENTS_UNDER_CARE AS
WITH
KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS REF_MONTH
  FROM generate_series(
      date_trunc('month', (SELECT min(REGISTRATION_DATE) FROM patients)),
      date_trunc('month', current_date),
      '1 month'::interval
  ) AS t(series_date)
),
ALIVE_PATIENTS AS (
    SELECT
        DATE_TRUNC('month', REGISTRATION_DATE) AS REGISTRATION_MONTH,
        p.org_unit_id,
        p.patient_id
    FROM patients p
    WHERE LOWER(patient_status) <> 'dead'
      AND EXISTS (
          SELECT 1 FROM patient_diagnoses pd
          WHERE pd.patient_id = p.patient_id
            AND pd.diagnosis_code = 'I10'
      )
),
ALL_ENCOUNTERS AS (
    SELECT e.patient_id,
           DATE_TRUNC('month', e.encounter_date) AS ENCOUNTER_MONTH
    FROM encounters e
)
SELECT
    KNOWN_MONTHS.REF_MONTH,
    ALIVE_PATIENTS.org_unit_id,
    sum(CASE WHEN ALL_ENCOUNTERS.patient_id IS NULL THEN 1 ELSE NULL END) AS NB_PATIENTS_LOST_TO_FOLLOW_UP,
    count(DISTINCT ALL_ENCOUNTERS.patient_id) AS NB_PATIENTS_UNDER_CARE,
    count(DISTINCT ALIVE_PATIENTS.patient_id) AS CUMULATIVE_NUMBER_OF_PATIENTS
FROM KNOWN_MONTHS
LEFT OUTER JOIN ALIVE_PATIENTS
    ON ALIVE_PATIENTS.REGISTRATION_MONTH <= KNOWN_MONTHS.REF_MONTH
LEFT OUTER JOIN ALL_ENCOUNTERS
    ON ALL_ENCOUNTERS.patient_id = ALIVE_PATIENTS.patient_id
        AND ENCOUNTER_MONTH <= KNOWN_MONTHS.REF_MONTH
        AND ENCOUNTER_MONTH + interval '12 month' > KNOWN_MONTHS.REF_MONTH
GROUP BY 1, 2
ORDER BY KNOWN_MONTHS.REF_MONTH DESC;


-- ============================================================================
-- VIEW 3: HEART360_PATIENTS_CATEGORY
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_PATIENTS_CATEGORY AS
WITH
KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS REF_MONTH
  FROM generate_series(
      date_trunc('month', (SELECT min(REGISTRATION_DATE) FROM patients)),
      date_trunc('month', current_date),
      '1 month'::interval
  ) AS t(series_date)
),
ALIVE_PATIENTS AS (
    SELECT
        DATE_TRUNC('month', REGISTRATION_DATE) AS REGISTRATION_MONTH,
        p.org_unit_id,
        p.patient_id AS patient_id
    FROM patients p
    WHERE LOWER(patient_status) <> 'dead'
      AND EXISTS (
          SELECT 1 FROM patient_diagnoses pd
          WHERE pd.patient_id = p.patient_id
            AND pd.diagnosis_code = 'I10'
      )
),
BP_ENCOUNTERS AS (
    SELECT
        e.id AS id,
        e.patient_id,
        bp.systolic_bp AS systolic,
        bp.diastolic_bp AS diastolic,
        e.encounter_date AS BP_ENCOUNTER_DATE,
        DATE_TRUNC('month', e.encounter_date) AS BP_ENCOUNTER_MONTH
    FROM encounters e
    LEFT JOIN blood_pressures bp ON e.id = bp.encounter_id
),
LATEST_BP_BY_MONTH_AND_PATIENT AS (
    WITH MOST_RECENT_BP_ENCOUNTER AS (
        SELECT
            KNOWN_MONTHS.REF_MONTH,
            e.patient_id,
            MAX(e.encounter_date) AS MOST_RECENT_BP_DATE
        FROM encounters e
        JOIN blood_pressures bp ON bp.encounter_id = e.id
        JOIN KNOWN_MONTHS ON DATE_TRUNC('month', e.encounter_date) <= KNOWN_MONTHS.REF_MONTH
        GROUP BY KNOWN_MONTHS.REF_MONTH, e.patient_id
    )
    SELECT
        REF_MONTH, MOST_RECENT_BP_ENCOUNTER.patient_id,
        MAX(systolic) AS systolic,
        MAX(diastolic) AS diastolic,
        MAX(BP_ENCOUNTER_MONTH) AS BP_ENCOUNTER_MONTH
    FROM MOST_RECENT_BP_ENCOUNTER
    JOIN BP_ENCOUNTERS
        ON MOST_RECENT_BP_ENCOUNTER.MOST_RECENT_BP_DATE = BP_ENCOUNTERS.BP_ENCOUNTER_DATE
        AND MOST_RECENT_BP_ENCOUNTER.patient_id = BP_ENCOUNTERS.patient_id
    GROUP BY REF_MONTH, MOST_RECENT_BP_ENCOUNTER.patient_id
),
-- Encounters that count as a hypertension visit:
--   BP encounters + visit-only encounters (no BP AND no BS attached).
-- BS-only encounters are excluded.
HTN_RELEVANT_ENCOUNTERS AS (
    SELECT e.id, e.patient_id, e.encounter_date
    FROM encounters e
    WHERE EXISTS (SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id)
       OR NOT EXISTS (SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id)
),
LATEST_HTN_BY_MONTH_AND_PATIENT AS (
    SELECT
        KNOWN_MONTHS.REF_MONTH,
        hre.patient_id,
        DATE_TRUNC('month', MAX(hre.encounter_date)) AS HTN_ENCOUNTER_MONTH
    FROM HTN_RELEVANT_ENCOUNTERS hre
    JOIN KNOWN_MONTHS ON DATE_TRUNC('month', hre.encounter_date) <= KNOWN_MONTHS.REF_MONTH
    GROUP BY KNOWN_MONTHS.REF_MONTH, hre.patient_id
)
SELECT
    KNOWN_MONTHS.REF_MONTH,
    ALIVE_PATIENTS.org_unit_id,
    count(*) AS TOTAL_NUMBER_OF_PATIENTS,
    -- Under Care = Total Registered - LTFU
    -- A patient is under care if they are EITHER newly registered (still in
    -- their grace period) OR have an HTN-relevant visit within the last 12
    -- months. This guarantees Total = UnderCare + LTFU.
    SUM(CASE
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        ELSE 1 END) AS NB_PATIENTS_UNDER_CARE,
    SUM(CASE
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH
             AND NOT (LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH IS NULL
                      OR LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH)
        THEN 1 ELSE 0 END) AS NB_PATIENTS_NEWLY_REGISTERED,
    SUM(CASE
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0 ELSE 1 END
    ) AS NB_PATIENTS_UNDER_CARE_REGISTERED_BEFORE_THE_PAST_3_MONTHS,
    -- LTFU = latest HTN-relevant visit is older than 12 months OR no visit at all.
    SUM(CASE
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH IS NULL THEN 1
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 1
        ELSE 0 END) AS NB_PATIENTS_LOST_TO_FOLLOW_UP,
    -- "No visit in past 3 months" = latest VISIT is between 3 and 12 months
    -- ago (i.e., NOT LTFU and NOT newly registered).
    SUM(CASE
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_HTN_BY_MONTH_AND_PATIENT.HTN_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 1
        ELSE 0 END) AS NB_PATIENTS_NO_VISIT,
    -- Legacy denominator column kept for backward compatibility with any
    -- consumer; equivalent to NB_PATIENTS_UNDER_CARE_REGISTERED_BEFORE_THE_PAST_3_MONTHS.
    SUM(CASE
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0 ELSE 1 END
    ) AS NB_PATIENTS_UNDER_CARE_REGISTERED_BEFORE_3M_INCL_VISITS,
    SUM(CASE
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN systolic >= 140 OR diastolic >= 90 THEN 1
        ELSE 0 END) AS NB_PATIENTS_UNCONTROLLED,
    SUM(CASE
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN systolic IS NULL OR diastolic IS NULL THEN 0
        WHEN systolic >= 140 OR diastolic >= 90 THEN 0
        ELSE 1 END) AS NB_PATIENTS_CONTROLLED,
    SUM(CASE
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_BP_BY_MONTH_AND_PATIENT.BP_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN systolic IS NULL OR diastolic IS NULL THEN 1
        ELSE 0 END) AS NB_PATIENTS_VISIT_NO_BP
FROM KNOWN_MONTHS
LEFT OUTER JOIN ALIVE_PATIENTS
    ON ALIVE_PATIENTS.REGISTRATION_MONTH <= KNOWN_MONTHS.REF_MONTH
LEFT OUTER JOIN LATEST_BP_BY_MONTH_AND_PATIENT
    ON LATEST_BP_BY_MONTH_AND_PATIENT.patient_id = ALIVE_PATIENTS.patient_id
    AND LATEST_BP_BY_MONTH_AND_PATIENT.REF_MONTH = KNOWN_MONTHS.REF_MONTH
LEFT OUTER JOIN LATEST_HTN_BY_MONTH_AND_PATIENT
    ON LATEST_HTN_BY_MONTH_AND_PATIENT.patient_id = ALIVE_PATIENTS.patient_id
    AND LATEST_HTN_BY_MONTH_AND_PATIENT.REF_MONTH = KNOWN_MONTHS.REF_MONTH
GROUP BY 1, 2
ORDER BY 1 DESC;


-- ============================================================================
-- VIEW 4: HEART360_OVERDUE_PATIENTS
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_OVERDUE_PATIENTS AS
WITH MOST_RECENT_ENCOUNTER AS (
    SELECT DISTINCT ON (e.patient_id)
        e.patient_id,
        e.encounter_date,
        bp.systolic_bp,
        bp.diastolic_bp
    FROM encounters e
    LEFT JOIN blood_pressures bp ON e.id = bp.encounter_id
    WHERE (e.patient_id, e.encounter_date) IN (
        SELECT patient_id, MAX(encounter_date)
        FROM encounters
        GROUP BY patient_id
    )
    ORDER BY e.patient_id, e.encounter_date DESC, e.id DESC, COALESCE(bp.id, 0) DESC
),
MOST_RECENT_CALL AS (
    SELECT DISTINCT ON (patient_id) *
    FROM call_results
    WHERE (patient_id, call_date) IN (
        SELECT patient_id, MAX(call_date)
        FROM call_results
        GROUP BY patient_id
    )
    ORDER BY patient_id, call_date DESC, call_id DESC
)
SELECT
    p.patient_id,
    p.patient_name,
    p.registration_date,
    p.birth_date,
    p.gender,
    p.phone_number,
    p.org_unit_id,
    mre.encounter_date AS last_visit_date,
    mre.diastolic_bp AS last_bp_diastolic,
    mre.systolic_bp AS last_bp_systolic,
    mrc.call_date::TIMESTAMP AS last_call_date,
    mrc.result_type AS last_call_result,
    mrc.removed_reason
FROM patients p
LEFT JOIN MOST_RECENT_ENCOUNTER mre ON p.patient_id = mre.patient_id
LEFT JOIN MOST_RECENT_CALL mrc
    ON p.patient_id = mrc.patient_id
    AND (mre.encounter_date IS NULL OR mrc.call_date::TIMESTAMP > mre.encounter_date)
WHERE (mrc.result_type IS NULL OR LOWER(mrc.result_type) <> 'removed_from_overdue_list');


-- ============================================================================
-- VIEW 5: HEART360_COHORT_PATIENT_DETAILS
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_COHORT_PATIENT_DETAILS AS
WITH patients_quarter AS (
    SELECT
        p.patient_id,
        p.org_unit_id,
        date_trunc('quarter', registration_date) AS registration_quarter,
        date_trunc('quarter', registration_date) + interval '6 month' AS cohort_validation_month,
        registration_date
    FROM patients p
    WHERE EXISTS (
        SELECT 1 FROM patient_diagnoses pd
        WHERE pd.patient_id = p.patient_id
          AND pd.diagnosis_code = 'I10'
    )
),
LAST_BP_IN_INTERVAL AS (
    SELECT
        e.patient_id,
        e.encounter_date,
        bp.systolic_bp,
        bp.diastolic_bp
    FROM encounters e
    LEFT JOIN blood_pressures bp ON e.id = bp.encounter_id
    WHERE e.id IN (
        SELECT max(e2.id) AS encounter_id
        FROM encounters e2
        WHERE (e2.patient_id, e2.encounter_date) IN (
            SELECT
                patients_quarter.patient_id,
                max(e3.encounter_date) AS most_recent_bp
            FROM encounters e3
            JOIN patients_quarter
                ON patients_quarter.patient_id = e3.patient_id
                AND e3.encounter_date < patients_quarter.cohort_validation_month
            GROUP BY patients_quarter.patient_id
        )
        GROUP BY e2.patient_id
    )
)
SELECT
    patients_quarter.patient_id,
    patients_quarter.org_unit_id,
    registration_quarter,
    CASE
        WHEN encounter_date IS NULL THEN 'missed visit'
        WHEN cohort_validation_month > encounter_date + interval '3 month' THEN 'missed visit'
        WHEN diastolic_bp < 90 AND systolic_bp < 140 THEN 'controlled'
        ELSE 'uncontrolled'
    END AS status_at_end_of_interval
FROM patients_quarter
LEFT OUTER JOIN LAST_BP_IN_INTERVAL ON LAST_BP_IN_INTERVAL.patient_id = patients_quarter.patient_id;


-- ============================================================================
-- VIEW 6: HEART360_OVERDUE_START_OF_MONTH
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_OVERDUE_START_OF_MONTH AS
WITH REF_MONTHS AS (
  SELECT generate_series(
      date_trunc('month', (SELECT MIN(registration_date) FROM patients)),
      date_trunc('month', CURRENT_DATE),
      interval '1 month'
  )::date AS ref_month
),
PATIENTS_UNDER_CARE AS (
  SELECT rm.ref_month, p.patient_id
  FROM REF_MONTHS rm
  JOIN patients p
    ON p.registration_date <= rm.ref_month - INTERVAL '3 months'
   AND p.patient_status = 'ALIVE'
   AND p.death_date IS NULL
  WHERE EXISTS (
      SELECT 1 FROM encounters be
      WHERE be.patient_id = p.patient_id
        AND be.encounter_date >= rm.ref_month - INTERVAL '12 months'
        AND be.encounter_date < rm.ref_month
  )
),
LATEST_SCHEDULED AS (
  SELECT rm.ref_month, sv.patient_id, MAX(sv.scheduled_date) AS scheduled_date
  FROM REF_MONTHS rm
  JOIN scheduled_visits sv ON sv.scheduled_date < rm.ref_month
  GROUP BY rm.ref_month, sv.patient_id
),
RETURNED_BEFORE_MONTH AS (
  SELECT DISTINCT ls.ref_month, ls.patient_id
  FROM LATEST_SCHEDULED ls
  JOIN encounters be
    ON be.patient_id = ls.patient_id
   AND be.encounter_date >= ls.scheduled_date
   AND be.encounter_date < ls.ref_month
),
REMOVED_BEFORE_MONTH AS (
  SELECT DISTINCT rm.ref_month, cr.patient_id
  FROM REF_MONTHS rm
  JOIN call_results cr ON cr.call_date < rm.ref_month
  WHERE LOWER(cr.result_type) = 'removed_from_overdue_list'
)
SELECT
  ls.ref_month,
  p.org_unit_id,
  COUNT(DISTINCT ls.patient_id) AS overdue_on_first
FROM LATEST_SCHEDULED ls
JOIN PATIENTS_UNDER_CARE puc
  ON puc.patient_id = ls.patient_id AND puc.ref_month = ls.ref_month
JOIN patients p ON p.patient_id = ls.patient_id
LEFT JOIN RETURNED_BEFORE_MONTH rbm
  ON rbm.patient_id = ls.patient_id AND rbm.ref_month = ls.ref_month
LEFT JOIN REMOVED_BEFORE_MONTH rmb
  ON rmb.patient_id = ls.patient_id AND rmb.ref_month = ls.ref_month
WHERE p.phone_number IS NOT NULL
  AND LENGTH(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g')) >= 8
  AND rbm.patient_id IS NULL
  AND rmb.patient_id IS NULL
GROUP BY ls.ref_month, p.org_unit_id
ORDER BY ls.ref_month;


-- ============================================================================
-- VIEW 7: HEART360_OVERDUE_PATIENTS_CALLED
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_OVERDUE_PATIENTS_CALLED AS
WITH FIRST_CALLS AS (
  SELECT DISTINCT ON (cr.patient_id, date_trunc('month', cr.call_date))
    cr.patient_id,
    date_trunc('month', cr.call_date)::date AS ref_month,
    cr.call_date,
    cr.result_type,
    cr.removed_reason
  FROM call_results cr
  ORDER BY cr.patient_id, date_trunc('month', cr.call_date), cr.call_date ASC
)
SELECT
  fc.ref_month,
  p.org_unit_id,
  COUNT(DISTINCT fc.patient_id) AS overdue_patients_called
FROM FIRST_CALLS fc
JOIN patients p ON p.patient_id = fc.patient_id
WHERE p.patient_status = 'ALIVE'
  AND NOT (
    LOWER(fc.result_type) = 'removed_from_overdue_list'
    AND LOWER(fc.removed_reason) = 'died'
  )
GROUP BY fc.ref_month, p.org_unit_id
ORDER BY fc.ref_month;


-- ============================================================================
-- VIEW 8: HEART360_OVERDUE_RETURNED_TO_CARE
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_OVERDUE_RETURNED_TO_CARE AS
WITH FIRST_CALLS AS (
    SELECT DISTINCT ON (cr.patient_id, date_trunc('month', cr.call_date))
        cr.patient_id,
        date_trunc('month', cr.call_date)::date AS ref_month,
        cr.call_date,
        cr.call_date + INTERVAL '15 days' AS window_end
    FROM call_results cr
    ORDER BY cr.patient_id, date_trunc('month', cr.call_date), cr.call_date ASC
),
RETURNED AS (
    SELECT DISTINCT fc.patient_id, fc.ref_month
    FROM FIRST_CALLS fc
    JOIN encounters be
      ON be.patient_id = fc.patient_id
     AND be.encounter_date >= fc.call_date
     AND be.encounter_date <= fc.window_end
)
SELECT
    r.ref_month,
    p.org_unit_id,
    COUNT(DISTINCT r.patient_id) AS overdue_returned_to_care
FROM RETURNED r
JOIN patients p ON p.patient_id = r.patient_id
WHERE p.patient_status = 'ALIVE'
GROUP BY r.ref_month, p.org_unit_id
ORDER BY r.ref_month;


-- ============================================================================
-- VIEW 9: HEART360_BLOOD_SUGAR_CONTROLLED
-- Fixed: uses DM_RELEVANT_ENCOUNTERS (BS encounter OR no-BP encounter) for the
-- under-care denominator, mirroring HTN_RELEVANT_ENCOUNTERS in HEART360_PATIENTS_CATEGORY.
-- This ensures missed-follow-up DM patients are counted the same way as HTN.
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_BLOOD_SUGAR_CONTROLLED AS
WITH REF_MONTHS AS (
    SELECT generate_series(
        date_trunc('month', (SELECT MIN(registration_date) FROM patients)),
        date_trunc('month', CURRENT_DATE),
        interval '1 month'
    )::date AS ref_month
),
ALL_PATIENTS AS (
    SELECT p.patient_id, p.org_unit_id, p.registration_date, p.death_date
    FROM patients p
    WHERE EXISTS (
        SELECT 1 FROM patient_diagnoses pd
        WHERE pd.patient_id = p.patient_id
          AND pd.diagnosis_code = 'E11'
    )
),
-- DM-relevant encounters: encounters with a BS reading OR no BP reading (visit-only / missed follow-up)
DM_RELEVANT_ENCOUNTERS AS (
    SELECT e.id, e.patient_id, e.encounter_date
    FROM encounters e
    WHERE EXISTS (SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id)
       OR NOT EXISTS (SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id)
),
BS_ENCOUNTERS AS (
    SELECT e.patient_id, e.encounter_date, bs.blood_sugar_type, bs.blood_sugar_value
    FROM encounters e
    JOIN blood_sugars bs ON bs.encounter_id = e.id
),
LATEST_BS AS (
    SELECT rm.ref_month, e.patient_id, MAX(e.encounter_date) AS latest_bs_date
    FROM REF_MONTHS rm
    JOIN BS_ENCOUNTERS e ON DATE_TRUNC('month', e.encounter_date) <= rm.ref_month
    GROUP BY rm.ref_month, e.patient_id
),
LATEST_BS_VALUES AS (
    SELECT lb.ref_month, e.patient_id, e.encounter_date, e.blood_sugar_type, e.blood_sugar_value
    FROM LATEST_BS lb
    JOIN BS_ENCOUNTERS e
        ON lb.patient_id = e.patient_id AND lb.latest_bs_date = e.encounter_date
)
SELECT
    rm.ref_month,
    p.org_unit_id,
    COUNT(DISTINCT p.patient_id) FILTER (
        WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= rm.ref_month
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
            )
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
                AND DATE_TRUNC('month', dre.encounter_date) <= rm.ref_month
                AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > rm.ref_month
            )
    ) AS diabetes_patients_under_care,
    COUNT(DISTINCT p.patient_id) FILTER (
        WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= rm.ref_month
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
            )
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
                AND DATE_TRUNC('month', dre.encounter_date) <= rm.ref_month
                AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > rm.ref_month
            )
            AND DATE_TRUNC('month', lbv.encounter_date) + interval '3 month' > rm.ref_month
            AND (
                (LOWER(lbv.blood_sugar_type) IN ('rbs', 'random') AND lbv.blood_sugar_value < 140)
                OR (LOWER(lbv.blood_sugar_type) IN ('fbs', 'fasting') AND lbv.blood_sugar_value < 126)
                OR (LOWER(lbv.blood_sugar_type) = 'hba1c' AND lbv.blood_sugar_value < 7)
            )
    ) AS diabetes_controlled
FROM REF_MONTHS rm
LEFT JOIN ALL_PATIENTS p
    ON p.registration_date <= rm.ref_month
    AND (p.death_date IS NULL OR DATE_TRUNC('month', p.death_date) >= rm.ref_month)
LEFT JOIN LATEST_BS_VALUES lbv
    ON lbv.patient_id = p.patient_id AND lbv.ref_month = rm.ref_month
GROUP BY rm.ref_month, p.org_unit_id
ORDER BY rm.ref_month;


-- ============================================================================
-- VIEW 10: HEART360_BLOOD_SUGAR_SEVERITY
-- Fixed: uses DM_RELEVANT_ENCOUNTERS for under-care denominator.
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_BLOOD_SUGAR_SEVERITY AS
WITH KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS ref_month
  FROM generate_series(
      date_trunc('month', (SELECT min(registration_date) FROM patients)),
      date_trunc('month', current_date),
      interval '1 month'
  ) AS t(series_date)
),
ALL_PATIENTS AS (
  SELECT p.patient_id, p.org_unit_id, p.registration_date, p.death_date
  FROM patients p
  WHERE EXISTS (
      SELECT 1 FROM patient_diagnoses pd
      WHERE pd.patient_id = p.patient_id
        AND pd.diagnosis_code = 'E11'
  )
),
-- DM-relevant encounters: encounters with a BS reading OR no BP reading
DM_RELEVANT_ENCOUNTERS AS (
    SELECT e.id, e.patient_id, e.encounter_date
    FROM encounters e
    WHERE EXISTS (SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id)
       OR NOT EXISTS (SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id)
),
BS_ENCOUNTERS AS (
  SELECT e.patient_id, e.encounter_date, bs.blood_sugar_type, bs.blood_sugar_value
  FROM encounters e
  JOIN blood_sugars bs ON bs.encounter_id = e.id
),
LATEST_BS AS (
  SELECT km.ref_month, e.patient_id, MAX(e.encounter_date) AS latest_bs_date
  FROM KNOWN_MONTHS km
  JOIN BS_ENCOUNTERS e ON DATE_TRUNC('month', e.encounter_date) <= km.ref_month
  GROUP BY km.ref_month, e.patient_id
),
LATEST_BS_VALUES AS (
  SELECT lb.ref_month, e.patient_id, e.encounter_date, e.blood_sugar_type, e.blood_sugar_value
  FROM LATEST_BS lb
  JOIN BS_ENCOUNTERS e ON lb.patient_id = e.patient_id AND lb.latest_bs_date = e.encounter_date
)
SELECT
  km.ref_month,
  p.org_unit_id,
  COUNT(DISTINCT p.patient_id) FILTER (
    WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= km.ref_month
      AND EXISTS (
            SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
            WHERE dre.patient_id = p.patient_id
        )
      AND EXISTS (
            SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
            WHERE dre.patient_id = p.patient_id
              AND DATE_TRUNC('month', dre.encounter_date) <= km.ref_month
              AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > km.ref_month
        )
  ) AS diabetes_patients_under_care,
  COUNT(DISTINCT p.patient_id) FILTER (
    WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= km.ref_month
      AND EXISTS (
            SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
            WHERE dre.patient_id = p.patient_id
        )
      AND EXISTS (
            SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
            WHERE dre.patient_id = p.patient_id
              AND DATE_TRUNC('month', dre.encounter_date) <= km.ref_month
              AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > km.ref_month
        )
      AND DATE_TRUNC('month', lbv.encounter_date) + interval '3 month' > km.ref_month
      AND (
           (LOWER(lbv.blood_sugar_type) IN ('rbs', 'random') AND lbv.blood_sugar_value >= 140 AND lbv.blood_sugar_value <= 199)
        OR (LOWER(lbv.blood_sugar_type) IN ('fbs', 'fasting') AND lbv.blood_sugar_value >= 126 AND lbv.blood_sugar_value <= 199)
        OR (LOWER(lbv.blood_sugar_type) = 'hba1c' AND lbv.blood_sugar_value >= 7 AND lbv.blood_sugar_value <= 8.9)
      )
  ) AS uncontrolled_moderate,
  COUNT(DISTINCT p.patient_id) FILTER (
    WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= km.ref_month
      AND EXISTS (
            SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
            WHERE dre.patient_id = p.patient_id
        )
      AND EXISTS (
            SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
            WHERE dre.patient_id = p.patient_id
              AND DATE_TRUNC('month', dre.encounter_date) <= km.ref_month
              AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > km.ref_month
        )
      AND DATE_TRUNC('month', lbv.encounter_date) + interval '3 month' > km.ref_month
      AND (
           (LOWER(lbv.blood_sugar_type) IN ('rbs', 'random') AND lbv.blood_sugar_value >= 200)
        OR (LOWER(lbv.blood_sugar_type) IN ('fbs', 'fasting') AND lbv.blood_sugar_value >= 200)
        OR (LOWER(lbv.blood_sugar_type) = 'hba1c' AND lbv.blood_sugar_value >= 9)
      )
  ) AS uncontrolled_high
FROM KNOWN_MONTHS km
LEFT JOIN ALL_PATIENTS p
  ON p.registration_date <= km.ref_month
  AND (p.death_date IS NULL OR DATE_TRUNC('month', p.death_date) >= km.ref_month)
LEFT JOIN LATEST_BS_VALUES lbv
  ON lbv.patient_id = p.patient_id AND lbv.ref_month = km.ref_month
GROUP BY km.ref_month, p.org_unit_id
ORDER BY km.ref_month;


-- ============================================================================
-- VIEW 11: HEART360_BLOOD_SUGAR_MISSED_VISITS
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_BLOOD_SUGAR_MISSED_VISITS AS
WITH KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS ref_month
  FROM generate_series(
      date_trunc('month', (SELECT min(registration_date) FROM patients)),
      date_trunc('month', current_date),
      interval '1 month'
  ) AS t(series_date)
),
ALL_PATIENTS AS (
  SELECT p.patient_id, p.org_unit_id, p.registration_date, p.death_date
  FROM patients p
  WHERE EXISTS (
      SELECT 1 FROM patient_diagnoses pd
      WHERE pd.patient_id = p.patient_id
        AND pd.diagnosis_code = 'E11'
  )
),
DM_RELEVANT_ENCOUNTERS AS (
  SELECT
    e.patient_id,
    date_trunc('month', e.encounter_date)::date AS encounter_month,
    e.encounter_date
  FROM encounters e
  WHERE EXISTS (
    SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id
  )
  OR NOT EXISTS (
    SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id
  )
),
PATIENT_MONTHLY_ACTIVE AS (
  SELECT
    km.ref_month,
    e.patient_id
  FROM KNOWN_MONTHS km
  JOIN DM_RELEVANT_ENCOUNTERS e
    ON e.encounter_month <= km.ref_month
   AND e.encounter_month + interval '12 month' > km.ref_month
  GROUP BY km.ref_month, e.patient_id
),
LAST_VISIT_PER_MONTH AS (
  SELECT
    km.ref_month,
    e.patient_id,
    MAX(e.encounter_date) AS last_visit_date
  FROM KNOWN_MONTHS km
  JOIN DM_RELEVANT_ENCOUNTERS e
    ON e.encounter_month <= km.ref_month
  GROUP BY km.ref_month, e.patient_id
)
SELECT
  km.ref_month,
  p.org_unit_id,
  COUNT(DISTINCT p.patient_id) FILTER (
    WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= km.ref_month
      AND pma.patient_id IS NOT NULL
  ) AS diabetes_patients_under_care,
  COUNT(DISTINCT p.patient_id) FILTER (
    WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= km.ref_month
      AND pma.patient_id IS NOT NULL
      AND DATE_TRUNC('month', lv.last_visit_date) + interval '3 month' <= km.ref_month
  ) AS missed_visit
FROM KNOWN_MONTHS km
LEFT JOIN ALL_PATIENTS p
  ON p.registration_date <= km.ref_month
  AND (p.death_date IS NULL OR DATE_TRUNC('month', p.death_date) >= km.ref_month)
LEFT JOIN PATIENT_MONTHLY_ACTIVE pma
  ON pma.patient_id = p.patient_id
  AND pma.ref_month = km.ref_month
LEFT JOIN LAST_VISIT_PER_MONTH lv
  ON lv.patient_id = p.patient_id
  AND lv.ref_month = km.ref_month
GROUP BY km.ref_month, p.org_unit_id
ORDER BY km.ref_month;


-- ============================================================================
-- VIEW 12: HEART360_DM_PATIENTS_UNDER_CARE
-- DM patients under care, cumulative registrations, and monthly registrations.
-- Fixed: uses DM_RELEVANT_ENCOUNTERS (BS encounter OR no-BP encounter) so the
-- under-care window matches the HTN dashboard denominator methodology.
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_DM_PATIENTS_UNDER_CARE AS
WITH
KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS ref_month
  FROM generate_series(
      date_trunc('month', (SELECT MIN(registration_date) FROM patients)),
      date_trunc('month', CURRENT_DATE),
      '1 month'::interval
  ) AS t(series_date)
),
ALIVE_PATIENTS AS (
  SELECT
      DATE_TRUNC('month', p.registration_date)::date AS registration_month,
      p.org_unit_id,
      p.patient_id
  FROM patients p
  WHERE LOWER(p.patient_status) <> 'dead'
    AND EXISTS (
        SELECT 1 FROM patient_diagnoses pd
        WHERE pd.patient_id = p.patient_id
          AND pd.diagnosis_code = 'E11'
    )
),
-- DM-relevant encounters: encounters with a BS reading OR no BP reading
DM_RELEVANT_ENCOUNTERS AS (
    SELECT e.patient_id,
           DATE_TRUNC('month', e.encounter_date) AS encounter_month
    FROM encounters e
    WHERE EXISTS (SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id)
       OR NOT EXISTS (SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id)
)
SELECT
    km.ref_month,
    ap.org_unit_id,
    COUNT(DISTINCT CASE
      WHEN dre.patient_id IS NOT NULL THEN ap.patient_id
    END) AS nb_dm_patients_under_care,
    COUNT(DISTINCT ap.patient_id) AS cumulative_dm_patients,
    COUNT(DISTINCT ap.patient_id) FILTER (
      WHERE ap.registration_month = km.ref_month
    ) AS nb_new_dm_patients,
    SUM(CASE WHEN dre.patient_id IS NULL THEN 1 ELSE NULL END) AS nb_patients_lost_to_follow_up
FROM KNOWN_MONTHS km
LEFT JOIN ALIVE_PATIENTS ap
    ON ap.registration_month <= km.ref_month
LEFT JOIN DM_RELEVANT_ENCOUNTERS dre
    ON dre.patient_id = ap.patient_id
    AND dre.encounter_month <= km.ref_month
    AND dre.encounter_month + interval '12 month' > km.ref_month
GROUP BY km.ref_month, ap.org_unit_id
ORDER BY km.ref_month DESC;


-- ============================================================================
-- VIEW 13: HEART360_DM_BP_CONTROL
-- DM patients with controlled BP at their latest visit in the past 3 months.
-- Denominator matches HEART360_BLOOD_SUGAR_CONTROLLED diabetes_patients_under_care:
-- E11 only, registered 3+ months before ref_month, DM_RELEVANT_ENCOUNTERS visit in past 12 months.
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_DM_BP_CONTROL AS
WITH REF_MONTHS AS (
    SELECT generate_series(
        date_trunc('month', (SELECT MIN(registration_date) FROM patients)),
        date_trunc('month', CURRENT_DATE),
        interval '1 month'
    )::date AS ref_month
),
ALL_PATIENTS AS (
    SELECT p.patient_id, p.org_unit_id, p.registration_date, p.death_date
    FROM patients p
    WHERE EXISTS (
        SELECT 1 FROM patient_diagnoses pd
        WHERE pd.patient_id = p.patient_id
          AND pd.diagnosis_code = 'E11'
    )
),
-- DM-relevant encounters: encounters with a BS reading OR no BP reading
DM_RELEVANT_ENCOUNTERS AS (
    SELECT e.id, e.patient_id, e.encounter_date
    FROM encounters e
    WHERE EXISTS (SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id)
       OR NOT EXISTS (SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id)
),
LATEST_BP AS (
    SELECT rm.ref_month, e.patient_id, MAX(e.encounter_date) AS latest_bp_date
    FROM REF_MONTHS rm
    JOIN encounters e ON DATE_TRUNC('month', e.encounter_date) <= rm.ref_month
    JOIN blood_pressures bp ON bp.encounter_id = e.id
    GROUP BY rm.ref_month, e.patient_id
),
LATEST_BP_VALUES AS (
    SELECT lb.ref_month, lb.patient_id, lb.latest_bp_date AS encounter_date,
           MAX(bp.systolic_bp) AS systolic_bp, MAX(bp.diastolic_bp) AS diastolic_bp
    FROM LATEST_BP lb
    JOIN encounters e ON e.patient_id = lb.patient_id AND e.encounter_date = lb.latest_bp_date
    JOIN blood_pressures bp ON bp.encounter_id = e.id
    GROUP BY lb.ref_month, lb.patient_id, lb.latest_bp_date
)
SELECT
    rm.ref_month,
    p.org_unit_id,
    COUNT(DISTINCT p.patient_id) FILTER (
        WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= rm.ref_month
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
            )
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
                AND DATE_TRUNC('month', dre.encounter_date) <= rm.ref_month
                AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > rm.ref_month
            )
    ) AS dm_patients_under_care,
    COUNT(DISTINCT p.patient_id) FILTER (
        WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= rm.ref_month
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
            )
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
                AND DATE_TRUNC('month', dre.encounter_date) <= rm.ref_month
                AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > rm.ref_month
            )
            AND lbp.encounter_date IS NOT NULL
            AND DATE_TRUNC('month', lbp.encounter_date) + interval '3 month' > rm.ref_month
            AND lbp.systolic_bp < 140 AND lbp.diastolic_bp < 90
            AND NOT (lbp.systolic_bp < 130 AND lbp.diastolic_bp < 80)
    ) AS bp_controlled_140_90,
    COUNT(DISTINCT p.patient_id) FILTER (
        WHERE DATE_TRUNC('month', p.registration_date) + interval '3 month' <= rm.ref_month
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
            )
            AND EXISTS (
                SELECT 1 FROM DM_RELEVANT_ENCOUNTERS dre
                WHERE dre.patient_id = p.patient_id
                AND DATE_TRUNC('month', dre.encounter_date) <= rm.ref_month
                AND DATE_TRUNC('month', dre.encounter_date) + interval '12 month' > rm.ref_month
            )
            AND lbp.encounter_date IS NOT NULL
            AND DATE_TRUNC('month', lbp.encounter_date) + interval '3 month' > rm.ref_month
            AND lbp.systolic_bp < 130 AND lbp.diastolic_bp < 80
    ) AS bp_controlled_130_80
FROM REF_MONTHS rm
LEFT JOIN ALL_PATIENTS p
    ON p.registration_date <= rm.ref_month
    AND (p.death_date IS NULL OR DATE_TRUNC('month', p.death_date) >= rm.ref_month)
LEFT JOIN LATEST_BP_VALUES lbp
    ON lbp.patient_id = p.patient_id AND lbp.ref_month = rm.ref_month
GROUP BY rm.ref_month, p.org_unit_id
ORDER BY rm.ref_month;

-- ============================================================================
-- VIEW 14: HEART360_DM_PATIENTS_CATAGORY
-- DM equivalent of HEART360_PATIENTS_CATEGORY. Produces identical columns so
-- the DM dashboard can use the same graph formulas as HTN:
--   % LTFU         = NB_PATIENTS_LOST_TO_FOLLOW_UP x 100 / TOTAL_NUMBER_OF_PATIENTS
--   % Missed Visit = NB_PATIENTS_NO_VISIT          x 100 / denom
--   % Controlled   = NB_PATIENTS_CONTROLLED        x 100 / denom
--   % Uncontrolled = NB_PATIENTS_UNCONTROLLED      x 100 / denom
-- where denom = NB_PATIENTS_UNDER_CARE_REGISTERED_BEFORE_THE_PAST_3_MONTHS
--             = TOTAL - NEWLY - LTFU
-- ============================================================================
CREATE OR REPLACE VIEW HEART360_DM_PATIENTS_CATAGORY AS
WITH
KNOWN_MONTHS AS (
  SELECT date_trunc('month', series_date)::date AS REF_MONTH
  FROM generate_series(
      date_trunc('month', (SELECT min(REGISTRATION_DATE) FROM patients)),
      date_trunc('month', current_date),
      '1 month'::interval
  ) AS t(series_date)
),
ALIVE_PATIENTS AS (
    SELECT
        DATE_TRUNC('month', REGISTRATION_DATE) AS REGISTRATION_MONTH,
        p.org_unit_id,
        p.patient_id AS patient_id
    FROM patients p
    WHERE LOWER(patient_status) <> 'dead'
      AND EXISTS (
          SELECT 1 FROM patient_diagnoses pd
          WHERE pd.patient_id = p.patient_id
            AND pd.diagnosis_code = 'E11'
      )
),
-- DM-relevant encounters: encounters with a BS reading OR no BP reading (visit-only / missed follow-up).
-- Mirrors HTN_RELEVANT_ENCOUNTERS from HEART360_PATIENTS_CATEGORY so missed-follow-up
-- DM patients are captured the same way as missed-follow-up HTN patients.
DM_RELEVANT_ENCOUNTERS AS (
    SELECT e.id, e.patient_id, e.encounter_date
    FROM encounters e
    WHERE EXISTS (SELECT 1 FROM blood_sugars bs WHERE bs.encounter_id = e.id)
       OR NOT EXISTS (SELECT 1 FROM blood_pressures bp WHERE bp.encounter_id = e.id)
),
BS_ENCOUNTERS AS (
    SELECT
        e.id AS id,
        e.patient_id,
        bs.blood_sugar_value AS bs_value,
        bs.blood_sugar_type  AS bs_type,
        e.encounter_date     AS BS_ENCOUNTER_DATE,
        DATE_TRUNC('month', e.encounter_date) AS BS_ENCOUNTER_MONTH
    FROM encounters e
    LEFT JOIN blood_sugars bs ON e.id = bs.encounter_id
),
LATEST_BS_BY_MONTH_AND_PATIENT AS (
    WITH MOST_RECENT_BS_ENCOUNTER AS (
        SELECT
            KNOWN_MONTHS.REF_MONTH,
            e.patient_id,
            MAX(e.encounter_date) AS MOST_RECENT_BS_DATE
        FROM encounters e
        JOIN blood_sugars bs ON bs.encounter_id = e.id
        JOIN KNOWN_MONTHS ON DATE_TRUNC('month', e.encounter_date) <= KNOWN_MONTHS.REF_MONTH
        GROUP BY KNOWN_MONTHS.REF_MONTH, e.patient_id
    )
    SELECT
        REF_MONTH,
        MOST_RECENT_BS_ENCOUNTER.patient_id,
        MAX(bse.bs_value)           AS bs_value,
        MAX(bse.bs_type)            AS bs_type,
        MAX(bse.BS_ENCOUNTER_MONTH) AS BS_ENCOUNTER_MONTH
    FROM MOST_RECENT_BS_ENCOUNTER
    JOIN BS_ENCOUNTERS bse
        ON MOST_RECENT_BS_ENCOUNTER.MOST_RECENT_BS_DATE = bse.BS_ENCOUNTER_DATE
       AND MOST_RECENT_BS_ENCOUNTER.patient_id          = bse.patient_id
    GROUP BY REF_MONTH, MOST_RECENT_BS_ENCOUNTER.patient_id
),
LATEST_DM_BY_MONTH_AND_PATIENT AS (
    SELECT
        KNOWN_MONTHS.REF_MONTH,
        dre.patient_id,
        DATE_TRUNC('month', MAX(dre.encounter_date)) AS DM_ENCOUNTER_MONTH
    FROM DM_RELEVANT_ENCOUNTERS dre
    JOIN KNOWN_MONTHS ON DATE_TRUNC('month', dre.encounter_date) <= KNOWN_MONTHS.REF_MONTH
    GROUP BY KNOWN_MONTHS.REF_MONTH, dre.patient_id
)
SELECT
    KNOWN_MONTHS.REF_MONTH,
    ALIVE_PATIENTS.org_unit_id,
    count(*) AS TOTAL_NUMBER_OF_PATIENTS,
    -- Under care: visited within last 12 months
    SUM(CASE
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        ELSE 1 END) AS NB_PATIENTS_UNDER_CARE,
    SUM(CASE
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH
             AND NOT (LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH IS NULL
                      OR LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH)
        THEN 1 ELSE 0 END) AS NB_PATIENTS_NEWLY_REGISTERED,
    -- Denom = registered > 3 months ago AND has a BS reading in last 12 months
    SUM(CASE
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0 ELSE 1 END
    ) AS NB_PATIENTS_UNDER_CARE_REGISTERED_BEFORE_THE_PAST_3_MONTHS,
    -- LTFU: no DM-relevant visit in last 12 months
    SUM(CASE
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH IS NULL THEN 1
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 1
        ELSE 0 END) AS NB_PATIENTS_LOST_TO_FOLLOW_UP,
    -- No visit: under care but latest DM-relevant visit > 3 months ago
    SUM(CASE
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_DM_BY_MONTH_AND_PATIENT.DM_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 1
        ELSE 0 END) AS NB_PATIENTS_NO_VISIT,
    SUM(CASE
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0 ELSE 1 END
    ) AS NB_PATIENTS_UNDER_CARE_REGISTERED_BEFORE_3M_INCL_VISITS,
    -- Uncontrolled: latest BS within 3 months and above threshold
    SUM(CASE
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN (
            (LOWER(COALESCE(LATEST_BS_BY_MONTH_AND_PATIENT.bs_type, '')) IN ('rbs', 'random') AND LATEST_BS_BY_MONTH_AND_PATIENT.bs_value >= 140)
            OR (LOWER(COALESCE(LATEST_BS_BY_MONTH_AND_PATIENT.bs_type, '')) IN ('fbs', 'fasting') AND LATEST_BS_BY_MONTH_AND_PATIENT.bs_value >= 126)
            OR (LOWER(COALESCE(LATEST_BS_BY_MONTH_AND_PATIENT.bs_type, '')) = 'hba1c' AND LATEST_BS_BY_MONTH_AND_PATIENT.bs_value >= 7)
        ) THEN 1
        ELSE 0 END) AS NB_PATIENTS_UNCONTROLLED,
    -- Controlled: latest BS within 3 months and below threshold
    SUM(CASE
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.bs_value IS NULL OR LATEST_BS_BY_MONTH_AND_PATIENT.bs_type IS NULL THEN 0
        WHEN (
            (LOWER(COALESCE(LATEST_BS_BY_MONTH_AND_PATIENT.bs_type, '')) IN ('rbs', 'random') AND LATEST_BS_BY_MONTH_AND_PATIENT.bs_value >= 140)
            OR (LOWER(COALESCE(LATEST_BS_BY_MONTH_AND_PATIENT.bs_type, '')) IN ('fbs', 'fasting') AND LATEST_BS_BY_MONTH_AND_PATIENT.bs_value >= 126)
            OR (LOWER(COALESCE(LATEST_BS_BY_MONTH_AND_PATIENT.bs_type, '')) = 'hba1c' AND LATEST_BS_BY_MONTH_AND_PATIENT.bs_value >= 7)
        ) THEN 0
        ELSE 1 END) AS NB_PATIENTS_CONTROLLED,
    -- Visited within 3 months but no BS reading recorded
    SUM(CASE
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH IS NULL THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '12 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN ALIVE_PATIENTS.REGISTRATION_MONTH + interval '3 month' > KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.BS_ENCOUNTER_MONTH + interval '3 month' <= KNOWN_MONTHS.REF_MONTH THEN 0
        WHEN LATEST_BS_BY_MONTH_AND_PATIENT.bs_value IS NULL OR LATEST_BS_BY_MONTH_AND_PATIENT.bs_type IS NULL THEN 1
        ELSE 0 END) AS NB_PATIENTS_VISIT_NO_BS
FROM KNOWN_MONTHS
LEFT OUTER JOIN ALIVE_PATIENTS
    ON ALIVE_PATIENTS.REGISTRATION_MONTH <= KNOWN_MONTHS.REF_MONTH
LEFT OUTER JOIN LATEST_BS_BY_MONTH_AND_PATIENT
    ON LATEST_BS_BY_MONTH_AND_PATIENT.patient_id = ALIVE_PATIENTS.patient_id
    AND LATEST_BS_BY_MONTH_AND_PATIENT.REF_MONTH  = KNOWN_MONTHS.REF_MONTH
LEFT OUTER JOIN LATEST_DM_BY_MONTH_AND_PATIENT
    ON LATEST_DM_BY_MONTH_AND_PATIENT.patient_id = ALIVE_PATIENTS.patient_id
    AND LATEST_DM_BY_MONTH_AND_PATIENT.REF_MONTH  = KNOWN_MONTHS.REF_MONTH
GROUP BY 1, 2
ORDER BY 1 DESC;

-- ============================================================================
-- Reporting tables for saving precalculated data
-- ============================================================================

DROP TABLE IF EXISTS heart360tk_reporting.IMPORT_FACILITY_MAPPING;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_PATIENTS_CATEGORY;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_PATIENTS_UNDER_CARE;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_PATIENTS_REGISTERED;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_BLOOD_SUGAR_CONTROLLED;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_BLOOD_SUGAR_SEVERITY;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_BLOOD_SUGAR_MISSED_VISITS;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_DM_BP_CONTROL;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_DM_PATIENTS_UNDER_CARE;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_OVERDUE_PATIENTS;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_OVERDUE_START_OF_MONTH;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_OVERDUE_PATIENTS_CALLED;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_OVERDUE_RETURNED_TO_CARE;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_COHORT_PATIENT_DETAILS;
DROP TABLE IF EXISTS heart360tk_reporting.HEART360_DM_PATIENTS_CATAGORY;

CREATE TABLE IF NOT EXISTS heart360tk_reporting.IMPORT_FACILITY_MAPPING (
    leaf_node_key character varying(255),
    leaf_org_unit_id integer,
    central_org_unit_id integer,
    last_updated_date timestamp,
    last_extract_date timestamp
);

CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_PATIENTS_CATEGORY AS SELECT * FROM heart360tk_schema.HEART360_PATIENTS_CATEGORY where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_PATIENTS_UNDER_CARE AS SELECT * FROM heart360tk_schema.HEART360_PATIENTS_UNDER_CARE where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_PATIENTS_REGISTERED AS SELECT * FROM heart360tk_schema.HEART360_PATIENTS_REGISTERED where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_BLOOD_SUGAR_CONTROLLED AS SELECT * FROM heart360tk_schema.HEART360_BLOOD_SUGAR_CONTROLLED where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_BLOOD_SUGAR_SEVERITY AS SELECT * FROM heart360tk_schema.HEART360_BLOOD_SUGAR_SEVERITY where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_BLOOD_SUGAR_MISSED_VISITS AS SELECT * FROM heart360tk_schema.HEART360_BLOOD_SUGAR_MISSED_VISITS where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_DM_BP_CONTROL AS SELECT * FROM heart360tk_schema.HEART360_DM_BP_CONTROL where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_DM_PATIENTS_UNDER_CARE AS SELECT * FROM heart360tk_schema.HEART360_DM_PATIENTS_UNDER_CARE where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_OVERDUE_PATIENTS AS SELECT * FROM heart360tk_schema.HEART360_OVERDUE_PATIENTS where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_OVERDUE_START_OF_MONTH AS SELECT * FROM heart360tk_schema.HEART360_OVERDUE_START_OF_MONTH where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_OVERDUE_PATIENTS_CALLED AS SELECT * FROM heart360tk_schema.HEART360_OVERDUE_PATIENTS_CALLED where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_OVERDUE_RETURNED_TO_CARE AS SELECT * FROM heart360tk_schema.HEART360_OVERDUE_RETURNED_TO_CARE where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_COHORT_PATIENT_DETAILS AS SELECT * FROM heart360tk_schema.HEART360_COHORT_PATIENT_DETAILS where 1=0;
CREATE TABLE IF NOT EXISTS heart360tk_reporting.HEART360_DM_PATIENTS_CATAGORY AS SELECT * FROM heart360tk_schema.HEART360_DM_PATIENTS_CATAGORY where 1=0;

CREATE INDEX IF NOT EXISTS idx_import_facility_mapping_leaf_node_key ON heart360tk_reporting.IMPORT_FACILITY_MAPPING (leaf_node_key);

-- ============================================================================
-- Export run audit log — one row per exporter execution (success or failure).
-- Allows detecting leaf nodes that have stopped exporting.
-- ============================================================================
DROP TABLE IF EXISTS heart360tk_reporting.export_run_log;
CREATE TABLE heart360tk_reporting.export_run_log (
    id               SERIAL          PRIMARY KEY,
    source_key       TEXT            NOT NULL,
    started_at       TIMESTAMPTZ     NOT NULL,
    finished_at      TIMESTAMPTZ,
    status           TEXT            NOT NULL CHECK (status IN ('success', 'failed')),
    duration_seconds NUMERIC(10, 2),
    destination      TEXT,
    error_message    TEXT
);

CREATE INDEX IF NOT EXISTS idx_export_run_log_source_key
    ON heart360tk_reporting.export_run_log (source_key, started_at DESC);

GRANT INSERT, SELECT ON heart360tk_reporting.export_run_log TO heart360tk;
GRANT USAGE ON SEQUENCE heart360tk_reporting.export_run_log_id_seq TO heart360tk;

-- ============================================================================
-- Importer run audit log — one row per import execution (success or failure).
-- Allows detecting leaf nodes for which import fails.
-- ============================================================================
DROP TABLE IF EXISTS heart360tk_reporting.import_run_log;
CREATE TABLE heart360tk_reporting.import_run_log (
    id               SERIAL          PRIMARY KEY,
    source_key       TEXT            NOT NULL,
    started_at       TIMESTAMPTZ     NOT NULL,
    finished_at      TIMESTAMPTZ,
    status           TEXT            NOT NULL CHECK (status IN ('success', 'failed')),
    duration_seconds NUMERIC(10, 2),
    error_message    TEXT
);

CREATE INDEX IF NOT EXISTS idx_import_run_log_source_key
    ON heart360tk_reporting.import_run_log (source_key, started_at DESC);

GRANT INSERT, SELECT ON heart360tk_reporting.import_run_log TO heart360tk;
GRANT USAGE ON SEQUENCE heart360tk_reporting.import_run_log_id_seq TO heart360tk;

CREATE UNIQUE INDEX IF NOT EXISTS idx_pat_cat_org_month ON heart360tk_reporting.HEART360_PATIENTS_CATEGORY (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pat_under_care_org_month ON heart360tk_reporting.HEART360_PATIENTS_UNDER_CARE (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pat_registered_org_month ON heart360tk_reporting.HEART360_PATIENTS_REGISTERED (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pat_registered_org_month ON heart360tk_reporting.HEART360_PATIENTS_REGISTERED (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bs_controlled_org_month ON heart360tk_reporting.HEART360_BLOOD_SUGAR_CONTROLLED (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bs_severity_org_month ON heart360tk_reporting.HEART360_BLOOD_SUGAR_SEVERITY (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bs_missed_visits_org_month ON heart360tk_reporting.HEART360_BLOOD_SUGAR_MISSED_VISITS (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dm_bp_control_org_month ON heart360tk_reporting.HEART360_DM_BP_CONTROL (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dm_pat_under_care_org_month ON heart360tk_reporting.HEART360_DM_PATIENTS_UNDER_CARE (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_overdue_patient_id ON heart360tk_reporting.HEART360_OVERDUE_PATIENTS (patient_id);
CREATE INDEX IF NOT EXISTS idx_overdue_org_last_visit ON heart360tk_reporting.HEART360_OVERDUE_PATIENTS (org_unit_id, last_visit_date);
CREATE UNIQUE INDEX IF NOT EXISTS idx_overdue_start_month_org_month ON heart360tk_reporting.HEART360_OVERDUE_START_OF_MONTH (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_overdue_called_org_month ON heart360tk_reporting.HEART360_OVERDUE_PATIENTS_CALLED (org_unit_id, ref_month);
CREATE UNIQUE INDEX IF NOT EXISTS idx_overdue_returned_org_month ON heart360tk_reporting.HEART360_OVERDUE_RETURNED_TO_CARE (org_unit_id, ref_month);
CREATE INDEX IF NOT EXISTS idx_cohort_org_quarter ON heart360tk_reporting.HEART360_COHORT_PATIENT_DETAILS (org_unit_id, registration_quarter);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pat_dm_cat_org_month ON heart360tk_reporting.HEART360_DM_PATIENTS_CATAGORY (org_unit_id, ref_month);

CREATE TABLE IF NOT EXISTS heart360tk_reporting.reporting_table_refresh_log (
    id serial PRIMARY KEY,
    reporting_table_name text NOT NULL,
    last_refreshed_at timestamp NOT NULL DEFAULT now(),
    refresh_duration interval,
    status text NOT NULL,
    refresh_batch_id bigint
);

CREATE INDEX IF NOT EXISTS idx_refresh_log_table_name ON heart360tk_reporting.reporting_table_refresh_log (reporting_table_name);
CREATE INDEX IF NOT EXISTS idx_refresh_log_last_refreshed ON heart360tk_reporting.reporting_table_refresh_log (last_refreshed_at DESC);
CREATE INDEX IF NOT EXISTS idx_refresh_log_batch ON heart360tk_reporting.reporting_table_refresh_log (refresh_batch_id);

-- =======================================================================================
-- Function to refresh all reporting tables (formerly materialized views) and log the
-- refresh status and duration. Tables are truncated and repopulated from source views.
-- Generic approach: define list once, iterate through all tables.
-- =======================================================================================

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

            -- Dynamically truncate and populate the table
            EXECUTE format('TRUNCATE TABLE heart360tk_reporting.%I', v_table_name);
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

-- =======================================================================================
-- Single-row status table for the data refresh dashboard: tracks the most recent refresh attempt
-- and serves as the queue gate for manual triggers.
-- =======================================================================================
CREATE TABLE IF NOT EXISTS heart360tk_reporting.reporting_table_refresh_status (
    id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    status text NOT NULL DEFAULT 'idle',  -- idle | queued | in_progress | success | failed
    requested_at timestamptz,
    started_at timestamptz,
    finished_at timestamptz,
    last_error text,
    requested_by text,
    job_name text
);

INSERT INTO heart360tk_reporting.reporting_table_refresh_status (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

-- =======================================================================================
-- Status-aware refresh: acquires an advisory lock so manual and scheduled paths cannot
-- run concurrently, updates the status row, calls refresh_all_matviews(), and records
-- success / failure. Used by both the hourly pg_cron job and the manual one-shot.
-- =======================================================================================
CREATE OR REPLACE FUNCTION heart360tk_reporting.run_refresh_with_status(p_source text DEFAULT 'manual')
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_lock_key bigint := hashtext('heart360tk_reporting.matview_refresh');
    v_lock_acquired boolean;
    v_start_time timestamptz;
BEGIN

    IF current_setting('app.is_central_node', true) = 'true' THEN
        RETURN;
    END IF;

    SELECT pg_try_advisory_lock(v_lock_key) INTO v_lock_acquired;
    IF NOT v_lock_acquired THEN
        RAISE NOTICE 'Matview refresh already running (source=%); skipping.', p_source;
        RETURN;
    END IF;

    v_start_time := clock_timestamp();

    BEGIN
        PERFORM heart360tk_reporting.refresh_all_reporting_tables();
        UPDATE heart360tk_reporting.reporting_table_refresh_status
        SET status = 'success',
            started_at = v_start_time,
            finished_at = clock_timestamp(),
            last_error = NULL
        WHERE id = 1;
    EXCEPTION WHEN OTHERS THEN
        UPDATE heart360tk_reporting.reporting_table_refresh_status
        SET status = 'failed',
            started_at = v_start_time,
            finished_at = clock_timestamp(),
            last_error = SQLERRM
        WHERE id = 1;
    END;

    PERFORM pg_advisory_unlock(v_lock_key);
END;
$$;

-- =======================================================================================
-- Manual trigger: atomically claims the queue slot, schedules an ephemeral pg_cron job
-- that will fire at the next minute boundary, do the work via run_refresh_with_status,
-- and unschedule itself. Returns 'queued' on success or 'already_running' if another
-- refresh is queued or in progress.
-- =======================================================================================
CREATE OR REPLACE FUNCTION heart360tk_reporting.start_async_refresh(p_user text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_job_name text;
BEGIN
    UPDATE heart360tk_reporting.reporting_table_refresh_status
    SET status = 'queued',
        requested_at = now(),
        requested_by = p_user,
        last_error = NULL,
        finished_at = NULL
    WHERE id = 1
      AND status NOT IN ('queued', 'in_progress');

    IF NOT FOUND THEN
        RETURN 'already_running';
    END IF;

    v_job_name := 'mv_refresh_oneshot_' || extract(epoch from clock_timestamp())::bigint;

    UPDATE heart360tk_reporting.reporting_table_refresh_status
    SET job_name = v_job_name
    WHERE id = 1;

    PERFORM cron.schedule(
        v_job_name,
        '* * * * *',
        format($cmd$
            DO $body$
            BEGIN
                IF EXISTS (
                    SELECT 1 FROM heart360tk_reporting.reporting_table_refresh_status
                    WHERE id = 1 AND status = 'queued'
                ) THEN
                    UPDATE heart360tk_reporting.reporting_table_refresh_status
                    SET status = 'in_progress', started_at = clock_timestamp()
                    WHERE id = 1;
                    COMMIT;
                    PERFORM heart360tk_reporting.run_refresh_with_status('manual');
                END IF;
                IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = %L) THEN
                    PERFORM cron.unschedule(%L);
                END IF;
            END
            $body$;
        $cmd$, v_job_name, v_job_name)
    );

    RETURN 'queued';
END;
$$;

-- =======================================================================================
-- Watchdog: recovers the status row if a refresh gets stuck (e.g. the database was
-- restarted, or the process running the refresh was killed) while a normal completion
-- never had a chance to write 'success'/'failed'. Run every minute by pg_cron so the
-- admin dashboard button re-enables itself instead of staying stuck forever.
--   - 'in_progress' for > 30s with no advisory lock held  -> the worker died mid-refresh.
--   - 'in_progress' for > 30 minutes regardless           -> safety net for slow refreshes.
--   - 'queued' for > 3 minutes                            -> the one-shot cron job that
--     should have picked it up never ran (e.g. pg_cron/postgres restarted in between).
-- Also sweeps orphaned one-shot jobs that failed to unschedule themselves.
-- =======================================================================================
CREATE OR REPLACE FUNCTION heart360tk_reporting.reset_stale_refresh_status()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_lock_key bigint := hashtext('heart360tk_reporting.matview_refresh');
    v_lock_acquired boolean;
    v_row heart360tk_reporting.reporting_table_refresh_status%ROWTYPE;
    v_stale_job record;
BEGIN
    SELECT * INTO v_row FROM heart360tk_reporting.reporting_table_refresh_status WHERE id = 1;

    IF FOUND AND v_row.status = 'in_progress' THEN
        IF v_row.started_at IS NOT NULL AND v_row.started_at < clock_timestamp() - interval '30 minutes' THEN
            UPDATE heart360tk_reporting.reporting_table_refresh_status
            SET status = 'failed',
                finished_at = clock_timestamp(),
                last_error = 'Refresh timed out after 30 minutes and was automatically reset. Please try again.'
            WHERE id = 1 AND status = 'in_progress';
        ELSIF v_row.started_at IS NOT NULL AND v_row.started_at < clock_timestamp() - interval '30 seconds' THEN
            SELECT pg_try_advisory_lock(v_lock_key) INTO v_lock_acquired;
            IF v_lock_acquired THEN
                PERFORM pg_advisory_unlock(v_lock_key);
                UPDATE heart360tk_reporting.reporting_table_refresh_status
                SET status = 'failed',
                    finished_at = clock_timestamp(),
                    last_error = 'Refresh was interrupted (the cron job was killed, or the database connection/process was lost) and was automatically reset. Please try again.'
                WHERE id = 1 AND status = 'in_progress';
            END IF;
        END IF;
    ELSIF FOUND AND v_row.status = 'queued' THEN
        IF v_row.requested_at IS NOT NULL AND v_row.requested_at < clock_timestamp() - interval '3 minutes' THEN
            UPDATE heart360tk_reporting.reporting_table_refresh_status
            SET status = 'failed',
                finished_at = clock_timestamp(),
                last_error = 'Refresh request was never picked up by the scheduler (it may have restarted) and was automatically reset. Please try again.'
            WHERE id = 1 AND status = 'queued';

            IF v_row.job_name IS NOT NULL AND EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_row.job_name) THEN
                PERFORM cron.unschedule(v_row.job_name);
            END IF;
        END IF;
    END IF;

    -- Defensive sweep: unschedule any one-shot refresh jobs that somehow failed to
    -- unschedule themselves (e.g. the database restarted mid-run) so they don't pile up.
    FOR v_stale_job IN
        SELECT jobname FROM cron.job WHERE jobname LIKE 'mv_refresh_oneshot_%'
    LOOP
        BEGIN
            IF to_timestamp(split_part(v_stale_job.jobname, '_', 4)::bigint) < clock_timestamp() - interval '10 minutes' THEN
                PERFORM cron.unschedule(v_stale_job.jobname);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL; -- unexpected job name format; leave it alone rather than fail the watchdog
        END;
    END LOOP;
END;
$$;

GRANT SELECT ON heart360tk_reporting.reporting_table_refresh_status TO heart360tk;
GRANT EXECUTE ON FUNCTION heart360tk_reporting.start_async_refresh(text) TO heart360tk;
GRANT EXECUTE ON FUNCTION heart360tk_reporting.run_refresh_with_status(text) TO heart360tk;

-- Cached Grafana datasource: read-only access with reporting matviews first in
-- the role search_path (heart360tk_reporting, heart360tk_schema, public).
--
-- heart360tk_reporting: full SELECT so every matview is reachable.
GRANT USAGE ON SCHEMA heart360tk_reporting TO heart360tk_cached;
GRANT SELECT ON ALL TABLES IN SCHEMA heart360tk_reporting TO heart360tk_cached;
--
-- heart360tk_schema: SELECT only on the helper tables/views that dashboard
-- panel queries (and the SQL-stable functions they call) actually touch.
-- Raw encounter/BP/BS tables are NOT exposed — panels read from matviews.
GRANT USAGE ON SCHEMA heart360tk_schema TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.org_units        TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.hierarchy_config TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.org_unit_lineage TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.patients         TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.patient_diagnoses TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.patient_diagnoses TO heart360tk;
--
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_descendant_ids(integer)        TO heart360tk_cached;
GRANT EXECUTE ON FUNCTION heart360tk_schema.build_drill_url(integer)           TO heart360tk_cached;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_child_level_name(integer)      TO heart360tk_cached;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_ancestor_name(integer, integer) TO heart360tk_cached;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_breadcrumb_path(integer)       TO heart360tk_cached;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_access_groups(integer, varchar) TO heart360tk_cached;

-- Grafana datasource user needs to call start_async_refresh as part of an admin-check
-- query that joins against the grafana user/team tables (which only the grafana role
-- can read). USAGE on the schema + EXECUTE on the function is enough; no data tables
-- are exposed.
GRANT USAGE ON SCHEMA heart360tk_reporting TO grafana;
GRANT EXECUTE ON FUNCTION heart360tk_reporting.start_async_refresh(text) TO grafana;

-- Grants for grafana to perform hierarchy checks directly
GRANT USAGE ON SCHEMA heart360tk_schema TO grafana;
GRANT SELECT ON heart360tk_schema.org_units TO grafana;
GRANT SELECT ON heart360tk_schema.hierarchy_config TO grafana;
GRANT SELECT ON heart360tk_schema.org_unit_lineage TO grafana;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_access_groups(integer, varchar) TO grafana;
GRANT EXECUTE ON FUNCTION heart360tk_schema.get_user_visible_org_units(integer) TO grafana;

-- ============================================================================
-- pg_cron: Schedule the refresh of all reporting tables every hour
-- ============================================================================
SELECT cron.schedule('refresh_reporting_tables_every_hour', '0 * * * *', 'SELECT heart360tk_reporting.run_refresh_with_status(''cron'');');

-- ============================================================================
-- pg_cron: Watchdog that recovers a stuck refresh status every minute
-- ============================================================================
SELECT cron.schedule('reset_stale_refresh_status_watchdog', '* * * * *', 'SELECT heart360tk_reporting.reset_stale_refresh_status();');


-- ============================================================================
-- TRIGGER: Update patient status when call_results indicates death
-- ============================================================================
CREATE OR REPLACE FUNCTION update_patient_status_on_death()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF LOWER(TRIM(COALESCE(NEW.result_type, ''))) = 'removed_from_overdue_list'
        AND LOWER(TRIM(COALESCE(NEW.removed_reason, ''))) = 'died' THEN
        UPDATE patients
        SET patient_status = 'DEAD',
            death_date = COALESCE(death_date, NEW.call_date)
        WHERE patient_id = NEW.patient_id
          AND patient_status = 'ALIVE';
        RAISE NOTICE 'Patient % marked as DEAD', NEW.patient_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_patient_status_on_death ON reminder_calls;
DROP TRIGGER IF EXISTS trigger_update_patient_status_on_death ON call_results;

CREATE TRIGGER trigger_update_patient_status_on_death
    AFTER INSERT OR UPDATE ON call_results
    FOR EACH ROW
    EXECUTE FUNCTION update_patient_status_on_death();

-- Drop deprecated tables
DROP TABLE IF EXISTS reminder_calls CASCADE;
DROP TABLE IF EXISTS facilities CASCADE;


-- ============================================================================
-- ADMIN PROCEDURE: H360TK_ADMIN_CLEAN_DATA
-- Clears all patient and organizational data for a fresh start.
-- Usage:  CALL heart360tk_schema.H360TK_ADMIN_CLEAN_DATA();
-- ============================================================================
CREATE OR REPLACE PROCEDURE H360TK_ADMIN_CLEAN_DATA()
LANGUAGE plpgsql AS $$
BEGIN
    SET search_path TO heart360tk_schema;

    TRUNCATE TABLE
        blood_pressures,
        blood_sugars,
        scheduled_visits,
        call_results,
        encounters,
        patients,
        org_units
    CASCADE;

    ALTER SEQUENCE org_units_id_seq RESTART WITH 1;
    ALTER SEQUENCE encounters_id_seq RESTART WITH 1;
    ALTER SEQUENCE blood_pressures_id_seq RESTART WITH 1;
    ALTER SEQUENCE blood_sugars_id_seq RESTART WITH 1;
    ALTER SEQUENCE scheduled_visits_scheduled_id_seq RESTART WITH 1;
    ALTER SEQUENCE call_results_call_id_seq RESTART WITH 1;

    RAISE NOTICE 'All data cleared and sequences reset.';
END;
$$;

GRANT SELECT ON heart360tk_schema.HEART360_DM_PATIENTS_CATAGORY TO heart360tk_cached;
GRANT SELECT ON heart360tk_schema.HEART360_DM_PATIENTS_CATAGORY TO heart360tk;

\ir migrations/0.5.1_to_0.5.2.sql
\ir migrations/0.5.2_to_0.5.3.sql
\ir migrations/0.5.3_to_0.5.4.sql
\ir migrations/0.5.4_to_0.5.5.sql
