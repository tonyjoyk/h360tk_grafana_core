# Ingesting aggregate data into the national dashboard

Investigation report, 23 October 2026.

This is the single report for the spike. It gathers the JSON investigation, the examples, the recommendation, and the open choices. A reader does not need the other notes to understand it.

The code and this report are on [pull request 8](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8), branch `cursor/aggregate-ingest-mvp-9630`.

## How to read this

| If you have | Read |
| --- | --- |
| Ten minutes, and you need the recommendation | [The decision](#the-decision), [The problem](#the-problem), [Options for the spike](#options-for-the-spike) |
| A Jira spike to scope | [Spike brief](#spike-brief) |
| An implementation to review | [From file to dashboard](#from-file-to-dashboard) through [Rules that are easy to get wrong](#rules-that-are-easy-to-get-wrong), then [Where the work lives](#where-the-work-lives) |

Words used in this report:

- **Leaf node.** A HEARTS toolkit install at a facility or district. It calculates indicators from the patient list and exports a ZIP.
- **Central node.** The national server. The importer reads one folder. Grafana shows the country.
- **Aggregate.** A count of patients. A patient line list is a different thing.
- **Registry.** The allow-list in the importer. A code is stored only when it is on this list. One code can fill more than one database column.
- **Snapshot.** Each import clears the reporting tables, then loads every valid file still in the folder.

## The decision

Use two readers and one way to write a count.

1. An EHR that installs the leaf node keeps sending the ZIP. That path already works.
2. An EHR that does not install the leaf node sends one JSON file into the same folder. This investigation built and tested that path.
3. The dashboard calculates every percentage. The EHR sends counts.
4. A CSV of the same counts is possible later. Build it only when a named EHR will send CSV and will not send JSON. The CSV parser must call the JSON importer. It must not have its own write path.
5. The national org tree stays owned by the central node. An external file matches a facility. It does not create the hierarchy.

That is option A in [Options for the spike](#options-for-the-spike). The spike should pressure-test it. The spike should not reopen the choices in [Already decided](#already-decided).

## The problem

The national hypertension dashboard and the national diabetes dashboard must show the same results the facility EHR shows.

Some facilities run the HEARTS toolkit. Their leaf node already calculates the indicators and drops a ZIP in the central importer folder.

Other facilities have their own EHR. They already calculate the indicators. They will not install the leaf node, and they will not send a patient line list.

The gap is the second group. They need a small file, a place to put it, and a guarantee that the national charts move.

## Three senders

| Sender | What they will do | What we accept today |
| --- | --- | --- |
| Leaf node is installed | The exporter writes a ZIP. SFTP or a local folder delivers it. | Yes. The ZIP reader is unchanged. |
| EHR will not install the leaf node, and can produce JSON | Drop one `.json` file in the same folder. | Yes. This investigation. |
| EHR will only produce a spreadsheet | Drop one `.csv` file of counts. | No. A `.csv` file is left in the folder. The shape we would accept is in [Option D](#option-d-add-the-long-csv-now). |

There is no HTTP endpoint. The transport is the one the importer already has.

- `IMPORT_PROTOCOL=sftp` is the production default.
- `IMPORT_PROTOCOL=file` is the local demo. The compose file mounts `./data/export` at `/export`.

## What the investigation proved

An EHR can send counts. The existing dashboards show them. No dashboard JSON was edited.

The proof has two parts.

- Nine automated scenarios pass and roll back, so they do not keep rows. A pass prints `9/9 scenarios passed`.
- A July–September 2026 demo file was loaded and opened in Grafana. Hypertension showed 50%, 30%, and 10%. Diabetes blood pressure showed 45% and 15%. Diabetes blood sugar showed 50%, 25%, and 13%. The numbers behind those cards are in [The September demo](#the-september-demo).

The file may arrive whenever the counts change. Daily, weekly, and monthly all work. Each entry must be the full picture for that facility and that calendar month. The importer does not add this week's file on top of last week's file.

## From file to dashboard

1. The EHR writes a JSON file. The type is `AggregateIndicatorSubmission`.
2. The file is placed in the importer folder.
3. The importer sees `.json` and `.zip` only. Any other name stays in the folder.
4. If at least one file is valid, the importer clears the reporting tables, then loads every valid file still in the folder. Files are loaded in name order.
5. For a JSON file, each indicator code is checked against the registry.
6. The count is written to the reporting column the panel already reads. A missing count stays empty. It is not stored as zero.
7. Grafana divides the counts and draws the percentage.

The panels that read these columns are:

- `grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension.program.json`
- `grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.diabetes.program.json`

## The JSON file

One file is one submission. One entry is one facility. Put `period` on an entry when the file holds more than one month.

The code is the toolkit column name. Add the table name only when that column exists on both the hypertension table and the diabetes table.

```json
{
  "resourceType": "AggregateIndicatorSubmission",
  "identifier": { "system": "urn:hearts360:source-system", "value": "demo-ehr|2026-09" },
  "status": "final",
  "reportedAt": "2026-10-02T12:15:00Z",
  "reporter": {
    "identifier": { "system": "urn:hearts360:vendor", "value": "demo-ehr" },
    "display": "Demo EHR"
  },
  "period": { "start": "2026-09-01", "end": "2026-09-30" },
  "entries": [
    {
      "orgUnit": { "id": 412, "code": "MW-BLT-D01-F001", "display": "Ndirande Health Centre" },
      "indicators": [
        { "code": "nb_patients_controlled", "value": 128 },
        { "code": "nb_patients_uncontrolled", "value": 34 },
        { "code": "nb_patients_no_visit", "value": 19 },
        { "code": "heart360_patients_category.total_number_of_patients", "value": 208 },
        { "code": "nb_patients_newly_registered", "value": 12 },
        { "code": "heart360_patients_category.nb_patients_lost_to_follow_up", "value": 15 }
      ]
    }
  ]
}
```

A second month in the same file looks like this. The entry period wins over the file period.

```json
{
  "period": { "start": "2026-07-01", "end": "2026-07-31" },
  "orgUnit": { "id": 3, "code": "H360-AUDIT-PHC", "display": "H360_AUDIT_PHC" },
  "indicators": [
    { "code": "nb_new_patients", "value": 5 },
    { "code": "nb_patients_under_care", "value": 70 }
  ]
}
```

Facility match, in this order:

1. `orgUnit.id` is the central org unit id.
2. `orgUnit.code` must already exist in `heart360tk_reporting.external_org_unit_mapping`.
3. `orgUnit.display` must match one name in `org_units`. `orgUnit.level` may be sent with the name.

If a facility cannot be matched, that entry is skipped and a row is written to the rejection log. The other facilities in the file are saved.

To correct a month, send the file again with the same `identifier.value`. The new counts replace the old counts for the columns in the new file. The importer does not add the two files together.

## Counts and percentages

Send any count you have. Send the counts a chart divides by when the percentage must appear. A chart with a numerator and no denominator shows the count and leaves the percentage blank.

### Hypertension

| Code | Meaning |
| --- | --- |
| `nb_patients_controlled` | Controlled blood pressure at the latest visit in the past 3 months |
| `nb_patients_uncontrolled` | Uncontrolled blood pressure at the latest visit in the past 3 months |
| `nb_patients_no_visit` | Under care, with no visit in the past 3 months |
| `nb_patients_visit_no_bp` | A visit in the past 3 months, and that visit has no blood pressure |
| `heart360_patients_category.nb_patients_lost_to_follow_up` | No visit in the past 12 months |
| `heart360_patients_category.total_number_of_patients` | All living patients registered with hypertension |
| `nb_patients_newly_registered` | Registered in the last 3 months. Used in the percentage denominator. |
| `nb_patients_under_care` | Registered, with a visit in the past 12 months |
| `nb_new_patients` | Registered in that one month. Used on the registrations chart. |

`nb_new_patients` and `nb_patients_newly_registered` are different counts. Do not swap them.

The controlled, uncontrolled, and no-visit percentages use this denominator:

`total_number_of_patients - nb_patients_newly_registered - nb_patients_lost_to_follow_up`

Those three percentages do not have to add up to 100. The gap is `nb_patients_visit_no_bp`.

`nb_patients_under_care` is written to two tables, because two panels divide by it: `heart360_patients_under_care` and `heart360_patients_category`.

### Diabetes

| Code | Meaning |
| --- | --- |
| `diabetes_controlled` | Controlled blood sugar at the latest visit in the past 3 months |
| `uncontrolled_moderate` | Uncontrolled blood sugar, moderate band |
| `uncontrolled_high` | Uncontrolled blood sugar, high band |
| `missed_visit` | Diabetes patients under care with no blood sugar record in the past 3 months |
| `nb_dm_patients_under_care` | Diabetes patients with a visit in the past 12 months |
| `nb_new_dm_patients` | Diabetes patients registered in that month |
| `heart360_dm_patients_catagory.total_number_of_patients` | All living patients registered with diabetes |
| `heart360_dm_patients_catagory.nb_patients_lost_to_follow_up` | Diabetes patients with no visit in the past 12 months |
| `bp_controlled_140_90` | Blood pressure below 140/90, and not below 130/80 |
| `bp_controlled_130_80` | Blood pressure below 130/80 |

The table name is `heart360_dm_patients_catagory`. That spelling is the toolkit spelling.

Blood sugar percentages divide by `nb_dm_patients_under_care`. The importer copies that one count onto the under-care table, the three blood-sugar tables, and the diabetes blood-pressure table. The EHR sends it once.

The chart for blood pressure below 140/90 adds `bp_controlled_140_90` and `bp_controlled_130_80`. The chart for below 130/80 uses `bp_controlled_130_80` only. One of those counts may be omitted. The chart shows the count that was sent.

Lost to follow-up divides by `heart360_dm_patients_catagory.total_number_of_patients`.

### Two ways to send

Send the outcome counts when you have them: controlled, uncontrolled, no visit, lost to follow-up.

Send the building blocks when you have them: under care, total registered, newly registered, and registrations for each month.

Send both when you have both. Each chart uses the count it already reads.

## Rules that are easy to get wrong

These are the rules that change the national numbers if a sender misunderstands them.

| Rule | What happens |
| --- | --- |
| The folder is a snapshot | The next import reloads every `.json` and `.zip` still in the folder, after clearing the tables. Remove a file and that source disappears from the dashboard. |
| Each entry is a full month | Inside one file, the same code for the same facility and month is summed. A weekly increment would double. Send the month total. |
| A later file replaces columns | Across files, the later file replaces only the columns it sends. A column it omits keeps the value from the earlier file in that same run. |
| `period.start` selects the month | 15 September is September. `period.end` is stored on the submission log. It does not place the row. A range that crosses into October is stored as the start month only. October needs its own entry. |
| Percentages are ignored | A code ending in `_percent`, `_pct`, or `_rate`, or a code containing `percentage`, is ignored. Counts in the same entry are kept. |
| Unknown codes are ignored | A code that is not on the registry is ignored. The rest of the entry is kept. |
| Negative values are ignored | A negative value is ignored for that indicator. |
| Zero is a real zero | Omit a count you do not have. Send zero only when the real count is zero. |
| One facility, one producer | A ZIP inserts whole rows. JSON replaces columns. If both claim the same facility and month, the ZIP can fail the unique key on `(org_unit_id, ref_month)`, depending on file name order. Give each facility to one sender. |
| This demo machine is not a central node | The hourly job `refresh_reporting_tables_every_hour` rebuilds the reporting tables from the patient list. On a machine that is not a central node, that job would wipe a JSON snapshot. On a central node the leaf ZIP is the source, and this job stays off. |

Invalid files do not clear the tables. The clear runs only after at least one file passes validation. The clear is committed before the load loop. A file that then fails leaves the files loaded before it, and drops the files after it. Row-level JSON problems stay inside the file: a bad facility is skipped, and the good facilities are saved.

## What we removed

The first JSON draft used short names such as `bp_controlled` and `bs_controlled`, plus a dictionary that translated them into column names. That dictionary did not change what was stored. It did create a clash. In the file, `missed_visit` meant a hypertension patient with no visit. In the database, `missed_visit` means a diabetes patient with no blood sugar record.

The short names were removed. The public code is the column name. The registry stayed, because it is the allow-list and the fan-out, not a translator.

An `extensions` block that invented `total_number_of_patients` by adding other counts was also removed. The EHR sends `total_number_of_patients` itself when it has that count.

Older planning notes under `_bmad-output/planning-artifacts/prds/prd-h360-central-aggregate-json-ingest-2026-10-14/` still say `bp_controlled`. Do not copy names from those notes. The registry in `importer_scripts/import_versions/aggregate_json.py` is the list.

## Why the ZIP has many CSVs

The leaf ZIP is a database snapshot, not a form a person fills in.

The exporter runs `SELECT *` once per reporting table and writes one CSV per table, plus `orgunit.csv` and `metadata.json`. The default tables are:

- `heart360_patients_category`
- `heart360_patients_under_care`
- `heart360_patients_registered`
- `heart360_blood_sugar_controlled`
- `heart360_blood_sugar_severity`
- `heart360_blood_sugar_missed_visits`
- `heart360_dm_bp_control`
- `heart360_dm_patients_under_care`
- `heart360_overdue_start_of_month`
- `heart360_overdue_patients_called`
- `heart360_overdue_returned_to_care`
- `heart360_dm_patients_catagory`

The importer copies each CSV into the table with the same name. `org_unit_id` in those CSVs is the leaf id. `import_facility_mapping` turns it into the central id. `orgunit.csv` also merges the leaf hierarchy into the central org units.

That design was the right shortcut when the only sender was our own leaf. The dashboards already queried those tables, so the wire format could be the schema. There was nothing to translate.

It is the wrong file to hand to an EHR that refused the leaf node. A person would have to build twelve full table dumps and an org tree. The JSON file is the form for that person. The ZIP can stay ugly, because a program writes it and a program reads it.

The ZIP is also wider than today's JSON. The three overdue tables are not in the registry. A leaf that sent only today's JSON would leave the overdue panels blank. The JSON registry would have to grow before a leaf could drop the ZIP.

## Options for the spike

### Option A, recommended. Keep the ZIP. JSON is the file a person sends.

External EHRs drop `AggregateIndicatorSubmission` in the same folder. Installed leaves keep the ZIP. A later leaf release can emit the same JSON after the registry covers every column the ZIP carries, including overdue. CSV waits for a named sender, and then it is only a parser in front of the JSON importer.

| Pros | Cons |
| --- | --- |
| Installed sites keep working. | Two readers remain. |
| Vendors get one short file. | The ZIP still looks like a table dump if someone opens it. |
| Dashboards stay as they are. | Overdue panels still depend on the ZIP until those codes join the registry. |
| One write path for counts. | |

### Option B. The leaf switches to JSON, then the ZIP is retired.

The exporter writes the same JSON. `orgunit.csv` is replaced by a separate hierarchy feed. The registry grows to every column the ZIP carries today.

| Pros | Cons |
| --- | --- |
| One document for the vendor and the leaf. | Every deployed leaf and every central move together. |
| The vendor note and the leaf note become one page. | Org-unit creation has to be redesigned first. |
| | Larger than the coverage problem this spike is solving. |

### Option C. Teach external EHRs to send the ZIP.

One importer. Vendors build the twelve CSVs, `orgunit.csv`, and `metadata.json`.

| Pros | Cons |
| --- | --- |
| The ZIP path already runs. | An EHR that refused the leaf will not hand-build a schema dump. |
| Full table fidelity, including overdue. | This fails the problem in [The problem](#the-problem). |

### Option D. Add the long CSV now.

A third reader for the same cells as the JSON. One row is one count. This file is not accepted today. It is here so the spike can judge the contract.

```csv
reporter,submission_id,period_start,period_end,org_unit_id,org_unit_code,org_unit_display,code,value
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,nb_patients_controlled,120
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,nb_patients_uncontrolled,40
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,nb_patients_no_visit,20
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,nb_patients_under_care,180
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,nb_patients_newly_registered,14
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,heart360_patients_category.nb_patients_lost_to_follow_up,9
demo-ehr,demo-ehr|2026-09,2026-09-01,2026-09-30,1,DEMO-FAC-001,Demo Facility,heart360_patients_category.total_number_of_patients,203
```

| Pros | Cons |
| --- | --- |
| A spreadsheet can be produced without a JSON developer. | A third public contract. |
| The same codes, the same month rule, the same facility match. | Excel files bring a title row, a `;` delimiter, `50%`, and `1,208`. Those must be rejected, not guessed. |
| | Another file in a folder that clears the national snapshot before it loads. |
| | Do this when a sender exists. Until then, a `.csv` in the folder stays ignored. |

Wide sheets, friendly headers such as "BP controlled", and `.xlsx` stay out. Friendly headers would bring back the alias list this investigation removed.

## Spike brief

The spike answers one question. What is the smallest set of ingest paths that lets every EHR reach the national dashboard, whether or not it installs the leaf node?

### Already decided

Treat these as fixed unless the spike finds a defect in the running code.

- The EHR sends counts. The dashboard calculates percentages.
- A missing count stays empty. Zero means the count is zero.
- Public codes are the toolkit column names. Colliding names include the table name.
- The registry stays. It is the allow-list and the fan-out.
- The EHR does not repeat one count once per table.
- A visit with no blood pressure is a real count: `nb_patients_visit_no_bp`.
- The file can arrive at any frequency. Each entry is the full month.
- `period.start` selects the calendar month.
- The folder is a snapshot. Files that must stay on the dashboard stay in the folder.
- There is no separate HTTP API in this version.
- The Grafana panels were not changed.
- Short names and the `extensions` total are not accepted.

### Still open

1. Confirm option A, or name the option that replaces it, using the pros and cons above.
2. Decide whether a future leaf release should emit the same JSON, and what must join the registry first. The overdue tables are the known gap.
3. Decide who creates org units. The recommendation is that the central node owns the tree, and an external file only matches a facility.
4. Decide the rule when two files claim the same facility and month. The recommendation is one producer per facility.
5. Decide whether any named EHR needs CSV in this spike. If none does, leave `.csv` unread.
6. Confirm the behaviour on a real central node, where the line-list refresh job is off and the folder is the source of the national snapshot.

### Done when

The spike returns a one-page choice, a yes or no on CSV, a yes or no on a future leaf JSON export, and a note on org-unit ownership. It points at this report and at [pull request 8](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8).

## The September demo

The demo file is `test_data/aggregate_scenarios/dashboard_demo.json`. The facility is org unit `3`, `H360_AUDIT_PHC`. July and August carry registrations and under-care only. September carries the outcome counts.

Hypertension denominator for September: `120 - 10 - 10 = 100`.

| Chart | Count | Percentage |
| --- | --- | --- |
| Blood pressure controlled | 50 | 50% |
| Blood pressure uncontrolled | 30 | 30% |
| No visit | 10 | 10% |
| Visit with no blood pressure | 10 | Shown as the gap. The three percentages above add up to 90. |
| Lost to follow-up | 10 of 120 registered | 10 / 120 |
| Under care, July / August / September | 70 / 80 / 90 | |
| New registrations, July / August / September | 5 / 7 / 8 | The chart accumulates these as 5, 12, 20. |

Diabetes denominator for September: `nb_dm_patients_under_care = 80`.

| Chart | Count | Percentage |
| --- | --- | --- |
| Blood sugar controlled | 40 | 50% |
| Blood sugar uncontrolled | 15 moderate + 5 high = 20 | 25% |
| Blood sugar missed | 10 | 10 / 80, shown on the dashboard as 13% |
| Blood pressure below 140/90 | 24 + 12 = 36 | 45% |
| Blood pressure below 130/80 | 12 | 15% |
| Diabetes under care, July / August / September | 70 / 80 / 80 | |
| New diabetes registrations, July / August / September | 5 / 7 / 6 | |
| Diabetes lost to follow-up | 8 of 100 | 8 / 100 |

The district table for `AUDIT_DIST` matches the September facility rollup. The region dropdown shows the org id `1`.

## Scenarios

Each file is under `test_data/aggregate_scenarios/`. The runner is `importer_scripts/test_aggregate_scenarios.py`. It deletes demo rows, imports, checks, and rolls back.

| File | What it proves |
| --- | --- |
| `counts_only.json` | A missing denominator stays blank. |
| `visit_without_bp.json` | Controlled, uncontrolled, and no visit use counts 50, 30, and 10. Ten visits have no blood pressure. The three percentages add up to 90. |
| `registrations_by_month.json` | One file has registrations and under care for July, August, and September. |
| `diabetes.json` | Blood sugar, diabetes blood pressure, under care, and lost to follow-up. |
| `dashboard_demo.json` | The July–September file behind the Grafana check. |
| `percent_sent.json` | A percentage code is ignored. The count in the same entry is kept. |
| `correction_first.json` and `correction_second.json` | The same file id replaces 120 with 100. |
| `partial_reject.json` | An unknown facility is skipped. The known facility is saved. |
| `negative_value.json` | A negative count is ignored. |
| `legacy_extensions.json` | Hypertension percentage inputs sent with column names, including the total of 203. No `extensions` object. |

Run them from the repository root:

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

## Where the work lives

Repository: [tonyjoyk/h360tk_grafana_core](https://github.com/tonyjoyk/h360tk_grafana_core)

Pull request: [Accept EHR indicator counts for the national dashboards](https://github.com/tonyjoyk/h360tk_grafana_core/pull/8)

Branch: [`cursor/aggregate-ingest-mvp-9630`](https://github.com/tonyjoyk/h360tk_grafana_core/tree/cursor/aggregate-ingest-mvp-9630). Base branch: `feature/drug-stock-mvp`.

| Need | File |
| --- | --- |
| This report | `docs/central-aggregate-ingest-investigation.md` |
| Vendor requirement, checklist, and file index | `docs/ehr-aggregate-indicator-requirements.md` |
| JSON shape, in shorter form | `docs/ehr-aggregate-json-ingest-mvp.md` |
| Vendor checklist | `docs/ehr-vendor-aggregate-json-checklist.md` |
| One-facility sample | `test_data/sample_aggregate_submission.json` |
| Registry and fan-out | `importer_scripts/import_versions/aggregate_json.py` |
| Folder loop, ZIP and JSON | `importer_scripts/importer.py` |
| Scenario runner | `importer_scripts/test_aggregate_scenarios.py` |
| Mapping table, submission log, rejection log | `pg_init_scripts/migrations/0.5.6_to_0.6.0.sql` |
| Leaf ZIP writer | `exporter_scripts/exporter.py` |
| Review of what stayed and what was removed | `_bmad-output/planning-artifacts/reviews/central-aggregate-json-2026-10-15.md` |

Log tables written by the JSON path:

- `heart360tk_reporting.external_org_unit_mapping`
- `heart360tk_reporting.external_aggregate_submission_log`
- `heart360tk_reporting.external_aggregate_rejection_log`
