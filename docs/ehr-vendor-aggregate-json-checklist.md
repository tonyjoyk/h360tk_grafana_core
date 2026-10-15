# EHR Vendor Checklist: Aggregate Indicator JSON (MVP)

Use this checklist when onboarding any EHR to send aggregate indicator data directly to the central node.

## 1) File and frequency

- [ ] Send a JSON file whenever the counts change. Each entry is the full picture for one calendar month.
- [ ] Use UTF-8 encoded `.json`.
- [ ] Ensure `resourceType` is `AggregateIndicatorSubmission`.

## 2) Source identity

- [ ] Set a stable `reporter.identifier.value` (vendor/system key).
- [ ] Set an `identifier.value` for the file, and reuse it when you correct that file.

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
- [ ] `nb_patients_controlled`
- [ ] `nb_patients_uncontrolled`
- [ ] `nb_patients_no_visit`
- [ ] `nb_patients_visit_no_bp`
- [ ] `heart360_patients_category.nb_patients_lost_to_follow_up`
- [ ] `heart360_patients_category.total_number_of_patients`
- [ ] `nb_patients_newly_registered`
- [ ] `nb_patients_under_care`
- [ ] `nb_new_patients`

Diabetes codes you can send:
- [ ] `diabetes_controlled`
- [ ] `uncontrolled_moderate`
- [ ] `uncontrolled_high`
- [ ] `missed_visit`
- [ ] `nb_dm_patients_under_care`
- [ ] `nb_new_dm_patients`
- [ ] `heart360_dm_patients_catagory.total_number_of_patients`
- [ ] `heart360_dm_patients_catagory.nb_patients_lost_to_follow_up`
- [ ] `bp_controlled_140_90`
- [ ] `bp_controlled_130_80`

Rules:
- [ ] Values must be non-negative integers.
- [ ] Unknown indicator codes are ignored.

## 6) Quality checks before sending

- [ ] `nb_patients_controlled`, `nb_patients_uncontrolled`, and `nb_patients_no_visit` are counts, and they do not have to add up to 100.
- [ ] Patients who visited with no blood pressure recorded are sent as `nb_patients_visit_no_bp`. Send zero only when the real count is zero.
- [ ] No duplicate org unit entries for the same period unless intentionally split.
- [ ] A test file has been validated in a non-production environment.

## 7) Operational readiness

- [ ] Vendor knows rejection reasons are logged per entry.
- [ ] Vendor has a retry process for corrected files.
- [ ] A named contact exists for mapping or semantic mismatches.
