# Send aggregate JSON to the central node

An EHR that does not install the leaf node drops one JSON file where the central importer already collects files. The national hypertension and diabetes dashboards show those counts, and they calculate the percentages.

## Sub-features

- `json-file-drop`: a `.json` file in the import folder is accepted beside a leaf ZIP.
- `month-snapshot`: `period.start` selects the calendar month, and a later file for that facility and month replaces those counts.
- `partial-counts`: a missing count stays blank on the dashboard.
- `visit-without-bp`: `nb_patients_visit_no_bp` lets the three hypertension percentages add up to less than 100.
- `diabetes-counts`: one `nb_dm_patients_under_care` value fills the diabetes denominators the blood-sugar and blood-pressure panels divide by.
- `unknown-facility`: a new display name creates the clinic. A row with no display, no mapped code, and no existing id is skipped, and the other facilities in the file are saved.
- `create-with-parents`: `orgUnit.parents` upserts region, district, and clinic through `upsert_org_unit_chain`.
- `create-without-parents`: missing ancestors become `UNKNOWN ({source_key})`.

## How to get to it (user POV)

- Put the file in the central import folder (`IMPORT_FOLDER_PATH`, mounted at `data/export` in local compose).
- Open Hypertension Program: `http://localhost:3000/d/heart360_drilldown/hypertension-program?orgId=1&from=2026-07-01T00:00:00.000Z&to=2026-09-30T23:59:59.000Z&var-region=1`
- Open Diabetes Program: `http://localhost:3000/d/heart360_drilldown_diabetes/diabetes-program?orgId=1&from=2026-07-01T00:00:00.000Z&to=2026-09-30T23:59:59.000Z&var-region=1`
- Read a rejection in `heart360tk_reporting.external_aggregate_rejection_log` when a row has no display name and cannot be matched.

## Driving it with the importer

Preconditions: the importer image `h360tk_grafana_core-importer` contains `import_versions/aggregate_json.py`, and Postgres is reachable as host `postgres` on network `h360tk_grafana_core_default`.

- Action: run the scenario file. Command: `docker run --rm --network h360tk_grafana_core_default --entrypoint python3 -e PYTHONPATH=/importer -e POSTGRES_HOST=postgres -e POSTGRES_DB=heart360tk_database -e POSTGRES_USER=heart360tk -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD -e FIXTURE_DIR=/fixtures -v $PWD/test_data/aggregate_scenarios:/fixtures:ro -v $PWD/importer_scripts/test_aggregate_scenarios.py:/test_aggregate_scenarios.py:ro -v $PWD/importer_scripts/import_versions:/importer/import_versions:ro h360tk_grafana_core-importer:latest /test_aggregate_scenarios.py`. Result: the process prints `14/14 scenarios passed` and leaves the database unchanged.
- Action: open Hypertension Program for July–September 2026 after `dashboard_demo.json` has been imported. Result: controlled reads 50% and 50, uncontrolled reads 30% and 30, no visit reads 10% and 10, and AUDIT_DIST shows under care 90 and registrations 8.
- Action: open Diabetes Program for the same range. Result: blood pressure reads 45% and 15%, controlled blood sugar reads 50% and 40, uncontrolled reads 25% and 20, and no visit reads 13% and 10.

## Gotchas

- The scenario runner deletes and rolls back org units 1 and 3 from 2026-07-01. A run that commits would replace the live demo.
- The importer reloads every file still in the folder and truncates the reporting tables first. A leaf ZIP left in `data/export` replaces the JSON snapshot on the next run.
- This compose file is not a central node. The hourly reporting refresh rebuilds those tables from the line list and removes the JSON snapshot.
- `period.end` does not choose the month. A start date of 15 September is stored as September.
- `nb_patients_lost_to_follow_up` and `total_number_of_patients` must include the table name. The same column exists for hypertension and diabetes.
