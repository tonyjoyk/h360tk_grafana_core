# EHR Aggregate Indicator JSON Ingestion (MVP)

This MVP allows the central node importer to accept **direct aggregate indicator JSON files** in addition to the existing ZIP export flow.

## Goal

Make it simple for EHR vendors that already compute HEARTS indicators to send monthly aggregates without sending patient line lists.

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
        { "code": "bp_controlled", "value": 128 },
        { "code": "bp_uncontrolled", "value": 34 },
        { "code": "missed_visit", "value": 19 }
      ],
      "extensions": {
        "denominator_under_care": 181,
        "newly_registered": 12,
        "lost_to_follow_up": 15
      }
    }
  ]
}
```

## Supported indicator codes

- `bp_controlled`
- `bp_uncontrolled`
- `missed_visit`

Unknown indicator codes are ignored in MVP.

## Org unit resolution rules (in order)

1. `orgUnit.id` (central node org unit ID)
2. `orgUnit.code` mapped in `heart360tk_reporting.external_org_unit_mapping`
3. `orgUnit.display` (+ optional `orgUnit.level`) matched to central `org_units`

If org unit cannot be resolved, the entry is rejected and logged.

## Validation and ingestion behavior

- File-level validation:
  - `resourceType` must be `AggregateIndicatorSubmission`
  - `period.start` and `period.end` must be valid ISO dates
  - `entries` must be a non-empty array
- Row-level validation:
  - Rejects malformed entries and logs reason in `external_aggregate_rejection_log`
  - Accepts valid rows even if some rows in the same file fail

## How data is shown on dashboards

Accepted JSON aggregates are written into `heart360tk_reporting.heart360_patients_category` (same table already used by dashboard queries), so existing BP control, BP uncontrolled, and missed-visit panels can show these values without dashboard redesign.

The hypertension panels use this denominator:

`total patients - newly registered - lost to follow-up`

Send `extensions.denominator_under_care` when the EHR's under-care count is not exactly `bp_controlled + bp_uncontrolled + missed_visit`. If it is omitted, the importer uses that sum.

## Reload behavior

Each import run reads every `.json` and `.zip` file still in the import folder, clears the reporting snapshot, and loads the folder again.

- Keep the current month's JSON file in the folder. Removing it drops that source on the next run.
- To correct a month, replace the file and wait for the next import (or run the importer once).
- Entries for the same org unit inside one file are summed.
- If two files in the same run mention the same org unit and month, the later file replaces that row.

## Audit tables added

- `heart360tk_reporting.external_org_unit_mapping`
- `heart360tk_reporting.external_aggregate_submission_log`
- `heart360tk_reporting.external_aggregate_rejection_log`
