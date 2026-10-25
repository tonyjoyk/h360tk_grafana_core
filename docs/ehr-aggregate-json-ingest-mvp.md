# EHR aggregate indicator JSON ingest (MVP)

The central importer accepts aggregate indicator JSON files. It also accepts the existing ZIP export files.

The vendor text is in [Send your indicator counts](ehr-aggregate-indicator-requirements.md).

## Goal

An EHR that already calculates HEARTS indicators can send aggregate counts. Send the file when the counts change. Do not send a patient line list.

## Transport

Put each JSON file in the importer input folder (`IMPORT_FOLDER_PATH`). Use the transport that the importer already uses:

- `IMPORT_PROTOCOL=sftp` is the default.
- `IMPORT_PROTOCOL=file` is for a local demo.

## JSON shape

The shape is small and follows FHIR field names.

```json
{
  "resourceType": "AggregateIndicatorSubmission",
  "identifier": { "system": "urn:hearts360:source-system", "value": "acme-ehr|mw|2026-09" },
  "status": "final",
  "reportedAt": "2026-10-02T12:15:00Z",
  "reporter": {
    "identifier": { "system": "urn:hearts360:vendor", "value": "acme-ehr" },
    "display": "Acme EHR Malawi"
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

## Indicator codes

Send counts. The importer ignores a code that ends with `_percent`, `_pct`, or `_rate`. The importer also ignores a code that contains `percentage`.

The code is the toolkit column name. Add the table name only when that column exists on the hypertension table and on the diabetes table.

Hypertension:

- `nb_patients_controlled`, `nb_patients_uncontrolled`, `nb_patients_no_visit`, `nb_patients_visit_no_bp`
- `heart360_patients_category.nb_patients_lost_to_follow_up`, `heart360_patients_category.total_number_of_patients`
- `nb_patients_newly_registered`, `nb_patients_under_care`, `nb_new_patients`

Diabetes:

- `diabetes_controlled`, `uncontrolled_moderate`, `uncontrolled_high`, `missed_visit`
- `nb_dm_patients_under_care`, `nb_new_dm_patients`
- `heart360_dm_patients_catagory.total_number_of_patients`, `heart360_dm_patients_catagory.nb_patients_lost_to_follow_up`
- `bp_controlled_140_90`, `bp_controlled_130_80`

The importer writes `nb_patients_under_care` to both hypertension under-care tables. The importer copies `nb_dm_patients_under_care` to the blood-sugar denominators and to the diabetes blood-pressure denominator.

The full list is in [Send your indicator counts](ehr-aggregate-indicator-requirements.md). The importer ignores an unknown code. Put `period` on an entry when one file has more than one month. `period.start` selects the calendar month.

## Facility match

The importer uses this order:

1. `orgUnit.id` is the central org unit id.
2. `orgUnit.code` must exist in `heart360tk_reporting.external_org_unit_mapping`.
3. `orgUnit.display` must match one name in `org_units`. You can also send `orgUnit.level`.

If the importer cannot match the facility, it rejects that entry and writes a log row.

## Validation

The file must have:

- `resourceType` set to `AggregateIndicatorSubmission`
- `entries` as an array with at least one entry

For each entry, the importer:

- Skips a bad entry and writes the reason in `external_aggregate_rejection_log`
- Keeps the other entries in the same file
- Stores only the codes that the file sends. A missing code stays null. The importer does not store zero for a missing code.

## Dashboards

Each code is a reporting column that a current panel already reads. Hypertension percentages use this denominator:

`heart360_patients_category.total_number_of_patients - nb_patients_newly_registered - heart360_patients_category.nb_patients_lost_to_follow_up`

Diabetes blood sugar percentages use `nb_dm_patients_under_care`. The dashboard divides. Do not put the percentage in the file.

## Reload

Each import reads every `.json` file and every `.zip` file that is still in the import folder. The import clears the reporting snapshot. Then it loads the folder again.

- Keep each month that must stay on the dashboard in the folder. If you remove a file, the next import removes that source.
- To correct a month, replace the file. Wait for the next import, or run the importer once.
- In one file, the importer adds values that have the same code, the same facility, and the same month.
- If two files in one run have the same facility and the same month, the later file replaces the columns that it sends.

## Log tables

- `heart360tk_reporting.external_org_unit_mapping`
- `heart360tk_reporting.external_aggregate_submission_log`
- `heart360tk_reporting.external_aggregate_rejection_log`
