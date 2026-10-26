# Compare three ways to send aggregate counts

Date: 25 October 2026.

This report helps you choose how a new EHR sends aggregate counts to the national dashboard. The EHR does not install the leaf node. The EHR already calculates the indicators. Do not recalculate them. Do not send a patient line list.

The report uses the views in `pg_init_scripts/01_heart360_tables.sql`, the ZIP path in `exporter_scripts/exporter.py` and `importer_scripts/import_versions/v1.py`, and the JSON path in `importer_scripts/import_versions/aggregate_json.py`.

## Recommendation

Use Approach 3. Ask the EHR to send one JSON file.

Approach 3 is the easiest path for a junior EHR developer. The national importer already reads that file. The dashboard already calculates percentages.

Approach 1 is cheap for the national node and hard for the EHR. The EHR must copy 12 table shapes, an org tree, and a ZIP.

Approach 2 is hard for both sides. The EHR still maps every count. The national node must write a new adapter. That adapter is not in the code today.

Do not ask the EHR to copy the ZIP unless that site already runs the HEARTS SQL. Do not build a Master CSV adapter unless a named EHR refuses JSON.

## How to read this

| If you have | Read |
| --- | --- |
| A choice to make | [Recommendation](#recommendation) and [Comparison](#comparison) |
| A junior task on the EHR side | [A sample EHR database](#a-sample-ehr-database), then the walkthrough for one approach |
| A national-node task | The "National dashboard change" section in each approach |

## How the national folder works

The central importer watches one folder. Each run clears the reporting tables. Then it loads every valid `.zip` and `.json` file that is still in the folder.

The national dashboards read `heart360tk_reporting`. They do not read the file type.

A `.csv` file in that folder is ignored today.

Keep each file in the folder while that month must stay on the dashboard. The next import reloads only the files that remain.

## What is in the current ZIP

The working ZIP has 13 CSV files and one `metadata.json` file. Twelve CSVs come from reporting views. The 13th CSV is `orgunit.csv`. That file is the facility tree. It is not an indicator view.

The leaf exporter writes those 12 reporting files with `SELECT *` on the tables in `DEFAULT_EXPORT_TABLES` in `exporter_scripts/exporter.py`.

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

The importer does not check `source_key` against a list of system names. It only requires a non-empty `source_key`. It requires `import_export_version`. Version `1` is the only registered version. A new EHR name does not need a national code change.

The importer copies each reporting CSV into the table with the same file name. `COPY` uses `FORMAT CSV, HEADER TRUE` without `HEADER MATCH`. PostgreSQL 16 then skips the header and loads columns by position. The EHR must keep the same column order and the same field count as the view. A wrong field count fails that ZIP after the reporting tables are already cleared.

`org_unit_id` in those CSVs is the EHR facility id. The importer remaps it after it reads `orgunit.csv`. Validation does not require `orgunit.csv`. Import does. A ZIP that passes the gate and then lacks `orgunit.csv` leaves the indicator tables empty.

## A sample EHR database

You are a junior developer at Acme EHR. The product already stores monthly counts. You do not read the patient table for this task.

The sample database has two tables.

```sql
CREATE TABLE ehr.facility (
    facility_id   integer PRIMARY KEY,
    facility_code text NOT NULL,
    facility_name text NOT NULL,
    level         integer NOT NULL,
    parent_id     integer
);

CREATE TABLE ehr.monthly_indicators (
    facility_id            integer NOT NULL,
    month_start            date NOT NULL,
    htn_controlled         integer,
    htn_uncontrolled       integer,
    htn_no_visit           integer,
    htn_visit_no_bp        integer,
    htn_total              integer,
    htn_newly_registered   integer,
    htn_ltfu               integer,
    htn_under_care         integer,
    htn_new_this_month     integer,
    dm_controlled          integer,
    dm_uncontrolled_mod    integer,
    dm_uncontrolled_high   integer,
    dm_missed              integer,
    dm_under_care          integer,
    dm_new_this_month      integer,
    dm_total               integer,
    dm_ltfu                integer,
    dm_bp_140_90           integer,
    dm_bp_130_80           integer,
    PRIMARY KEY (facility_id, month_start)
);
```

Sample rows:

```sql
INSERT INTO ehr.facility VALUES
    (1, 'DEMO-REG', 'Demo Region', 1, NULL),
    (2, 'AUDIT-DIST', 'AUDIT_DIST', 2, 1),
    (3, 'H360-AUDIT-PHC', 'H360_AUDIT_PHC', 3, 2);

INSERT INTO ehr.monthly_indicators VALUES
    (3, '2026-09-01',
     50, 30, 10, 10, 120, 10, 10, 90, 8,
     40, 15, 5, 10, 80, 6, 100, 8, 24, 12);
```

These numbers are the September demo counts from `test_data/aggregate_scenarios/dashboard_demo.json`. You map them. You do not calculate them again.

## Approach 1. Thirteen CSVs and metadata.json

You copy the ZIP that a leaf node already sends.

### What you build

You build an export job. The job reads `ehr.monthly_indicators` and `ehr.facility`. It writes 12 reporting CSVs, or fewer if you omit overdue files. It writes `orgunit.csv`. It writes `metadata.json`. It packs those files into a ZIP. It puts the ZIP in the national SFTP folder.

You do not write HEARTS patient SQL. You do write one `SELECT` per reporting file. Each `SELECT` must output the national column order.

### Data you need

You need the monthly counts you already store. You need the facility tree. You need the national column list for each file you will send. That list is in `pg_init_scripts/01_heart360_tables.sql`.

You do not need patient names, encounter rows, or blood-pressure readings.

### Exact steps

1. Ask the national operator for the SFTP folder and for the national facility names.
2. Open the column list for `HEART360_PATIENTS_CATEGORY`. The order is fixed.
3. Write a view or a query that maps your columns into that order.

```sql
CREATE VIEW ehr.export_patients_category AS
SELECT
    i.month_start                              AS ref_month,
    i.facility_id                              AS org_unit_id,
    i.htn_total                                AS total_number_of_patients,
    i.htn_under_care                           AS nb_patients_under_care,
    i.htn_newly_registered                     AS nb_patients_newly_registered,
    i.htn_total - i.htn_newly_registered
        - i.htn_ltfu                           AS nb_patients_under_care_registered_before_the_past_3_months,
    i.htn_ltfu                                 AS nb_patients_lost_to_follow_up,
    i.htn_no_visit                             AS nb_patients_no_visit,
    i.htn_total - i.htn_newly_registered
        - i.htn_ltfu                           AS nb_patients_under_care_registered_before_3m_incl_visits,
    i.htn_uncontrolled                         AS nb_patients_uncontrolled,
    i.htn_controlled                           AS nb_patients_controlled,
    i.htn_visit_no_bp                          AS nb_patients_visit_no_bp
FROM ehr.monthly_indicators i;
```

The two long denominator columns are in the national view. The dashboard does not need them if the three inputs above are present. You still send them in Approach 1, because `COPY` expects 12 fields.

4. Export that view to CSV. Keep the header. Keep the column order.

```csv
ref_month,org_unit_id,total_number_of_patients,nb_patients_under_care,nb_patients_newly_registered,nb_patients_under_care_registered_before_the_past_3_months,nb_patients_lost_to_follow_up,nb_patients_no_visit,nb_patients_under_care_registered_before_3m_incl_visits,nb_patients_uncontrolled,nb_patients_controlled,nb_patients_visit_no_bp
2026-09-01,3,120,90,10,100,10,10,100,30,50,10
```

Save the file as `HEART360_PATIENTS_CATEGORY.csv`.

5. Repeat the same mapping for each reporting file that you will send. `HEART360_PATIENTS_REGISTERED.csv` needs `nb_new_patients`. That is `htn_new_this_month` in the sample. It is not `htn_newly_registered`.
6. Write `orgunit.csv`.

```csv
id,name,level,parent_id
1,Demo Region,1,
2,AUDIT_DIST,2,1
3,H360_AUDIT_PHC,3,2
```

The importer sorts by level, then id. A parent must have a lower level, or the same level and a smaller id. The importer can create national org units from this file.

7. Write `metadata.json`.

```json
{
  "import_export_version": 1,
  "source_key": "acme-ehr",
  "source_h360tk_version": "acme-1.0",
  "generated_at": "2026-10-02 12:15:00 UTC",
  "generated_at_epoch": 1759407300,
  "generation_duration_seconds": 4.2,
  "facility_count": 1,
  "patient_count": 208
}
```

The importer reads `source_key`, `import_export_version`, and `generated_at_epoch`. The other keys are optional.

8. Pack the files into `acme-ehr.zip`. Put `metadata.json` at the root of the ZIP. Put `orgunit.csv` at the root. Put each reporting CSV at the root.
9. Upload the ZIP to the national SFTP folder. Keep it there.
10. Ask the national operator to run the importer, or wait for the hourly job. Open the hypertension dashboard and the diabetes dashboard. Check September 2026.

### National dashboard change

No importer change is required for a new `source_key`. The national node still needs an operations step. Someone must agree the facility names, watch the first load, and keep the ZIP in the folder.

### Time estimate

Count 8 to 12 working days for one junior developer.

Assumptions: the counts already exist. You send one to 20 facilities. You map hypertension and diabetes files. You omit overdue files. You have SQL and SFTP. You test one month. A national operator is available for one review.

The three overdue CSVs are optional. A missing overdue file leaves that table empty after the job-wide clear. Overdue panels then stay blank unless another ZIP in the same folder still sends those files.

### Risks

A missing column shifts every later value. The load can succeed and still show the wrong number. Two facilities with the same name, level, and parent become one national id. Their month rows then collide.

## Approach 2. One Master CSV and metadata.json

You send one wide CSV that holds every count, plus `metadata.json`. The national node does not read this file today.

### What you build

You build one export query. The query writes one row per facility and month. You prefix colliding names with the table name. You also write `metadata.json`. You may still need `orgunit.csv` if `org_unit_id` is your local id.

The 12 views have 42 measure columns after you drop the repeated keys. A lossless Master CSV has those 42 cells.

### Data you need

You need the same monthly counts as Approach 1. You need the national name for each cell. You need a decision for empty versus zero.

### Exact steps

1. Confirm that the national team will write the adapter. Stop if they will not. A `.csv` file in the folder is ignored today.
2. Map your columns to the prefixed names. These names collide if you omit the table:

| Your column | National cell |
| --- | --- |
| `htn_controlled` | `heart360_patients_category.nb_patients_controlled` |
| `htn_uncontrolled` | `heart360_patients_category.nb_patients_uncontrolled` |
| `htn_no_visit` | `heart360_patients_category.nb_patients_no_visit` |
| `htn_visit_no_bp` | `heart360_patients_category.nb_patients_visit_no_bp` |
| `htn_total` | `heart360_patients_category.total_number_of_patients` |
| `htn_newly_registered` | `heart360_patients_category.nb_patients_newly_registered` |
| `htn_ltfu` | `heart360_patients_category.nb_patients_lost_to_follow_up` |
| `htn_under_care` | `heart360_patients_under_care.nb_patients_under_care` |
| `htn_new_this_month` | `heart360_patients_registered.nb_new_patients` |
| `dm_controlled` | `heart360_blood_sugar_controlled.diabetes_controlled` |
| `dm_under_care` | `heart360_dm_patients_under_care.nb_dm_patients_under_care` |

`htn_under_care` and the hypertension-category under-care column are different measures in the national views. A lossless file keeps them in separate cells. Do not send one number twice unless your EHR stored both.

3. Export one row.

```sql
SELECT
    i.facility_id AS org_unit_id,
    i.month_start AS ref_month,
    f.facility_code AS org_unit_code,
    f.facility_name AS org_unit_display,
    i.htn_total AS "heart360_patients_category.total_number_of_patients",
    i.htn_controlled AS "heart360_patients_category.nb_patients_controlled",
    i.htn_uncontrolled AS "heart360_patients_category.nb_patients_uncontrolled",
    i.htn_no_visit AS "heart360_patients_category.nb_patients_no_visit",
    i.htn_visit_no_bp AS "heart360_patients_category.nb_patients_visit_no_bp",
    i.htn_newly_registered AS "heart360_patients_category.nb_patients_newly_registered",
    i.htn_ltfu AS "heart360_patients_category.nb_patients_lost_to_follow_up",
    i.htn_under_care AS "heart360_patients_under_care.nb_patients_under_care",
    i.htn_new_this_month AS "heart360_patients_registered.nb_new_patients",
    i.dm_controlled AS "heart360_blood_sugar_controlled.diabetes_controlled",
    i.dm_under_care AS "heart360_dm_patients_under_care.nb_dm_patients_under_care"
FROM ehr.monthly_indicators i
JOIN ehr.facility f ON f.facility_id = i.facility_id
WHERE i.month_start = DATE '2026-09-01';
```

A short sample row:

```csv
org_unit_id,ref_month,org_unit_code,org_unit_display,heart360_patients_category.total_number_of_patients,heart360_patients_category.nb_patients_controlled,heart360_patients_category.nb_patients_uncontrolled,heart360_patients_category.nb_patients_no_visit,heart360_patients_category.nb_patients_visit_no_bp,heart360_patients_category.nb_patients_newly_registered,heart360_patients_category.nb_patients_lost_to_follow_up,heart360_patients_under_care.nb_patients_under_care,heart360_patients_registered.nb_new_patients,heart360_blood_sugar_controlled.diabetes_controlled,heart360_dm_patients_under_care.nb_dm_patients_under_care
3,2026-09-01,H360-AUDIT-PHC,H360_AUDIT_PHC,120,50,30,10,10,10,10,90,8,40,80
```

A lossless file also has the other 27 measure columns. Leave a cell empty when you do not have that count. Do not write `0` for a missing count. Do not save the file from Excel with a `;` delimiter or a `50%` value.

`ref_month` is `date`. `org_unit_id` is `integer`. Most counts are `bigint`. `heart360_patients_registered.nb_new_patients` and `heart360_patients_registered.cumulative_number_of_patients` are `numeric`.

4. Write the same `metadata.json` as Approach 1 if the file travels in a ZIP.
5. Do not upload a bare `.csv` to the live folder. The importer will ignore it.

### National dashboard change

The national team must write a new adapter. That adapter must:

1. Accept a `.csv` file or a ZIP that holds one Master CSV.
2. Parse UTF-8, a header row, and commas. Reject a title row, a `;` delimiter, `50%`, and `1,208`.
3. Split one row into 12 inserts. Map each prefixed column to that one table and column.
4. Skip a table when every measure for it is empty. Do not copy one count onto several denominator columns. `nb_dm_patients_under_care`, `diabetes_patients_under_care`, and `dm_patients_under_care` use different rules in the views.
5. Remap `org_unit_id` or match a national facility.
6. Keep the snapshot rule.

That adapter is a second write path next to `aggregate_json.py`. Two write paths drift when a panel adds a column.

A long Master CSV uses `org_unit_id`, `ref_month`, `code`, and `value`. A lossless long file uses 42 `table.column` codes. The JSON path has 19 codes and copies some of them. A long Master CSV is not Approach 3 with commas.

### Time estimate

Count 4 to 6 working days on the EHR side after the adapter exists.

Count 8 to 12 working days on the national side to write the adapter and the tests.

Assumptions: the counts already exist. One junior EHR developer. One national developer. One test month. Excel is not the export tool.

The EHR is blocked until the adapter exists.

### Risks

The file looks simple and is not simple. Twelve names collide. Excel changes types. A third reader in the same truncate loop can break a ZIP that is already in the folder.

## Approach 3. One JSON file

You send one `AggregateIndicatorSubmission` file. The national importer already reads it on branch `cursor/aggregate-ingest-mvp-9630`.

### What you build

You build one export query or a small script. The script reads `ehr.monthly_indicators`. It writes one JSON file. It puts that file in the same SFTP folder.

You do not write 12 views. You do not write `orgunit.csv`. You do not write `metadata.json`. You send `orgUnit.parents` when the clinic is new. The importer creates the national org units.

### Data you need

You need the monthly counts you already store. You need a national facility id, or a mapped code, or a facility name that matches one national name. You need the 19 public codes in `importer_scripts/import_versions/aggregate_json.py`.

### Exact steps

1. Ask the national operator for the facility id or the exact facility name.
2. Map your columns to the public codes.

```sql
SELECT
    i.htn_controlled       AS nb_patients_controlled,
    i.htn_uncontrolled     AS nb_patients_uncontrolled,
    i.htn_no_visit         AS nb_patients_no_visit,
    i.htn_visit_no_bp      AS nb_patients_visit_no_bp,
    i.htn_total            AS "heart360_patients_category.total_number_of_patients",
    i.htn_newly_registered AS nb_patients_newly_registered,
    i.htn_ltfu             AS "heart360_patients_category.nb_patients_lost_to_follow_up",
    i.htn_under_care       AS nb_patients_under_care,
    i.htn_new_this_month   AS nb_new_patients,
    i.dm_controlled        AS diabetes_controlled,
    i.dm_uncontrolled_mod  AS uncontrolled_moderate,
    i.dm_uncontrolled_high AS uncontrolled_high,
    i.dm_missed            AS missed_visit,
    i.dm_under_care        AS nb_dm_patients_under_care,
    i.dm_new_this_month    AS nb_new_dm_patients,
    i.dm_total             AS "heart360_dm_patients_catagory.total_number_of_patients",
    i.dm_ltfu              AS "heart360_dm_patients_catagory.nb_patients_lost_to_follow_up",
    i.dm_bp_140_90         AS bp_controlled_140_90,
    i.dm_bp_130_80         AS bp_controlled_130_80
FROM ehr.monthly_indicators i
WHERE i.facility_id = 3
  AND i.month_start = DATE '2026-09-01';
```

Use the table name only on `nb_patients_lost_to_follow_up` and `total_number_of_patients`. Those names exist on the hypertension table and on the diabetes table. The diabetes table name is `heart360_dm_patients_catagory`.

3. Write the JSON file. Omit a code that you do not have. Send zero only when the real count is zero. Do not send percentages.

```json
{
  "resourceType": "AggregateIndicatorSubmission",
  "identifier": { "system": "urn:hearts360:source-system", "value": "acme-ehr|2026-09" },
  "reporter": { "identifier": { "system": "urn:hearts360:vendor", "value": "acme-ehr" } },
  "period": { "start": "2026-09-01", "end": "2026-09-30" },
  "entries": [
    {
      "orgUnit": { "id": 3, "code": "H360-AUDIT-PHC", "display": "H360_AUDIT_PHC" },
      "indicators": [
        { "code": "nb_patients_controlled", "value": 50 },
        { "code": "nb_patients_uncontrolled", "value": 30 },
        { "code": "nb_patients_no_visit", "value": 10 },
        { "code": "nb_patients_visit_no_bp", "value": 10 },
        { "code": "heart360_patients_category.total_number_of_patients", "value": 120 },
        { "code": "nb_patients_newly_registered", "value": 10 },
        { "code": "heart360_patients_category.nb_patients_lost_to_follow_up", "value": 10 },
        { "code": "nb_patients_under_care", "value": 90 },
        { "code": "nb_new_patients", "value": 8 },
        { "code": "diabetes_controlled", "value": 40 },
        { "code": "uncontrolled_moderate", "value": 15 },
        { "code": "uncontrolled_high", "value": 5 },
        { "code": "missed_visit", "value": 10 },
        { "code": "nb_dm_patients_under_care", "value": 80 },
        { "code": "nb_new_dm_patients", "value": 6 },
        { "code": "heart360_dm_patients_catagory.total_number_of_patients", "value": 100 },
        { "code": "heart360_dm_patients_catagory.nb_patients_lost_to_follow_up", "value": 8 },
        { "code": "bp_controlled_140_90", "value": 24 },
        { "code": "bp_controlled_130_80", "value": 12 }
      ]
    }
  ]
}
```

Save the file as `acme-ehr-2026-09.json`.

4. Put the file in the same SFTP folder as the leaf ZIP files. Keep it there.
5. Ask the national operator to run the importer, or wait for the hourly job. Open the dashboards for July to September 2026.

To send more than one month in one file, put `period` on each entry. `period.start` selects the calendar month. A start date of 15 September is still September.

To correct a month, send the file again with the same `identifier.value`. The new counts replace the columns in the new file.

### National dashboard change

The path is already on this branch. `git diff --stat` against `feature/drug-stock-mvp` shows 32 files, 3355 insertions, and 65 deletions. Most of that is docs and fixtures.

| File | Role |
| --- | --- |
| `importer_scripts/import_versions/aggregate_json.py` | New. Registry, validation, and column writes. 19 public codes. |
| `importer_scripts/importer.py` | Accept `.json` next to `.zip`. |
| `pg_init_scripts/migrations/0.5.6_to_0.6.0.sql` | Mapping table, submission log, rejection log. |
| `importer_scripts/test_aggregate_scenarios.py` | Nine scenarios. The run rolls back. |

The Grafana dashboard JSON did not change. The ZIP reader did not change. The leaf exporter did not change.

The JSON path does not write the overdue tables. It creates org units from `orgUnit.display` and optional `orgUnit.parents`, using the same name, level, and parent key as the ZIP path. A folder that holds only JSON still clears all 12 reporting tables first. Overdue panels then go blank unless a ZIP stays in that folder.

### Time estimate

Count 2 to 4 working days for one junior developer.

Assumptions: the counts already exist. The national facility id or name is known. You can write JSON from SQL or from a short script. You test one month. A national operator is available for one review.

A later indicator is one new `{ "code", "value" }` pair. Senders that do not have the new count omit it.

### Risks

A facility that does not match is skipped. Read `heart360tk_reporting.external_aggregate_rejection_log`. Give each facility to one producer. A ZIP and a JSON for the same facility and month can collide.

## Comparison

Assumptions for the time column: one junior EHR developer, indicators already stored, 1 to 20 facilities, first test month, SQL and SFTP available, one national review.

| Topic | Approach 1. 13 CSVs | Approach 2. Master CSV | Approach 3. JSON |
| --- | --- | --- | --- |
| EHR development effort | High. Map 12 file shapes and the org tree. | Medium after the adapter exists. High if you wait for it. | Low. Map the counts you have into one list. |
| Time for the EHR | 8 to 12 working days. | 4 to 6 working days after the adapter exists. | 2 to 4 working days. |
| Time for the national node | 1 to 2 days of operations. No code. | 8 to 12 working days to write the adapter. | Already done on this branch. |
| Skills on the EHR side | SQL, exact CSV column order, ZIP, SFTP, org hierarchy. | SQL, wide CSV, empty-versus-zero rules. | SQL or a small script, JSON, SFTP. |
| Complexity | High. 13 files and positional `COPY`. | High. 42 cells and name collisions. | Low. 19 codes. Omit what you do not have. |
| Maintenance | Every new column changes a file position. Every EHR updates together. | The wide header and the adapter grow together. | One registry line. One optional JSON field. |
| Risks | Wrong column order writes the wrong number. A missing `orgunit.csv` clears the tables. | The adapter does not exist. Excel breaks the file. A third reader shares the truncate loop. | A new clinic without parents sits under `UNKNOWN (ehr-name)`. Overdue panels stay blank. |
| Missing counts | A missing CSV field shifts the row. | An empty cell can stay null. | Omit the code. The cell stays null. |
| Org tree | You send `orgunit.csv`. You can create national units. | You still need ids or a second file. | You send `orgUnit.parents`, or the importer fills `UNKNOWN (ehr-name)`. |
| Overdue panels | Filled if you send those three CSVs. | Filled only if those columns are in the row. | Blank until those codes join the registry. |
| File a person can check | 13 files. Hard to review. | One very wide row. | One short list. Easy to review. |
| Works today | Yes, if the ZIP is exact. | No. | Yes, on this branch. |

## Decision

Approach 3 is the easiest for the EHR to implement. The junior developer maps stored counts into one JSON file and puts that file in the folder they already use for ZIP files.

Approach 3 is also the best for the national dashboard to support across many EHR systems. One contract covers every sender that will not install the leaf. Partial counts are allowed. A new sender does not invent the org tree. The ZIP path stays for sites that already have it.

Use Approach 1 only when the site will install the leaf node, or when it already emits the HEARTS ZIP.

Do not build Approach 2 now. A wide Master CSV is the 12 views in one line. A lossless long file has 42 codes. The JSON path has 19 codes and copies some counts. Those are different contracts. Approach 2 adds a parser the national node does not need.

## Where the files live

- This comparison: `docs/compare-aggregate-ingest-approaches.md`
- Investigation report: `docs/central-aggregate-ingest-investigation.md`
- Vendor JSON contract: `docs/ehr-aggregate-indicator-requirements.md`
- Registry: `importer_scripts/import_versions/aggregate_json.py`
- ZIP import: `importer_scripts/import_versions/v1.py`
- Views: `pg_init_scripts/01_heart360_tables.sql`
- Code: [pull request 8](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8)
