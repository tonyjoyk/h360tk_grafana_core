# EHR Aggregate Indicator JSON Ingestion (MVP)

This MVP allows the central node importer to accept **direct aggregate indicator JSON files** in addition to the existing ZIP export flow.

## Goal

Make it simple for EHR vendors that already compute HEARTS indicators to send aggregate counts, at whatever frequency they already produce them, without sending patient line lists.

## Transport (MVP)

- Drop JSON files into the importer input folder (`IMPORT_FOLDER_PATH`) using the existing transport:
  - `IMPORT_PROTOCOL=sftp` (current default), or
  - `IMPORT_PROTOCOL=file` (local/demo mode)

## Required JSON Shape (FHIR-inspired, lightweight)

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

## Supported indicator codes

Send counts. A code ending in `_percent`, `_pct`, or `_rate` is ignored.

The code is the toolkit column name. A code includes the table name only when that column exists on both the hypertension and diabetes tables.

Hypertension:

- `nb_patients_controlled`, `nb_patients_uncontrolled`, `nb_patients_no_visit`, `nb_patients_visit_no_bp`
- `heart360_patients_category.nb_patients_lost_to_follow_up`, `heart360_patients_category.total_number_of_patients`
- `nb_patients_newly_registered`, `nb_patients_under_care`, `nb_new_patients`

Diabetes:

- `diabetes_controlled`, `uncontrolled_moderate`, `uncontrolled_high`, `missed_visit`
- `nb_dm_patients_under_care`, `nb_new_dm_patients`
- `heart360_dm_patients_catagory.total_number_of_patients`, `heart360_dm_patients_catagory.nb_patients_lost_to_follow_up`
- `bp_controlled_140_90`, `bp_controlled_130_80`

`nb_patients_under_care` is written to both under-care tables the hypertension dashboard reads. `nb_dm_patients_under_care` is copied onto the blood-sugar denominators and the diabetes blood-pressure denominator.

The plain-language list is in [Send your indicator counts](ehr-aggregate-indicator-requirements.md). Unknown codes are ignored. An entry can use its own `period` when one file covers more than one month. `period.start` selects the calendar month.

## Org unit resolution rules (in order)

1. `orgUnit.id` (central node org unit ID)
2. `orgUnit.code` mapped in `heart360tk_reporting.external_org_unit_mapping`
3. `orgUnit.display` (+ optional `orgUnit.level`) matched to central `org_units`

If org unit cannot be resolved, the entry is rejected and logged.

## Validation and ingestion behavior

- File-level validation:
  - `resourceType` must be `AggregateIndicatorSubmission`
  - `entries` must be a non-empty array
- Row-level validation:
  - Skips a bad entry and logs the reason in `external_aggregate_rejection_log`
  - Keeps the other entries in the same file
  - Stores only the codes that were sent. A missing code stays null. It is not stored as zero.

## How data is shown on dashboards

Each code is the reporting column the existing panel already reads. Hypertension percentages use `heart360_patients_category.total_number_of_patients - nb_patients_newly_registered - heart360_patients_category.nb_patients_lost_to_follow_up`. Diabetes blood sugar percentages use `nb_dm_patients_under_care`. The dashboard does that division. The file does not include the percentage.

## Reload behavior

Each import run reads every `.json` and `.zip` file still in the import folder, clears the reporting snapshot, and loads the folder again.

- Keep every month that should stay on the dashboard in the folder. Removing a file drops that source on the next run.
- To correct a month, replace the file and wait for the next import (or run the importer once).
- The same code for one facility and month inside one file is summed.
- If two files in the same run mention the same facility and month, the later file replaces the columns it sends.

## Audit tables added

- `heart360tk_reporting.external_org_unit_mapping`
- `heart360tk_reporting.external_aggregate_submission_log`
- `heart360tk_reporting.external_aggregate_rejection_log`
