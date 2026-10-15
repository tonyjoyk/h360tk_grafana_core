# EHR Vendor Checklist: Aggregate Indicator JSON (MVP)

Use this checklist when onboarding any EHR to send aggregate indicator data directly to the central node.

## 1) File and frequency

- [ ] Send one JSON file per reporting month.
- [ ] Use UTF-8 encoded `.json`.
- [ ] Ensure `resourceType` is `AggregateIndicatorSubmission`.

## 2) Source identity

- [ ] Set a stable `reporter.identifier.value` (vendor/system key).
- [ ] Set a unique monthly submission `identifier.value`.

## 3) Reporting period

- [ ] Provide `period.start` and `period.end` in ISO date format (`YYYY-MM-DD`).
- [ ] Ensure all entries in the file refer to that same period.

## 4) Org unit mapping

Preferred:
- [ ] Provide central `orgUnit.id`.

If central ID is not available:
- [ ] Provide stable `orgUnit.code` for mapping.
- [ ] Provide `orgUnit.display` (and optional `orgUnit.level`) for fallback matching.

## 5) Indicator payload

Required codes:
- [ ] `bp_controlled`
- [ ] `bp_uncontrolled`
- [ ] `missed_visit`

Rules:
- [ ] Values must be non-negative integers.
- [ ] Unknown indicator codes are allowed but ignored in MVP.

Optional:
- [ ] `extensions.denominator_under_care`
- [ ] `extensions.newly_registered`
- [ ] `extensions.lost_to_follow_up`

## 6) Quality checks before sending

- [ ] `bp_controlled + bp_uncontrolled + missed_visit` is internally consistent.
- [ ] No duplicate org unit entries for the same period unless intentionally split.
- [ ] A test file has been validated in a non-production environment.

## 7) Operational readiness

- [ ] Vendor knows rejection reasons are logged per entry.
- [ ] Vendor has a retry process for corrected files.
- [ ] A named contact exists for mapping or semantic mismatches.
