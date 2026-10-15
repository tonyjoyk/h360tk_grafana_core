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
- [ ] Put the period on the file for one month, or on each entry when the file covers more than one month.

## 4) Org unit mapping

Preferred:
- [ ] Provide central `orgUnit.id`.

If central ID is not available:
- [ ] Provide stable `orgUnit.code` for mapping.
- [ ] Provide `orgUnit.display` (and optional `orgUnit.level`) for fallback matching.

## 5) Indicator payload

Send the counts you have. The full list is in [Send your indicator counts to the national dashboard](ehr-aggregate-indicator-requirements.md).

Hypertension codes you can send:
- [ ] `bp_controlled`
- [ ] `bp_uncontrolled`
- [ ] `missed_visit`
- [ ] `visit_no_bp`
- [ ] `lost_to_follow_up`
- [ ] `total_registered`
- [ ] `newly_registered`
- [ ] `patients_under_care`
- [ ] `new_registrations`

Diabetes codes you can send:
- [ ] `bs_controlled`
- [ ] `bs_uncontrolled_moderate`
- [ ] `bs_uncontrolled_high`
- [ ] `bs_missed_visit`
- [ ] `dm_patients_under_care`
- [ ] `dm_new_registrations`
- [ ] `dm_total_registered`
- [ ] `dm_lost_to_follow_up`
- [ ] `dm_bp_controlled`
- [ ] `dm_bp_controlled_130_80`

Rules:
- [ ] Values must be non-negative integers.
- [ ] Unknown indicator codes are allowed but ignored in MVP.

Optional:
- [ ] `extensions.denominator_under_care`
- [ ] `extensions.newly_registered`
- [ ] `extensions.lost_to_follow_up`

## 6) Quality checks before sending

- [ ] `bp_controlled`, `bp_uncontrolled`, and `missed_visit` are counts, not percentages, and they do not have to add up to 100.
- [ ] Patients who visited with no blood pressure recorded are sent as `visit_no_bp`, not as zero.
- [ ] No duplicate org unit entries for the same period unless intentionally split.
- [ ] A test file has been validated in a non-production environment.

## 7) Operational readiness

- [ ] Vendor knows rejection reasons are logged per entry.
- [ ] Vendor has a retry process for corrected files.
- [ ] A named contact exists for mapping or semantic mismatches.
