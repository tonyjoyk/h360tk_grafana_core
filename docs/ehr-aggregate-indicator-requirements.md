# Send your indicator counts to the national dashboard

You already calculate the HEARTS indicators in your EHR. This note says what to send so those same numbers can appear on the national dashboard.

You send counts. You do not send percentages. The national dashboard calculates the percentages from the counts you send.

You can send as many, or as few, of the counts below as you already have. A missing count stays blank. It is not treated as zero.

The technical file shape is in [EHR aggregate JSON ingest](ehr-aggregate-json-ingest-mvp.md).

The file list for colleagues who are building or reviewing this feature is [Files, branch, and repo](#files-branch-and-repo).

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

## Files, branch, and repo

This is the parent list. Share this document. It links to every other file a colleague needs to understand the feature or to implement it.

Repository: [tonyjoyk/h360tk_grafana_core](https://github.com/tonyjoyk/h360tk_grafana_core)

Branch: `cursor/aggregate-ingest-mvp-9630`, based on `feature/drug-stock-mvp`

Pull request: [Accept EHR indicator counts for the national dashboards](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8)

The current indicator codes are the ones in this document and in `importer_scripts/import_versions/aggregate_json.py`. Earlier planning notes still use the short names `bp_controlled` and `missed_visit`. Those names are not accepted.

### Give this to an EHR vendor

- [docs/ehr-aggregate-indicator-requirements.md](ehr-aggregate-indicator-requirements.md) — this document. The problem, the counts, and the checklist.
- [docs/ehr-aggregate-json-ingest-mvp.md](ehr-aggregate-json-ingest-mvp.md) — the JSON file shape, org-unit matching, and how a correction replaces a month.
- [docs/ehr-vendor-aggregate-json-checklist.md](ehr-vendor-aggregate-json-checklist.md) — the same checklist as a standalone list.
- [test_data/sample_aggregate_submission.json](../test_data/sample_aggregate_submission.json) — one facility, one month.
- [test_data/aggregate_scenarios/](../test_data/aggregate_scenarios/) — the worked examples below.

| Example | What it shows |
| --- | --- |
| [visit_without_bp.json](../test_data/aggregate_scenarios/visit_without_bp.json) | Controlled, uncontrolled, and no visit add up to 90 because 10 visits have no blood pressure. |
| [counts_only.json](../test_data/aggregate_scenarios/counts_only.json) | A missing denominator stays blank. |
| [registrations_by_month.json](../test_data/aggregate_scenarios/registrations_by_month.json) | Three months of registrations and patients under care in one file. |
| [diabetes.json](../test_data/aggregate_scenarios/diabetes.json) | Blood sugar, diabetes blood pressure, under care, and lost to follow-up. |
| [dashboard_demo.json](../test_data/aggregate_scenarios/dashboard_demo.json) | July, August, and September together, for the live dashboards. |
| [percent_sent.json](../test_data/aggregate_scenarios/percent_sent.json) | A percentage is ignored. The count in the same entry is kept. |
| [correction_first.json](../test_data/aggregate_scenarios/correction_first.json) and [correction_second.json](../test_data/aggregate_scenarios/correction_second.json) | The same file id replaces 120 with 100. |
| [partial_reject.json](../test_data/aggregate_scenarios/partial_reject.json) | An unknown facility is skipped. The known facility is saved. |
| [negative_value.json](../test_data/aggregate_scenarios/negative_value.json) | A negative count is ignored. |
| [legacy_extensions.json](../test_data/aggregate_scenarios/legacy_extensions.json) | The hypertension percentage inputs sent as column names. |

### Read this to understand the design

- [Architecture spine](../_bmad-output/planning-artifacts/architecture/architecture-h360-central-aggregate-json-ingest-2026-10-14/ARCHITECTURE-SPINE.md) — where the counts are stored, and why the registry copies one count onto several columns.
- [Review, 15 October 2026](../_bmad-output/planning-artifacts/reviews/central-aggregate-json-2026-10-15.md) — what stayed, and why the short names were removed.
- [Epics and stories](../_bmad-output/planning-artifacts/epics-central-aggregate-json-ingest-2026-10-14.md)
- [Experience notes](../_bmad-output/planning-artifacts/ux-designs/ux-h360-central-aggregate-json-ingest-2026-10-14/EXPERIENCE.md)
- [Feature map](../.cursor/skills/verify-h360tk-grafana-core/features/central-aggregate-json.md) — how to drive the importer and what the dashboards should show. The index is [features/README.md](../.cursor/skills/verify-h360tk-grafana-core/features/README.md).

### Implement it

- [importer_scripts/import_versions/aggregate_json.py](../importer_scripts/import_versions/aggregate_json.py) — the allow-list of column names, and the copy of one count onto every column a panel divides by.
- [importer_scripts/importer.py](../importer_scripts/importer.py) — reads `.json` files from the same folder as the leaf ZIP files.
- [docker_build/heart360.importer.docker](../docker_build/heart360.importer.docker) — copies those scripts into the importer image.
- [docker-compose.yml](../docker-compose.yml) — mounts `./data/export` at `/export` for the importer.
- [pg_init_scripts/migrations/0.5.6_to_0.6.0.sql](../pg_init_scripts/migrations/0.5.6_to_0.6.0.sql) — org-unit mapping, submission log, and rejection log.
- [pg_init_scripts/01_heart360_tables.sql](../pg_init_scripts/01_heart360_tables.sql) — applies that migration on a new database.
- [importer_scripts/test_aggregate_scenarios.py](../importer_scripts/test_aggregate_scenarios.py) — the nine scenarios. It rolls back, so it does not keep the rows it writes.

The dashboards are unchanged. These are the panels that read the columns:

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

A passing run prints `9/9 scenarios passed`.
