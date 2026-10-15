---
name: HEARTS360 central direct aggregate JSON ingest
type: architecture-spine
status: draft-for-implementation
created: 2026-10-14
updated: 2026-10-14
---

# Architecture spine: direct aggregate indicator ingest

## 1) Current baseline

- Exporter emits ZIP with CSV files + `metadata.json`.
- Importer fetches ZIP from SFTP, validates, then imports into `heart360tk_reporting`.
- Org-unit association today depends on imported `orgunit.csv` and `import_facility_mapping`.

The new requirement adds a second ingestion path for external EHR aggregate data.

## 2) Design options considered

### Option A. JSON over API post

Pros.

- Fast vendor adoption.
- Immediate validation response.
- No file transport setup required.

Cons.

- Requires endpoint auth and API lifecycle support.

### Option B. JSON file drop on SFTP inbox

Pros.

- Reuses existing SFTP operations.

Cons.

- Slow error feedback.
- Harder idempotency and observability.

### Option C. Full FHIR Bundle ingestion

Pros.

- Strong standards alignment.

Cons.

- Heavy for MVP.
- Higher implementation and partner complexity.

### Decision

Choose Option A for MVP. Keep schema FHIR-inspired but compact. Option B can be added later as an adapter that writes into the same staging table.

## 3) Architecture decisions

1. Keep ZIP importer unchanged.
2. Add parallel direct-ingest pipeline for aggregate JSON.
3. Normalize accepted rows into one monthly indicator fact table.
4. Use row-level partial acceptance with explicit reject table.
5. Resolve org units by ID first, then mapping table fallback.
6. Enforce idempotent upsert key at row grain.
7. Keep source payload reference for traceability.

## 4) Proposed data model in `heart360tk_reporting`

### 4.1 Submission log

`aggregate_ingest_submission`

- `id` bigserial pk
- `source_system` text
- `submission_identifier` text
- `period_start` date
- `period_end` date
- `status` text
- `accepted_rows` integer
- `rejected_rows` integer
- `received_at` timestamptz
- `processed_at` timestamptz
- `payload_json` jsonb

Unique index on `(source_system, submission_identifier)`.

### 4.2 Accepted fact rows

`aggregate_indicator_fact`

- `id` bigserial pk
- `source_system` text
- `submission_identifier` text
- `reporting_month` date
- `org_unit_id` integer not null
- `indicator_code` text not null
- `indicator_value` numeric not null
- `reported_at` timestamptz null
- `ingested_at` timestamptz not null default now()

Unique index on:

`(source_system, submission_identifier, reporting_month, org_unit_id, indicator_code)`

### 4.3 Rejection rows

`aggregate_ingest_rejection`

- `id` bigserial pk
- `submission_id` bigint fk
- `entry_path` text
- `reason_code` text
- `reason_detail` text
- `raw_fragment` jsonb
- `created_at` timestamptz default now()

### 4.4 Org-unit mapping

`external_org_unit_map`

- `source_system` text
- `external_org_unit_code` text
- `central_org_unit_id` integer fk
- `is_active` boolean
- `updated_at` timestamptz

Unique index on `(source_system, external_org_unit_code)`.

## 5) Ingestion flow

```text
Vendor JSON POST
  -> parse + envelope validation
  -> per-entry normalization
  -> org-unit resolution
  -> per-indicator validation
  -> upsert accepted rows
  -> write rejection rows
  -> submission status summary
```

## 6) Indicator model

Core indicator registry for MVP.

- `bp_controlled`
- `bp_uncontrolled`
- `missed_visit`

Optional indicator rows are allowed and stored when valid. Dashboard queries initially filter to the core three codes.

## 7) Validation and fallback strategy

Boundary validation.

- Reject malformed payload early.
- Enforce monthly period.
- Enforce non-negative numeric values.

Row fallback.

- Org-unit resolution order.
  1. `orgUnit.id`
  2. `external_org_unit_map` by `orgUnit.code`
  3. display-name match fallback
- Indicator alias map normalizes known synonyms.
- Unknown optional indicators pass with raw code preserved.

## 8) Reporting contract for downstream dashboards

Create a view for core KPIs.

`v_external_aggregate_kpi_monthly`

Columns.

- `reporting_month`
- `org_unit_id`
- `bp_controlled`
- `bp_uncontrolled`
- `missed_visit`
- `source_system`
- `last_ingested_at`

This view is the first dashboard entry point and can later join hierarchy views for tree filtering.

## 9) Rollout sequence

1. Create tables and indexes.
2. Implement parser and validator.
3. Implement org-unit mapping resolver.
4. Implement upsert + rejection writes.
5. Add admin query surfaces for submission and rejection logs.
6. Pilot with one vendor and one month.
