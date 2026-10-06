-- Existing 0.5.0 databases. Fresh installs take the view from 01_heart360_tables.sql.
-- Safe to re-run. The reporting table keeps its four columns.

BEGIN;

SET ROLE heart360tk;
SET search_path TO heart360tk_schema;

\ir ../sql/cohort_q1_view.sql

TRUNCATE heart360tk_reporting.heart360_cohort_patient_details;
INSERT INTO heart360tk_reporting.heart360_cohort_patient_details
SELECT * FROM heart360tk_schema.heart360_cohort_patient_details;

ALTER TABLE heart360tk_reporting.heart360_cohort_patient_details
    DROP CONSTRAINT IF EXISTS cohort_patient_details_outcome_chk;
ALTER TABLE heart360tk_reporting.heart360_cohort_patient_details
    ADD CONSTRAINT cohort_patient_details_outcome_chk
    CHECK (status_at_end_of_interval IN ('controlled', 'uncontrolled', 'missed_visit', 'visited_no_bp'));

COMMIT;
