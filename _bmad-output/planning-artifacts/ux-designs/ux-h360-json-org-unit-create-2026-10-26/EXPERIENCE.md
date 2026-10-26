---
name: HEARTS360 JSON org unit create
status: draft-for-implementation
created: 2026-10-26
updated: 2026-10-26
---

# Experience notes: new clinics from a JSON file

This feature has almost no new screens. The vendor still drops a file. The district user still opens Grafana. The change is what they see in the location tree and in the rejection log.

## 1. Actors

- **Vendor integrator.** Builds the JSON file. Needs a clinic to appear without asking a national operator to type it by hand.
- **Central admin.** Checks that a new clinic landed in the tree, and that two EHRs did not create the same place twice.
- **District user.** Uses Change location. Expects a region, a district, and a facility, not a clinic floating at the top of the tree.

## 2. Experience goals

1. A new JSON clinic is selectable in Grafana after the next import.
2. A clinic with real parent names sits under those names.
3. A clinic with no parent names still has a region and a district, labelled so a person can see they are placeholders.
4. A vendor can tell from the rejection log why a row still did not become a clinic.

## 3. Vendor flow

### Flow A. First file for a new clinic, with parents

1. The vendor writes `orgUnit.display`, `orgUnit.level`, and `orgUnit.parents`.
2. They put the `.json` file in the national import folder.
3. They wait for the importer, or they ask the operator to run it.
4. They open Hypertension Program. They select the new region, district, and facility.
5. The counts they sent are on the cards that already exist.

### Flow B. First file for a new clinic, no parents

1. The vendor only has the clinic name.
2. They send `orgUnit.display` and omit `parents`.
3. After import, Change location shows a region named `UNKNOWN ({ehr-name})`, a district with the same pattern, and the clinic under that district.
4. The vendor can later send the same clinic with real parent names. That creates a second chain. Vendor docs must say they should send real parents on the first file when they have them.

### Flow C. Clinic already on the national tree

1. The vendor sends `orgUnit.id`, or a mapped `orgUnit.code`, or a display name that matches one existing clinic.
2. The importer does not create a second clinic.
3. The counts update the existing clinic.

### Flow D. Row still rejected

The importer still skips a row when there is no display, no existing id, and no mapped code. The rejection log reason must name that gap. The other clinics in the file still load.

## 4. What the district user sees

Grafana dashboards do not change. The location tree gains nodes.

| What the EHR sent | What Change location shows |
| --- | --- |
| Region, district, and facility names | Those three names, nested. |
| Facility name only | `UNKNOWN (ehr-name)` at region, `UNKNOWN (ehr-name)` at district, then the facility. |
| Existing national clinic | The clinic that was already there. |

A placeholder region is visible on purpose. It must not look like a real province. The `UNKNOWN (ehr-name)` label does that.

Percent cards still go blank when the EHR omitted a denominator count. Creating a clinic does not invent counts.

## 5. Admin checks

After the first JSON file from a new EHR:

1. Open Change location. Confirm the new clinic exists.
2. Confirm it sits under the names the vendor sent, or under `UNKNOWN ({source_key})`.
3. Confirm a second import of the same file did not add a second clinic with the same path.
4. Read `external_aggregate_rejection_log` for any entry that still failed.
5. Read `external_org_unit_mapping` if the vendor sent a `code`.

There is no mapping UI in this feature.

## 6. Copy

Vendor docs must say:

- Send the clinic name.
- Send region and district names when you have them.
- If you omit them, the tree shows `UNKNOWN (your-ehr-name)` above the clinic.
- Do not send a JSON clinic that a leaf ZIP already created. Match it by id, code, or exact unique name.

Rejection reasons stay short and literal:

- `orgUnit.display is required to create a clinic`
- `orgUnit.level must be an integer when provided`
- `orgUnit.parents entries must include display and level`

## 7. Non-goals for UX

- No clinic merge screen.
- No rename screen for unknown parents.
- No payload builder.
- No dashboard JSON edits.
