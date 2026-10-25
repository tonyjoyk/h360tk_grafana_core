# Compare three ways to send aggregate counts

Date: 25 October 2026.

This report helps you choose how a new EHR sends aggregate counts to the national dashboard. The EHR does not install the leaf node.

The report uses the views in `pg_init_scripts/01_heart360_tables.sql`, the ZIP path in `exporter_scripts/exporter.py` and `importer_scripts/import_versions/v1.py`, and the JSON path in `importer_scripts/import_versions/aggregate_json.py`.

## Recommendation

Use Approach 3. Ask the EHR to send one JSON file. Do not ask the EHR to copy the 13 ZIP CSVs. Do not build a Master CSV adapter unless a named EHR refuses JSON.

Approach 1 is cheap for the central node and hard for the EHR. The ZIP is a copy of our reporting tables. The EHR must write the HEARTS definitions, the org tree, and the overdue counts.

Approach 2 is hard for both sides. One wide row still holds every colliding column from every view. The central node then needs a new adapter that splits that row back into the same tables.

Approach 3 is the file a person can write. The central node already reads it. The dashboard already calculates percentages. The EHR sends only the counts it has.

## How the folder works

The central importer watches one folder. Each run clears the reporting tables. Then it loads every valid `.zip` and `.json` file that is still in the folder.

The national dashboards read `heart360tk_reporting`. They do not read the file type.

A `.csv` file in that folder is ignored today.

## What is in the current ZIP

The leaf exporter writes 12 reporting CSVs, `orgunit.csv`, and `metadata.json`. That is 13 CSV files plus one metadata file. The 12 reporting files come from `SELECT *` on the tables in `DEFAULT_EXPORT_TABLES` in `exporter_scripts/exporter.py`.

These 12 reporting files are in the ZIP:

1. `HEART360_PATIENTS_CATEGORY.csv`
2. `HEART360_PATIENTS_UNDER_CARE.csv`
3. `HEART360_PATIENTS_REGISTERED.csv`
4. `HEART360_BLOOD_SUGAR_CONTROLLED.csv`
5. `HEART360_BLOOD_SUGAR_SEVERITY.csv`
6. `HEART360_BLOOD_SUGAR_MISSED_VISITS.csv`
7. `HEART360_DM_BP_CONTROL.csv`
8. `HEART360_DM_PATIENTS_UNDER_CARE.csv`
9. `HEART360_OVERDUE_START_OF_MONTH.csv`
10. `HEART360_OVERDUE_PATIENTS_CALLED.csv`
11. `HEART360_OVERDUE_RETURNED_TO_CARE.csv`
12. `HEART360_DM_PATIENTS_CATAGORY.csv`

`orgunit.csv` is the 13th CSV. It is the org tree. It is not an indicator view.

Two other views exist in the schema and are not in the default ZIP. They are `HEART360_OVERDUE_PATIENTS` and `HEART360_COHORT_PATIENT_DETAILS`.

`metadata.json` from `generate_metadata()` looks like this:

```json
{
  "import_export_version": 1,
  "source_key": "acme-ehr",
  "source_h360tk_version": "0.5.0",
  "generated_at": "2026-10-02 12:15:00 UTC",
  "generated_at_epoch": 1759407300,
  "generation_duration_seconds": 4.2,
  "facility_count": 1,
  "patient_count": 208
}
```

The importer does not check `source_key` against a list of system names. It only requires a non-empty `source_key`. It requires `import_export_version`. Version `1` is the only registered version. A new EHR does not need a central-node code change to use a new name.

The importer copies each reporting CSV into the table with the same file name. `COPY` uses `FORMAT CSV, HEADER TRUE` without `HEADER MATCH`. PostgreSQL 16 then skips the header and loads columns by position. The EHR must keep the same column order as the view.

`org_unit_id` in those CSVs is the leaf id. The importer remaps it through `import_facility_mapping` after it reads `orgunit.csv`.

## Approach 1. Mimic the 13 CSVs

Ask the EHR to produce the same ZIP the leaf already produces.

### What the EHR must do

1. Recreate the HEARTS definitions. The views use a 3-month new-registration window, a 12-month lost-to-follow-up window, hypertension-relevant encounters, and diabetes-relevant encounters. Those rules live in `pg_init_scripts/01_heart360_tables.sql`. A wrong window changes the national percentage.
2. Write 12 reporting views or queries. Each output must use the same column names and the same column order as the HEARTS view.
3. Write `orgunit.csv` with `id`, `name`, `level`, and `parent_id`. Parent rows must appear before child rows. The importer creates national org units from this file.
4. Write `metadata.json` with a non-empty `source_key` and `import_export_version` set to `1`.
5. Pack the 13 CSVs and `metadata.json` into a ZIP. Put the ZIP in the importer folder.

The EHR must also produce the three overdue CSVs if those panels must stay filled. Those counts need scheduled visits, call results, and phone numbers. An EHR that only has hypertension and diabetes totals still has to emit empty overdue files or accept blank overdue panels.

### What the central node must change

No importer change is required for a new `source_key`. The claim that we must "accept the new system name" is not true in this code.

The central node still needs an operations step. Someone must agree the org names, watch the first load, and keep the ZIP in the folder. The next import reloads only the files that remain.

### Cost of a future indicator

A new dashboard column needs a new view column, a new CSV column in the same position, a new leaf export, and a new EHR view. Every sender updates at the same time.

## Approach 2. One Master CSV

Ask the EHR to send one CSV that holds every count, plus `metadata.json`. The central node writes an adapter that splits the row into the 12 reporting tables. `orgunit.csv` is still required if the EHR uses leaf ids.

### Why one wide row is not simple

The 12 views share names. These names mean different things on different tables:

| Column | Where it appears |
| --- | --- |
| `org_unit_id` | Every reporting view |
| `ref_month` | Every reporting view |
| `nb_patients_under_care` | `heart360_patients_category` and `heart360_patients_under_care` |
| `nb_patients_lost_to_follow_up` | Hypertension category, hypertension under care, diabetes under care, and diabetes category |
| `total_number_of_patients` | Hypertension category and diabetes category |
| `nb_patients_controlled` | Hypertension category and diabetes category |
| `nb_patients_uncontrolled` | Hypertension category and diabetes category |
| `nb_patients_no_visit` | Hypertension category and diabetes category |
| `nb_patients_newly_registered` | Hypertension category and diabetes category |
| `cumulative_number_of_patients` | Hypertension registered and hypertension under care |
| `diabetes_patients_under_care` | Blood sugar controlled, severity, and missed visits |

A header that uses the short name once cannot fill those tables. The Master CSV must prefix the colliding names with the table name.

### Master CSV format

One row is one facility and one calendar month. Column types come from the views. `ref_month` is `date`. `org_unit_id` is `integer`. Every count is `bigint` from `COUNT` or `SUM`. Send an empty cell when the EHR does not have that count. Do not send `0` for a missing count.

```csv
org_unit_id,ref_month,org_unit_code,org_unit_display,heart360_patients_category.total_number_of_patients,heart360_patients_category.nb_patients_under_care,heart360_patients_category.nb_patients_newly_registered,heart360_patients_category.nb_patients_under_care_registered_before_the_past_3_months,heart360_patients_category.nb_patients_lost_to_follow_up,heart360_patients_category.nb_patients_no_visit,heart360_patients_category.nb_patients_under_care_registered_before_3m_incl_visits,heart360_patients_category.nb_patients_uncontrolled,heart360_patients_category.nb_patients_controlled,heart360_patients_category.nb_patients_visit_no_bp,heart360_patients_under_care.nb_patients_lost_to_follow_up,heart360_patients_under_care.nb_patients_under_care,heart360_patients_under_care.cumulative_number_of_patients,heart360_patients_registered.cumulative_number_of_patients,heart360_patients_registered.nb_new_patients,heart360_blood_sugar_controlled.diabetes_patients_under_care,heart360_blood_sugar_controlled.diabetes_controlled,heart360_blood_sugar_severity.diabetes_patients_under_care,heart360_blood_sugar_severity.uncontrolled_moderate,heart360_blood_sugar_severity.uncontrolled_high,heart360_blood_sugar_missed_visits.diabetes_patients_under_care,heart360_blood_sugar_missed_visits.missed_visit,heart360_dm_patients_under_care.nb_dm_patients_under_care,heart360_dm_patients_under_care.cumulative_dm_patients,heart360_dm_patients_under_care.nb_new_dm_patients,heart360_dm_patients_under_care.nb_patients_lost_to_follow_up,heart360_dm_bp_control.dm_patients_under_care,heart360_dm_bp_control.bp_controlled_140_90,heart360_dm_bp_control.bp_controlled_130_80,heart360_dm_patients_catagory.total_number_of_patients,heart360_dm_patients_catagory.nb_patients_under_care,heart360_dm_patients_catagory.nb_patients_newly_registered,heart360_dm_patients_catagory.nb_patients_under_care_registered_before_the_past_3_months,heart360_dm_patients_catagory.nb_patients_lost_to_follow_up,heart360_dm_patients_catagory.nb_patients_no_visit,heart360_dm_patients_catagory.nb_patients_under_care_registered_before_3m_incl_visits,heart360_dm_patients_catagory.nb_patients_uncontrolled,heart360_dm_patients_catagory.nb_patients_controlled,heart360_dm_patients_catagory.nb_patients_visit_no_bs,heart360_overdue_start_of_month.overdue_on_first,heart360_overdue_patients_called.overdue_patients_called,heart360_overdue_returned_to_care.overdue_returned_to_care
3,2026-09-01,H360-AUDIT-PHC,H360_AUDIT_PHC,120,90,10,100,10,10,100,30,50,10,10,90,120,20,8,80,40,80,15,5,80,10,80,100,6,,80,24,12,100,,,,8,,,,,,,,
```

The example row uses the September demo counts from `test_data/aggregate_scenarios/dashboard_demo.json`. Empty cells are counts that file does not send. The overdue columns stay empty. The diabetes category file sends only the total and lost to follow-up.

A useful Master CSV still needs `metadata.json` if the file arrives in a ZIP. A bare `.csv` in the folder is not read. The adapter would have to accept `.csv` names, or the EHR would wrap the Master CSV and `metadata.json` in a ZIP.

### What the EHR must do

1. Calculate every count the dashboards show. The EHR still needs the HEARTS windows. A single file does not remove the definitions.
2. Fill one wide row per facility and month. Prefix every colliding name.
3. Decide empty versus zero for each cell.
4. Send `orgunit.csv` if `org_unit_id` is a local id. Or send a national id that already exists.
5. Send `metadata.json` if the transport stays a ZIP.

The EHR must still compute `nb_patients_visit_no_bp`. It must still keep `nb_new_patients` (that month) separate from `nb_patients_newly_registered` (last 3 months).

### What the central node must change

Write a new adapter. That adapter must:

1. Accept a `.csv` file or a ZIP that holds one Master CSV.
2. Parse UTF-8, a header row, and commas. Reject a title row, a `;` delimiter, `50%`, and `1,208`.
3. Split one row into 12 `INSERT` statements. Map each prefixed column to `(table, column)`.
4. Copy `diabetes_patients_under_care` and `nb_dm_patients_under_care` onto every diabetes denominator column if the EHR sends the count once.
5. Remap `org_unit_id` or match a national facility.
6. Keep the snapshot rule. A later file replaces columns. A missing file disappears on the next run.

That adapter is a second write path next to `aggregate_json.py`. Two write paths drift when a panel adds a column.

### A long Master CSV

A long file is one row per count. The headers are `reporter`, `submission_id`, `period_start`, `period_end`, `org_unit_id`, `org_unit_code`, `org_unit_display`, `code`, `value`. That file is the JSON submission in CSV form. It is smaller than the wide row. It is not a new idea. Approach 3 already stores that shape.

## Approach 3. One JSON file

This path is on branch `cursor/aggregate-ingest-mvp-9630`. The EHR drops `AggregateIndicatorSubmission` in the same folder.

### What the EHR must do

1. Calculate the counts it already shows.
2. Write one JSON file. Set `resourceType` to `AggregateIndicatorSubmission`.
3. Set `reporter.identifier.value` to a stable EHR name. Set `identifier.value` to the file id.
4. Set `period.start` to the first day of the month.
5. Put each facility in `entries`. Match the facility by national id, then mapped code, then unique name.
6. Send each count as `{ "code": "<column name>", "value": <whole number> }`. Use the table name only on `nb_patients_lost_to_follow_up` and `total_number_of_patients`.
7. Omit a count that is unknown. Send zero only when the count is zero.
8. Put the file in the importer folder. Keep it there while that month must stay on the dashboard.

The EHR does not write 12 views. The EHR does not send a patient list. The EHR does not create the national org tree. The EHR does not send percentages.

A short file looks like this:

```json
{
  "resourceType": "AggregateIndicatorSubmission",
  "identifier": { "system": "urn:hearts360:source-system", "value": "acme-ehr|2026-09" },
  "reporter": { "identifier": { "system": "urn:hearts360:vendor", "value": "acme-ehr" } },
  "period": { "start": "2026-09-01", "end": "2026-09-30" },
  "entries": [
    {
      "orgUnit": { "id": 3, "display": "H360_AUDIT_PHC" },
      "indicators": [
        { "code": "nb_patients_controlled", "value": 50 },
        { "code": "nb_patients_uncontrolled", "value": 30 },
        { "code": "nb_patients_no_visit", "value": 10 },
        { "code": "nb_patients_visit_no_bp", "value": 10 },
        { "code": "heart360_patients_category.total_number_of_patients", "value": 120 },
        { "code": "nb_patients_newly_registered", "value": 10 },
        { "code": "heart360_patients_category.nb_patients_lost_to_follow_up", "value": 10 }
      ]
    }
  ]
}
```

### What we changed on the central node

`git diff --stat` against `feature/drug-stock-mvp` shows 32 files, 3355 insertions, and 65 deletions. The runtime change is small. Most of the diff is docs, planning notes, and fixtures.

| File | Role |
| --- | --- |
| `importer_scripts/import_versions/aggregate_json.py` | New. Registry, validation, and column writes. 19 public codes. |
| `importer_scripts/importer.py` | Accept `.json` next to `.zip`. Empty environment values do not crash. |
| `pg_init_scripts/migrations/0.5.6_to_0.6.0.sql` | Mapping table, submission log, rejection log. |
| `pg_init_scripts/01_heart360_tables.sql` | Apply that migration on a new database. |
| `docker-compose.yml` | Pass `IMPORT_AGGREGATE_DATA`. |
| `importer_scripts/test_aggregate_scenarios.py` | Nine scenarios. The run rolls back. |
| `test_data/aggregate_scenarios/` | The example files. |
| `docs/` | Vendor note, JSON shape, checklist, investigation report. |

The Grafana dashboard JSON did not change. The ZIP reader did not change. The leaf exporter did not change.

The JSON path does not write the overdue tables. It does not create org units from the file. Those two jobs stay on the ZIP path.

### Cost of a future indicator

Add one code to the registry. The EHR adds one `{ "code", "value" }` pair. The dashboard already reads the column, or you add a panel later. Senders that do not have the new count omit it.

## Comparison

| Question | Approach 1. 13 CSVs | Approach 2. Master CSV | Approach 3. JSON |
| --- | --- | --- | --- |
| Time for a new EHR | Long. The EHR copies 12 HEARTS views, the org tree, and overdue counts. | Long. The EHR still calculates the same counts and fills a wide row with prefixed names. | Short. The EHR writes the counts it already has. |
| Time for the central node now | None in code. Operations only. | New adapter, new tests, new rejection cases for Excel files. | Already done on this branch. |
| Time when a panel adds a column | Every EHR view and every CSV position change. | The wide header grows. The adapter grows. | One registry line. One optional JSON field. |
| Missing counts | A missing CSV column shifts `COPY` by position and can write the wrong number. | An empty cell is possible if the adapter treats blank as null. | Omit the code. The cell stays null. |
| Org tree | The EHR sends `orgunit.csv` and can create national units. | The EHR still needs org ids or a second file. | The EHR matches a facility that already exists. |
| Overdue panels | Filled if the EHR sends those three CSVs. | Filled only if the wide row includes those columns. | Blank until those codes join the registry. |
| Risk to installed leaves | Low. Same ZIP. | Medium. A third reader in the same truncate loop. | Low. The ZIP reader stayed. |
| File a person can check | 13 files. Hard to review. | One very wide row. Easy to break in Excel. | One short list. Easy to review. |

## Decision

JSON is the best mode for an EHR that only sends aggregate data.

Use Approach 1 only when the site will install the leaf node, or when it already runs the HEARTS SQL and can emit the ZIP without a rewrite.

Do not build Approach 2 now. A wide Master CSV is the 12 views in one line. A long Master CSV is Approach 3 with commas. Neither removes work from the EHR. The second one adds a parser we do not need.

## Where the files live

- This comparison: `docs/compare-aggregate-ingest-approaches.md`
- Investigation report: `docs/central-aggregate-ingest-investigation.md`
- Vendor JSON contract: `docs/ehr-aggregate-indicator-requirements.md`
- Registry: `importer_scripts/import_versions/aggregate_json.py`
- ZIP import: `importer_scripts/import_versions/v1.py`
- Views: `pg_init_scripts/01_heart360_tables.sql`
- Code: [pull request 8](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8)
