# Epics and implementation checklist: central direct aggregate JSON ingest

## Epic 1. Ingest foundation and data contract

Goal. Accept FHIR-inspired aggregate JSON and persist valid rows with idempotency.

Stories.

- [x] E1-S1 Define JSON schema and indicator code registry.
- [x] E1-S2 Build envelope validator and row validator.
- [x] E1-S3 Implement org-unit resolution chain (`id`, code map, display fallback).
- [x] E1-S4 Implement accepted fact upsert and submission summary status.
- [x] E1-S5 Implement rejection table writes with stable reason codes.

Exit criteria.

- [ ] Submission can be `accepted`, `partially_accepted`, or `rejected`.
- [ ] Replay of same submission does not create duplicates.
- [ ] Core indicators persist for at least one month in test data.

## Epic 2. Admin observability and operations

Goal. Let central admins diagnose and recover from vendor data issues quickly.

Stories.

- [ ] E2-S1 Add SQL views for submission log and rejection diagnostics.
- [ ] E2-S2 Add runbook for row-level correction and vendor resend flow.
- [ ] E2-S3 Add alert condition for repeated `rejected` submissions per source.
- [ ] E2-S4 Add minimal audit query for changed values across resubmissions.

Exit criteria.

- [ ] Admin can identify why a row failed without application logs.
- [ ] Admin can verify corrected resend updated final values.

## Epic 3. Vendor onboarding and pilot rollout

Goal. Make first external EHR integration repeatable.

Stories.

- [x] E3-S1 Publish vendor checklist and sample payload.
- [ ] E3-S2 Complete org-unit mapping for pilot partner.
- [ ] E3-S3 Run dry-run month payload and resolve validation errors.
- [ ] E3-S4 Run signed-off month payload and confirm dashboard-ready data.
- [ ] E3-S5 Capture partner lessons and freeze v1.0 contract notes.

Exit criteria.

- [ ] One partner successfully submits monthly payloads for the 3 core indicators.
- [ ] Central admin confirms data confidence for pilot scope.

## Epic 4. Optional extensions after MVP

Goal. Expand without destabilizing the MVP path.

Stories.

- [ ] E4-S1 Add optional SFTP JSON adapter that writes to same tables.
- [ ] E4-S2 Add optional indicator registry table and activation flags.
- [ ] E4-S3 Add mapping maintenance UI or import utility.
- [ ] E4-S4 Add versioned schema negotiation for partner compatibility.

Exit criteria.

- [ ] Extensions do not alter MVP payload acceptance behavior for core indicators.

## Rollout risk checklist

- [ ] Auth and endpoint protections approved.
- [ ] Org-unit mapping ownership assigned.
- [ ] `missed_visit` definition aligned with partner and documented.
- [ ] Backfill policy decided.
- [ ] Reprocessing procedure tested on a non-prod environment.
