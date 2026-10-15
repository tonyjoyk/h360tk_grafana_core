---
title: HEARTS360 central direct aggregate JSON ingest (MVP)
status: draft-for-implementation
created: 2026-10-14
updated: 2026-10-14
---

# PRD addendum: direct aggregate ingest for external EHRs

## 1) Why this feature now

The current central path only accepts leaf Toolkit ZIP exports with CSV + `orgunit.csv`. External EHR partners need a lighter way to submit aggregate indicators without standing up the full exporter package.

This addendum adds a second ingest mode for central nodes.

- Existing mode stays. ZIP import remains supported.
- New mode adds JSON submit for external systems.
- MVP stays narrow. It focuses on three hypertension indicators.

## 2) MVP outcome

External EHRs can send monthly aggregate counts by org unit using one simple JSON payload. Central ingest stores the data in `heart360tk_reporting` with enough provenance to troubleshoot and reprocess.

MVP top indicators:

1. `bp_controlled`
2. `bp_uncontrolled`
3. `missed_visit`

Optional indicator blocks are allowed in the payload and stored when valid, but dashboards and acceptance focus on the three indicators above.

## 3) Users and jobs

- **Vendor integrator.** Submit aggregate data without ZIP packaging or CSV layout coupling.
- **Central admin.** Confirm which payloads were accepted, which rows failed, and why.
- **Reporting consumer.** Query normalized monthly counts by org unit and indicator.

## 4) In scope

- One JSON ingest contract for central nodes.
- Minimal auth model for MVP.
- Idempotent upsert by source + submission key + period + org unit + indicator.
- Org-unit association using central ID or source mapping rules.
- Validation outcomes with row-level rejection reasons.
- Tables and views in `heart360tk_reporting` for accepted values and ingest run logs.
- Vendor checklist and sample payload for handoff.

## 5) Out of scope for MVP

- Full FHIR Bundle processing.
- Patient-level resources.
- Real-time streaming.
- Automated vendor onboarding portal.
- Master-data synchronization UI for org-unit mapping.
- Backfill orchestration UI.

## 6) Functional requirements

### FR-A1. Accept simple JSON payloads

Central ingest accepts a JSON payload with:

- source identity
- reporting period
- one or more org-unit entries
- indicator value list per org unit

### FR-A2. Support the three core indicators

The contract must support `bp_controlled`, `bp_uncontrolled`, and `missed_visit` as first-class codes.

### FR-A3. Allow optional building blocks

Payload may include optional metadata and extra indicators. Unknown extras do not fail the entire submission when core data is valid.

### FR-A4. Associate every accepted value to a central org unit

Each accepted indicator row maps to one central org unit ID. Unresolved org units are rejected at row level with explicit reason codes.

### FR-A5. Idempotent writes

Resubmitting the same logical row replaces prior value, not duplicate it.

### FR-A6. Validation with partial acceptance

Submission can be partially accepted. Invalid rows are quarantined with reasons while valid rows commit.

### FR-A7. Admin visibility

Central admins can inspect:

- submission status
- accepted row count
- rejected row count
- rejection reasons
- raw payload reference

## 7) Non-functional requirements

- Keep contract simple enough to implement from common EHR middleware in under one sprint.
- Keep processing deterministic and replay-safe.
- Keep schema extensible for additional aggregate indicators later.
- Keep validation errors vendor-actionable.

## 8) Success criteria

- At least one external vendor submits valid payloads without ZIP tooling.
- Three indicator values appear in reporting tables for at least one month across multiple org units.
- Central admin can diagnose a failed payload without reading application code.

## 9) Open questions

1. Which transport is primary for MVP. Direct API post, inbox file drop, or both.
2. Which auth primitive is approved first. Static token, mTLS, or gateway JWT.
3. Which org-unit identifier is mandatory for first partner. Central numeric ID, source code mapping, or both.
4. Whether `missed_visit` semantics are fixed globally or tagged by source definition metadata.
