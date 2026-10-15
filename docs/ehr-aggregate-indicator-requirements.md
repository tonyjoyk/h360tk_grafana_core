# Send your indicator counts to the national dashboard

You already calculate the HEARTS indicators in your EHR. This note says what to send so those same numbers can appear on the national dashboard.

You send counts. You do not send percentages. The national dashboard calculates the percentages from the counts you send.

You can send as many, or as few, of the counts below as you already have. A missing count stays blank. It is not treated as zero.

The technical file shape is in [EHR aggregate JSON ingest](ehr-aggregate-json-ingest-mvp.md).

## The problem we are solving

A facility EHR and the national dashboard should show the same hypertension and diabetes results. Today many EHRs already have those results. They should not have to send a patient line list.

Send a JSON file whenever the numbers change. Put it where the central importer already collects files. The file names the facility and the counts. `period.start` chooses the calendar month. A later file for that facility and month replaces the counts it includes.

## What you send

Send whole numbers of patients.

For the percentage charts to appear, also send the counts that chart divides by. If you send only the numerator, the count still appears and the percentage stays blank.

The codes are the same names the dashboard columns already use. Two columns exist on both the hypertension table and the diabetes table, so those codes include the table name.

The three hypertension percentages do not need to add up to 100. A patient can visit and have no blood pressure recorded. Send that as its own count, `nb_patients_visit_no_bp`. The dashboard shows it as the gap.

## Hypertension counts

Send any of these.

| Code | What it means |
| --- | --- |
| `nb_patients_controlled` | Patients with controlled blood pressure at the latest visit in the past 3 months |
| `nb_patients_uncontrolled` | Patients with uncontrolled blood pressure at the latest visit in the past 3 months |
| `nb_patients_no_visit` | Patients under care with no visit in the past 3 months |
| `nb_patients_visit_no_bp` | Patients who visited in the past 3 months, but no blood pressure was recorded |
| `heart360_patients_category.nb_patients_lost_to_follow_up` | Patients with no visit in the past 12 months |
| `heart360_patients_category.total_number_of_patients` | All living patients registered with hypertension |
| `nb_patients_newly_registered` | Patients registered in the last 3 months |
| `nb_patients_under_care` | Registered patients with a visit in the past 12 months |
| `nb_new_patients` | Patients registered during that month |

The controlled, uncontrolled, and no-visit percentages use this denominator:

`heart360_patients_category.total_number_of_patients - nb_patients_newly_registered - heart360_patients_category.nb_patients_lost_to_follow_up`

Send those three counts when you want those percentages to match the dashboard.

`nb_new_patients` is the patients registered in that one month. `nb_patients_newly_registered` is the patients still inside their first 3 months. The registrations chart uses `nb_new_patients` for each month. Send one entry per month if you want the month-on-month line.

## Diabetes counts

Send any of these.

| Code | What it means |
| --- | --- |
| `diabetes_controlled` | Patients with controlled blood sugar at the latest visit in the past 3 months |
| `uncontrolled_moderate` | Uncontrolled blood sugar in the moderate band |
| `uncontrolled_high` | Uncontrolled blood sugar in the high band |
| `missed_visit` | Diabetes patients under care with no blood sugar recorded in the past 3 months |
| `nb_dm_patients_under_care` | Diabetes patients with a visit in the past 12 months |
| `nb_new_dm_patients` | Diabetes patients registered during that month |
| `heart360_dm_patients_catagory.total_number_of_patients` | All living patients registered with diabetes |
| `heart360_dm_patients_catagory.nb_patients_lost_to_follow_up` | Diabetes patients with no visit in the past 12 months |
| `bp_controlled_140_90` | Diabetes patients with blood pressure below 140/90, excluding those below 130/80 |
| `bp_controlled_130_80` | Diabetes patients with blood pressure below 130/80 |

Blood sugar percentages use `nb_dm_patients_under_care` as the denominator. The importer copies that count onto the blood sugar tables and the diabetes blood-pressure table. Those percentages do not need to add up to 100. A patient can be under care and still sit outside controlled, uncontrolled, and missed visit.

The blood pressure chart for diabetes patients adds `bp_controlled_140_90` and `bp_controlled_130_80` for the below-140/90 result.

You can leave either blood pressure count out. The chart shows the count you sent.

## Two ways to participate

Some EHRs already have the result counts. Send `nb_patients_controlled`, `nb_patients_uncontrolled`, `nb_patients_no_visit`, and `heart360_patients_category.nb_patients_lost_to_follow_up`.

Some EHRs have the building blocks instead. Send `nb_patients_under_care`, `heart360_patients_category.total_number_of_patients`, `nb_patients_newly_registered`, and `nb_new_patients`.

Send both when you have both. The dashboard uses each count in the chart that already reads it.

## What the file must contain

Each file is one JSON object.

- `resourceType` is `AggregateIndicatorSubmission`.
- `identifier.value` is your id for this file. Use the same id again when you send a correction.
- `reporter.identifier.value` is your EHR name. Keep it stable.
- `period.start` chooses the calendar month. `period.end` is recorded with the submission.
- `entries` is the list of facilities.

Each entry has an `orgUnit` and a list of `indicators`. Each indicator has a `code` and a `value`.

To send several months in one file, put `period` on the entry. That entry then uses its own month.

Name the facility in the first way that you can.

1. `orgUnit.id` is the national org unit id.
2. `orgUnit.code` is your own stable facility code, after it has been mapped once.
3. `orgUnit.display` is the facility name, and it must match one national org unit.

A facility that cannot be matched is skipped. The other facilities in the file are still saved.

## Corrections

Replace the file and send it again with the same `identifier.value`. The new counts replace the old counts for that facility and month. They are not added on top.

## Checklist

- Send the file whenever the numbers change. Each entry is the full picture for one calendar month.
- Save the file as UTF-8 and end the name with `.json`.
- Set `resourceType` to `AggregateIndicatorSubmission`.
- Use a stable `reporter.identifier.value`.
- Use one `identifier.value` per file, and reuse it when you correct that file.
- Put `period.start` and `period.end` on the file, or on each entry when the file covers more than one month.
- Send counts, not percentages.
- Use a code from the tables above. Any other code is skipped.
- Send only numbers that are zero or greater.
- Prefer `orgUnit.id`. Otherwise send `orgUnit.code` or a unique `orgUnit.display`.
- Leave out a count you do not have. Do not send zero unless the real count is zero.
- If controlled, uncontrolled, and no visit do not add up to the denominator, send `nb_patients_visit_no_bp` for the patients who visited without a blood pressure.
- Keep every month you want on the dashboard inside the import folder. The next import reads the files that are still there.
- Check the rejection log when a facility is missing from the dashboard.

## Example

A short example is `test_data/aggregate_scenarios/visit_without_bp.json`. It is the case where the three percentages add up to 90 because 10 patients visited with no blood pressure recorded.

More examples, including diabetes and a three-month registration series, are in `test_data/aggregate_scenarios/`.
