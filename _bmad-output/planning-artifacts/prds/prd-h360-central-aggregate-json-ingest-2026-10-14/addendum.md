# Addendum: MVP JSON contract and validation rules

This addendum defines the payload contract for direct aggregate ingest.

## 1) Contract style

The payload is FHIR-inspired but not a Bundle.

- Uses `resourceType`, `identifier`, `period`, and coded indicators.
- Avoids nested FHIR resource graphs.
- Keeps one submission in one document.

## 2) Recommended MVP payload schema

```json
{
  "resourceType": "AggregateIndicatorSubmission",
  "identifier": {
    "system": "urn:hearts360:source-system",
    "value": "acme-ehr|mw|2026-09"
  },
  "status": "final",
  "reportedAt": "2026-10-02T12:15:00Z",
  "reporter": {
    "identifier": {
      "system": "urn:hearts360:vendor",
      "value": "acme-ehr"
    },
    "display": "Acme EHR Malawi"
  },
  "period": {
    "start": "2026-09-01",
    "end": "2026-09-30"
  },
  "entries": [
    {
      "orgUnit": {
        "id": 412,
        "code": "MW-BLT-D01-F001",
        "display": "Ndirande Health Centre"
      },
      "indicators": [
        {
          "code": "bp_controlled",
          "value": 128
        },
        {
          "code": "bp_uncontrolled",
          "value": 34
        },
        {
          "code": "missed_visit",
          "value": 19
        }
      ],
      "extensions": {
        "denominator_under_care": 181
      }
    }
  ]
}
```

## 3) Required fields for MVP

Submission-level required fields.

- `resourceType`
- `identifier.system`
- `identifier.value`
- `status`
- `period.start`
- `period.end`
- `entries`

Entry-level required fields.

- `entries[].orgUnit`
- `entries[].indicators`

Indicator-level required fields.

- `entries[].indicators[].code`
- `entries[].indicators[].value`

## 4) Indicator code set

Core required for dashboard readiness.

- `bp_controlled`
- `bp_uncontrolled`
- `missed_visit`

Allowed optional examples.

- `under_care`
- `registered_total`
- `newly_registered`

Unknown codes are accepted as extension indicators if they pass base validation.

## 5) Validation rules

Hard validation.

1. Payload must parse as JSON object.
2. `resourceType` must be `AggregateIndicatorSubmission`.
3. `status` must be `final` or `amended`.
4. `period.start` and `period.end` must be valid ISO date.
5. Period must be one calendar month in MVP.
6. `entries` must contain at least one item.
7. Indicator `value` must be numeric and `>= 0`.

Row validation.

1. Org unit must resolve to one central `org_units.id`.
2. Duplicate indicator codes in one entry are rejected for that entry.
3. Core indicator rows with null values are rejected.

## 6) Fallback and mapping rules

### Org-unit resolution order

1. Use `entries[].orgUnit.id` when provided and valid.
2. Else resolve `entries[].orgUnit.code` via `external_org_unit_map`.
3. Else attempt exact name fallback from `entries[].orgUnit.display`.
4. If unresolved, reject row with `ORG_UNIT_UNRESOLVED`.

### Indicator code fallback

Normalize common aliases before validation.

- `controlled` -> `bp_controlled`
- `uncontrolled` -> `bp_uncontrolled`
- `no_visit_3m` -> `missed_visit`

Unmapped unknown codes are stored as optional indicators only.

### Submission idempotency key

Use normalized tuple:

`source_system + identifier.value + period.start + org_unit_id + indicator_code`

Upsert on that key for deterministic replay.

## 7) Partial acceptance behavior

- Valid rows are committed.
- Invalid rows are written to rejection table with reason code and source path.
- Submission status is:
  - `accepted` when no rejections
  - `partially_accepted` when mixed
  - `rejected` when zero valid rows

## 8) Minimal JSON Schema sketch

This sketch is intentionally small for MVP implementation.

```json
{
  "type": "object",
  "required": ["resourceType", "identifier", "status", "period", "entries"],
  "properties": {
    "resourceType": {"const": "AggregateIndicatorSubmission"},
    "status": {"enum": ["final", "amended"]},
    "entries": {
      "type": "array",
      "minItems": 1
    }
  }
}
```
