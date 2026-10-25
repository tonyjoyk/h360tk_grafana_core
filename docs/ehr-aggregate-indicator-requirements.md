# Send your indicator counts to the national dashboard

Your EHR already calculates the HEARTS indicators. This document tells you which counts to send. The national dashboard then shows the same numbers.

Send counts. Do not send percentages. The national dashboard calculates each percentage from the counts.

Send only the counts that you have. If you do not send a count, the dashboard leaves that count blank. The dashboard does not use zero for a missing count.

The file shape is in [EHR aggregate JSON ingest](ehr-aggregate-json-ingest-mvp.md).

The investigation report for the spike is [Ingesting aggregate data into the national dashboard](central-aggregate-ingest-investigation.md).

The comparison of the ZIP, one Master CSV, and JSON is [Compare three ways to send aggregate counts](compare-aggregate-ingest-approaches.md).

Colleagues who build or review this feature use [Files, branch, and repo](#files-branch-and-repo).

## The problem

The facility EHR and the national dashboard must show the same hypertension results and the same diabetes results. Many EHRs already have these results. Do not send a patient line list.

Send a JSON file when your counts change. Put the file in the folder that the central importer already reads. The file gives the facility and the counts. `period.start` selects the calendar month. A later file for the same facility and the same month replaces the counts in that file.

## What you send

Send whole numbers of patients.

Also send the counts that a percentage chart divides by. If you send only the top number, the dashboard shows that count. The percentage stays blank.

Use the same names as the dashboard columns. Two column names exist on the hypertension table and on the diabetes table. For those two names, put the table name in the code.

The three hypertension percentages do not have to add up to 100. A patient can visit, and the visit can have no blood pressure. Send that count as `nb_patients_visit_no_bp`. The dashboard shows this count as the difference.

## Hypertension counts

Send any of these counts.

| Code | Meaning |
| --- | --- |
| `nb_patients_controlled` | Patients with controlled blood pressure at the latest visit in the past 3 months |
| `nb_patients_uncontrolled` | Patients with uncontrolled blood pressure at the latest visit in the past 3 months |
| `nb_patients_no_visit` | Patients under care with no visit in the past 3 months |
| `nb_patients_visit_no_bp` | Patients who had a visit in the past 3 months, and that visit has no blood pressure |
| `heart360_patients_category.nb_patients_lost_to_follow_up` | Patients with no visit in the past 12 months |
| `heart360_patients_category.total_number_of_patients` | All living patients registered with hypertension |
| `nb_patients_newly_registered` | Patients registered in the last 3 months |
| `nb_patients_under_care` | Registered patients with a visit in the past 12 months |
| `nb_new_patients` | Patients registered in that month |

The controlled percentage, the uncontrolled percentage, and the no-visit percentage use this denominator:

`heart360_patients_category.total_number_of_patients - nb_patients_newly_registered - heart360_patients_category.nb_patients_lost_to_follow_up`

Send these three counts when the percentages must match the dashboard.

`nb_new_patients` means patients registered in that one month. `nb_patients_newly_registered` means patients who are still in their first 3 months. The registrations chart uses `nb_new_patients` for each month. Send one entry for each month when you want the month-to-month line.

## Diabetes counts

Send any of these counts.

| Code | Meaning |
| --- | --- |
| `diabetes_controlled` | Patients with controlled blood sugar at the latest visit in the past 3 months |
| `uncontrolled_moderate` | Patients with uncontrolled blood sugar in the moderate band |
| `uncontrolled_high` | Patients with uncontrolled blood sugar in the high band |
| `missed_visit` | Diabetes patients under care with no blood sugar record in the past 3 months |
| `nb_dm_patients_under_care` | Diabetes patients with a visit in the past 12 months |
| `nb_new_dm_patients` | Diabetes patients registered in that month |
| `heart360_dm_patients_catagory.total_number_of_patients` | All living patients registered with diabetes |
| `heart360_dm_patients_catagory.nb_patients_lost_to_follow_up` | Diabetes patients with no visit in the past 12 months |
| `bp_controlled_140_90` | Diabetes patients with blood pressure below 140/90, and not below 130/80 |
| `bp_controlled_130_80` | Diabetes patients with blood pressure below 130/80 |

Blood sugar percentages use `nb_dm_patients_under_care` as the denominator. The importer copies this count to the blood sugar tables and to the diabetes blood-pressure table. These percentages do not have to add up to 100. A patient can be under care and can be outside controlled, uncontrolled, and missed visit.

The diabetes blood-pressure chart adds `bp_controlled_140_90` and `bp_controlled_130_80` for the result below 140/90.

You can omit one blood-pressure count. The chart shows the count that you send.

## Two ways to send data

If you have the result counts, send `nb_patients_controlled`, `nb_patients_uncontrolled`, `nb_patients_no_visit`, and `heart360_patients_category.nb_patients_lost_to_follow_up`.

If you have the registration counts, send `nb_patients_under_care`, `heart360_patients_category.total_number_of_patients`, `nb_patients_newly_registered`, and `nb_new_patients`.

Send both groups when you have both groups. Each chart uses the count that it already reads.

## File contents

Each file is one JSON object.

- Set `resourceType` to `AggregateIndicatorSubmission`.
- Set `identifier.value` to your id for this file. Use the same id when you send a correction.
- Set `reporter.identifier.value` to your EHR name. Do not change this name.
- Set `period.start` to the first day of the month. The importer records `period.end` with the submission.
- Put each facility in `entries`.

Each entry has an `orgUnit` and a list of `indicators`. Each indicator has a `code` and a `value`.

To send more than one month in one file, put `period` on the entry. That entry uses its own month.

Give the facility name in this order:

1. Use `orgUnit.id` when you have the national org unit id.
2. Use `orgUnit.code` when the code is already mapped.
3. Use `orgUnit.display` when the facility name matches one national org unit.

If the importer cannot match a facility, it does not save that facility. It saves the other facilities in the file.

## Corrections

Replace the file. Send it again with the same `identifier.value`. The new counts replace the old counts for that facility and that month. The importer does not add the two files together.

## Checklist

- Send the file when the counts change. Each entry contains all counts for one calendar month.
- Save the file as UTF-8. End the file name with `.json`.
- Set `resourceType` to `AggregateIndicatorSubmission`.
- Use one `reporter.identifier.value`. Do not change it.
- Use one `identifier.value` for each file. Use the same value when you correct that file.
- Put `period.start` and `period.end` on the file. If the file has more than one month, put `period` on each entry.
- Send counts. Do not send percentages.
- Use a code from the tables above. The importer ignores any other code.
- Send a number that is zero or greater.
- Use `orgUnit.id` when you have it. If you do not have it, use `orgUnit.code` or a unique `orgUnit.display`.
- Omit a count that you do not have. Send zero only when the real count is zero.
- If controlled, uncontrolled, and no visit do not add up to the denominator, send `nb_patients_visit_no_bp`.
- Keep each month that must stay on the dashboard in the import folder. The next import reads the files that are still in the folder.
- Read the rejection log when a facility is missing from the dashboard.

## Example

`test_data/aggregate_scenarios/visit_without_bp.json` is a short example. The three percentages add up to 90. Ten patients had a visit with no blood pressure.

More examples are in `test_data/aggregate_scenarios/`. The folder includes diabetes and a registration series for three months.

## Files, branch, and repo

This section is the parent list. Share this document. It links to each file that a colleague needs.

Repository: [tonyjoyk/h360tk_grafana_core](https://github.com/tonyjoyk/h360tk_grafana_core)

Branch: `cursor/aggregate-ingest-mvp-9630`. Base branch: `feature/drug-stock-mvp`.

Pull request: [Accept EHR indicator counts for the national dashboards](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8)

Use the codes in this document and in `importer_scripts/import_versions/aggregate_json.py`. Do not use the old short names `bp_controlled` and `missed_visit` for hypertension. The importer does not accept those names.

### Give these files to an EHR vendor

- [docs/ehr-aggregate-indicator-requirements.md](ehr-aggregate-indicator-requirements.md) — this document. It has the problem, the counts, and the checklist.
- [docs/ehr-aggregate-json-ingest-mvp.md](ehr-aggregate-json-ingest-mvp.md) — the JSON file shape, facility matching, and corrections.
- [docs/ehr-vendor-aggregate-json-checklist.md](ehr-vendor-aggregate-json-checklist.md) — the same checklist in a separate file.
- [test_data/sample_aggregate_submission.json](../test_data/sample_aggregate_submission.json) — one facility and one month.
- [test_data/aggregate_scenarios/](../test_data/aggregate_scenarios/) — the examples in the table below.

| Example | What the example shows |
| --- | --- |
| [visit_without_bp.json](../test_data/aggregate_scenarios/visit_without_bp.json) | Controlled, uncontrolled, and no visit add up to 90. Ten visits have no blood pressure. |
| [counts_only.json](../test_data/aggregate_scenarios/counts_only.json) | A missing denominator stays blank. |
| [registrations_by_month.json](../test_data/aggregate_scenarios/registrations_by_month.json) | One file has registrations and patients under care for three months. |
| [diabetes.json](../test_data/aggregate_scenarios/diabetes.json) | Blood sugar, diabetes blood pressure, patients under care, and lost to follow-up. |
| [dashboard_demo.json](../test_data/aggregate_scenarios/dashboard_demo.json) | July, August, and September for the live dashboards. |
| [percent_sent.json](../test_data/aggregate_scenarios/percent_sent.json) | The importer ignores a percentage. It keeps the count in the same entry. |
| [correction_first.json](../test_data/aggregate_scenarios/correction_first.json) and [correction_second.json](../test_data/aggregate_scenarios/correction_second.json) | The same file id replaces 120 with 100. |
| [partial_reject.json](../test_data/aggregate_scenarios/partial_reject.json) | The importer skips an unknown facility. It saves the known facility. |
| [negative_value.json](../test_data/aggregate_scenarios/negative_value.json) | The importer ignores a negative count. |
| [legacy_extensions.json](../test_data/aggregate_scenarios/legacy_extensions.json) | Hypertension percentage inputs sent with column names. |

### Read these files to understand the design

- [Ingesting aggregate data into the national dashboard](central-aggregate-ingest-investigation.md) — the single investigation report. It has the decision, the examples, the options, and the spike brief.
- [Architecture spine](../_bmad-output/planning-artifacts/architecture/architecture-h360-central-aggregate-json-ingest-2026-10-14/ARCHITECTURE-SPINE.md) — where the importer stores the counts, and why one count goes to more than one column.
- [Review, 15 October 2026](../_bmad-output/planning-artifacts/reviews/central-aggregate-json-2026-10-15.md) — what stayed, and why the short names were removed.
- [Epics and stories](../_bmad-output/planning-artifacts/epics-central-aggregate-json-ingest-2026-10-14.md)
- [Experience notes](../_bmad-output/planning-artifacts/ux-designs/ux-h360-central-aggregate-json-ingest-2026-10-14/EXPERIENCE.md)
- [Feature map](../.cursor/skills/verify-h360tk-grafana-core/features/central-aggregate-json.md) — how to run the importer, and which numbers the dashboards show. The index is [features/README.md](../.cursor/skills/verify-h360tk-grafana-core/features/README.md).

### Use these files to implement the feature

- [importer_scripts/import_versions/aggregate_json.py](../importer_scripts/import_versions/aggregate_json.py) — the list of column names. One count can fill each column that a panel divides by.
- [importer_scripts/importer.py](../importer_scripts/importer.py) — reads `.json` files from the same folder as the leaf ZIP files.
- [docker_build/heart360.importer.docker](../docker_build/heart360.importer.docker) — copies those scripts into the importer image.
- [docker-compose.yml](../docker-compose.yml) — mounts `./data/export` at `/export` for the importer.
- [pg_init_scripts/migrations/0.5.6_to_0.6.0.sql](../pg_init_scripts/migrations/0.5.6_to_0.6.0.sql) — facility-code mapping, submission log, and rejection log.
- [pg_init_scripts/01_heart360_tables.sql](../pg_init_scripts/01_heart360_tables.sql) — applies that migration on a new database.
- [importer_scripts/test_aggregate_scenarios.py](../importer_scripts/test_aggregate_scenarios.py) — the nine scenarios. The test rolls back. It does not keep the rows.

The dashboards did not change. These panels read the columns:

- [grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension.program.json](../grafana_provisioning/dashboards/HEARTS360%20Dashboards/heart360.hypertension.program.json)
- [grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.diabetes.program.json](../grafana_provisioning/dashboards/HEARTS360%20Dashboards/heart360.diabetes.program.json)

Run the scenarios from the repository root:

```bash
docker run --rm --network h360tk_grafana_core_default --entrypoint python3 \
  -e PYTHONPATH=/importer \
  -e POSTGRES_HOST=postgres \
  -e POSTGRES_DB=heart360tk_database \
  -e POSTGRES_USER=heart360tk \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e FIXTURE_DIR=/fixtures \
  -v "$PWD/test_data/aggregate_scenarios:/fixtures:ro" \
  -v "$PWD/importer_scripts/test_aggregate_scenarios.py:/test_aggregate_scenarios.py:ro" \
  h360tk_grafana_core-importer:latest \
  /test_aggregate_scenarios.py
```

A pass prints `9/9 scenarios passed`.
