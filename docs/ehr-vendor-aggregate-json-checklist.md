# EHR vendor checklist: aggregate indicator JSON

Use this checklist when an EHR sends aggregate indicator counts to the central node.

The full text is in [Send your indicator counts to the national dashboard](ehr-aggregate-indicator-requirements.md).

## 1) File and frequency

- [ ] Send a JSON file when the counts change. Each entry has all counts for one calendar month.
- [ ] Save the file as UTF-8. End the file name with `.json`.
- [ ] Set `resourceType` to `AggregateIndicatorSubmission`.

## 2) Source identity

- [ ] Set `reporter.identifier.value` to the EHR name. Do not change this name.
- [ ] Set `identifier.value` for the file. Use the same value when you correct that file.

## 3) Reporting period

- [ ] Write `period.start` and `period.end` as `YYYY-MM-DD`.
- [ ] Put the period on the file when the file has one month. Put the period on each entry when the file has more than one month.

## 4) Facility

Use the first item that you can:

- [ ] Send the central `orgUnit.id`.
- [ ] If you do not have the id, send a stable `orgUnit.code` after it is mapped.
- [ ] If you do not have a mapped code, send `orgUnit.display`. The name must match one national org unit. You can also send `orgUnit.level`.

## 5) Counts

Send the counts that you have.

Hypertension:

- [ ] `nb_patients_controlled`
- [ ] `nb_patients_uncontrolled`
- [ ] `nb_patients_no_visit`
- [ ] `nb_patients_visit_no_bp`
- [ ] `heart360_patients_category.nb_patients_lost_to_follow_up`
- [ ] `heart360_patients_category.total_number_of_patients`
- [ ] `nb_patients_newly_registered`
- [ ] `nb_patients_under_care`
- [ ] `nb_new_patients`

Diabetes:

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

- [ ] Each value is a whole number. The number is zero or greater.
- [ ] The importer ignores an unknown code.

## 6) Checks before you send

- [ ] `nb_patients_controlled`, `nb_patients_uncontrolled`, and `nb_patients_no_visit` are counts. They do not have to add up to 100.
- [ ] Send patients who had a visit with no blood pressure as `nb_patients_visit_no_bp`. Send zero only when the real count is zero.
- [ ] Do not repeat the same facility and the same month in one file, unless you want the importer to add those counts.
- [ ] Test the file in an environment that is not production.

## 7) Operations

- [ ] The vendor can read the rejection reason for each entry.
- [ ] The vendor can send a corrected file.
- [ ] Name one contact for facility mapping and for count questions.
