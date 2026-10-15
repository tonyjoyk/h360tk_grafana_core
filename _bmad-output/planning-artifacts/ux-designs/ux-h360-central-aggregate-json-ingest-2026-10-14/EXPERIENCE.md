---
name: HEARTS360 central aggregate JSON ingest
status: draft-for-implementation
created: 2026-10-14
updated: 2026-10-14
---

# Experience spine: vendor API and central admin flow

This artifact defines interaction behavior for the new direct aggregate ingest path.

## 1) Primary actors

- **Vendor integrator** submitting monthly aggregate indicator JSON.
- **Central admin** validating ingest outcomes and resolving rejects.

## 2) Experience goals

1. Vendor can integrate from any EHR middleware without ZIP export tooling.
2. Validation feedback is actionable by field path and reason code.
3. Central admin can trust partial acceptance without silent data loss.

## 3) Vendor API flow

### Flow A. First successful submit

1. Vendor prepares one monthly payload with entries for one or more org units.
2. Vendor posts payload with auth credential.
3. API returns submission result.
4. Vendor sees accepted and rejected counts.
5. Vendor stores returned submission reference for replay and support.

Expected response shape.

```json
{
  "submissionRef": "subm_2026_10_02_00017",
  "status": "partially_accepted",
  "acceptedRows": 89,
  "rejectedRows": 3,
  "errors": [
    {
      "path": "entries[4].orgUnit.code",
      "code": "ORG_UNIT_UNRESOLVED",
      "message": "No mapping for code MW-BLT-X99"
    }
  ]
}
```

### Flow B. Correction and replay

1. Vendor fixes only rejected rows.
2. Vendor resubmits with new `identifier.value` or amended status.
3. API upserts corrected rows.
4. Prior accepted rows remain intact.

## 4) Central admin flow

### Flow C. Daily ingest review

1. Open ingest run log view.
2. Filter by source and reporting month.
3. Inspect submissions marked `partially_accepted` or `rejected`.
4. Download or copy row-level error details.
5. Request vendor resubmission if needed.

### Flow D. Data confidence check

1. Query normalized indicator table for current month.
2. Validate presence of all three core indicators by org unit.
3. Confirm values changed after vendor correction run.

## 5) Behavior rules that matter to UX

- Unknown optional indicators do not block accepted core rows.
- Core indicator rows must pass strict validation.
- Missing org-unit mapping always yields explicit reject reason.
- API always returns machine-parseable reason codes.
- Idempotent resubmission does not duplicate rows.

## 6) Error language contract

Error copy must stay vendor-actionable.

- Include `path`.
- Include stable `code`.
- Include short plain message.

Recommended MVP reason codes.

- `JSON_INVALID`
- `SCHEMA_INVALID`
- `PERIOD_INVALID`
- `ORG_UNIT_UNRESOLVED`
- `INDICATOR_CODE_UNSUPPORTED`
- `INDICATOR_VALUE_INVALID`
- `DUPLICATE_INDICATOR_IN_ENTRY`

## 7) Non-goals for UX layer

- No vendor self-service mapping UI in MVP.
- No interactive payload builder.
- No full FHIR validation UI.
