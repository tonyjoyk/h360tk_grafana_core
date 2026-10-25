BEGIN;

SET ROLE heart360tk;

SET search_path TO heart360tk_reporting, heart360tk_schema;

CREATE TABLE IF NOT EXISTS external_org_unit_mapping (
    source_key text NOT NULL,
    external_code text NOT NULL,
    central_org_unit_id integer NOT NULL REFERENCES heart360tk_schema.org_units(id),
    external_display_name text,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_key, external_code)
);

CREATE INDEX IF NOT EXISTS idx_external_org_unit_mapping_central
    ON external_org_unit_mapping (central_org_unit_id);

CREATE TABLE IF NOT EXISTS external_aggregate_submission_log (
    id serial PRIMARY KEY,
    source_key text NOT NULL,
    submission_id text NOT NULL,
    period_start date NOT NULL,
    period_end date,
    accepted_entries integer NOT NULL DEFAULT 0,
    rejected_entries integer NOT NULL DEFAULT 0,
    ingested_at timestamptz NOT NULL DEFAULT now(),
    raw_filename text,
    UNIQUE (source_key, submission_id, period_start)
);

CREATE INDEX IF NOT EXISTS idx_external_aggregate_submission_log_ingested
    ON external_aggregate_submission_log (ingested_at DESC);

CREATE TABLE IF NOT EXISTS external_aggregate_rejection_log (
    id serial PRIMARY KEY,
    source_key text NOT NULL,
    submission_id text NOT NULL,
    period_start date NOT NULL,
    entry_index integer NOT NULL,
    reason text NOT NULL,
    org_unit_payload jsonb,
    entry_payload jsonb NOT NULL,
    rejected_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_external_aggregate_rejection_log_rejected
    ON external_aggregate_rejection_log (rejected_at DESC);

GRANT SELECT, INSERT, UPDATE ON external_org_unit_mapping TO heart360tk;
GRANT SELECT, INSERT, UPDATE ON external_aggregate_submission_log TO heart360tk;
GRANT SELECT, INSERT ON external_aggregate_rejection_log TO heart360tk;

GRANT USAGE ON SEQUENCE external_aggregate_submission_log_id_seq TO heart360tk;
GRANT USAGE ON SEQUENCE external_aggregate_rejection_log_id_seq TO heart360tk;

COMMIT;
