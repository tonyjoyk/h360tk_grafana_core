---
title: HEARTS360 JSON ingest creates org units like the ZIP path
status: draft-for-implementation
created: 2026-10-26
updated: 2026-10-26
---

# PRD: JSON org unit create on the central node

## 1. Why this feature now

JSON ingest already stores indicator counts. It only stores them when the facility already exists on the central node. EHRs that send JSON serve different locations from EHRs that send ZIP files. A JSON-only clinic never appears in a ZIP. If JSON cannot create that clinic, the counts never land.

The ZIP path already creates clinics. JSON must do the same job.

## 2. Review. How the ZIP creates org units

This section is the requirement source. The JSON path must copy this job, not the leaf line-list shortcuts.

### 2.1 Three different org-unit writers

People mix these three. They are not the same.

| Writer | When it runs | What it creates | What it does with missing parents |
| --- | --- | --- | --- |
| Leaf line-list ingest | A person uploads a patient CSV or Excel to a leaf node | A chain of names from the Region, District, Facility columns | Missing facility name becomes `UNKNOWN`. Missing district is skipped. Missing region becomes `Demo Region`. |
| Leaf exporter | The leaf export job runs | A ZIP that includes `orgunit.csv` | It dumps every row already in `org_units`. It does not invent parents. |
| Central ZIP importer | The central import job reads a ZIP | The same names, levels, and parents on the central `org_units` table | It does not invent parents. A child whose parent is missing from the CSV fails the import. |

The `UNKNOWN` label lives in leaf line-list ingest. It is not in the ZIP importer.

Code:

- Leaf line-list: `inotify_scripts/ingest_file_h360tk.py` (`HIERARCHY_LEVELS`, `build_hierarchy_from_row`, `execute_upsert_org_unit_chain`)
- Leaf exporter: `exporter_scripts/exporter.py` writes `SELECT id, name, level, parent_id FROM heart360tk_schema.org_units`
- Central ZIP importer: `importer_scripts/import_versions/base.py` `import_org_units`
- Database: `heart360tk_schema.upsert_org_unit` and `upsert_org_unit_chain` in `pg_init_scripts/01_heart360_tables.sql`

### 2.2 What `orgunit.csv` contains

The exporter writes every org unit in the leaf database, not only facilities.

```
id,name,level,parent_id
1,Malawi,1,
2,Blantyre,2,1
3,Ndirande Health Centre,3,2
```

`id` is the leaf id. The central node does not keep that id. It keeps the name, the level, and the parent.

### 2.3 What the central ZIP importer does, step by step

1. The ZIP must contain `orgunit.csv`. Import fails if the file is missing.
2. The importer deletes `import_facility_mapping` rows for that `source_key`.
3. It reads rows and sorts them by `level`, then by `id`. Parents load before children.
4. For each row it maps the leaf `parent_id` to the central parent id already stored in this run.
5. If the row has a `parent_id` and that parent was not in the file, the import raises an error. It does not create a placeholder parent.
6. If the row has an empty `parent_id`, the unit is a root. `parent_id` is null.
7. It calls `upsert_org_unit(name, level, central_parent_id)`.
8. `upsert_org_unit` inserts when the key is new. It returns the existing id when the key already exists.
9. The unique key for a root is `(name, level)`. The unique key for a child is `(name, level, parent_id)`.
10. It stores `leaf_id -> central_id` in `import_facility_mapping`. Reporting CSVs then remap `org_unit_id`.

The importer never deletes an org unit. A name that was created once stays in the tree.

### 2.4 What happens if the ZIP has only one org unit

This is the case the product question asked about.

- If that one row has an empty `parent_id`, the central node creates it as a root at the stated level. Grafana may then show a facility with no region and no district above it.
- If that one row has a `parent_id`, the import fails. The parent is not in the file. The importer does not mark the parent as unknown.

The leaf line-list path is the one that writes `UNKNOWN` for a missing facility name. The ZIP path does not copy that rule.

### 2.5 What Grafana needs

`org_unit_lineage` is a view. New org units appear in it as soon as they have a `parent_id`. Dashboards filter by region, district, and facility through `get_descendant_ids`. A facility at level 3 under a region and a district appears in the tree. A facility created as a root at level 3 does not sit under a region.

JSON create must therefore send or fill ancestor names. A clinic with no parent is not enough for the national tree.

## 3. Users and jobs

- **EHR vendor.** Send counts for clinics the national tree does not yet have. Send the clinic name, the level, and the parent names they know.
- **Central admin.** See new clinics in the Grafana location tree after the next import. Read the rejection log when a row still cannot become an org unit.
- **District user.** Open Change location and find the new clinic under its region and district, or under a labelled unknown parent when the EHR omitted those names.

## 4. Outcome

An EHR JSON file can create org units on the central node. It uses the same unique key as the ZIP path: name, level, and parent. Existing unique matches still win. A missing ancestor name becomes a source-scoped `UNKNOWN ({source_key})` node so the tree still has a region and a district. Two EHRs do not share one unknown parent.

## 5. In scope

- Create org units from JSON `orgUnit` when the clinic is not already on the central node.
- Accept optional parent names on each entry.
- Fill missing ancestor levels with `UNKNOWN ({source_key})`.
- Keep match-by-id, match-by-mapped-code, and unique display match before create.
- Reuse `upsert_org_unit` / `upsert_org_unit_chain`. Do not add a second write path into `org_units`.
- Remember `orgUnit.code` in `external_org_unit_mapping` after create.
- Update vendor docs and scenario tests.
- Keep ZIP import unchanged.

## 6. Out of scope

- Choosing the central numeric id from the JSON file. Central ids stay serial, as in ZIP import.
- Deleting org units.
- A master-data UI for merging duplicate clinics.
- HTTP ingest. Transport stays the existing import folder.
- Changing Grafana dashboard JSON.
- Leaf line-list ingest and the leaf exporter.

## 7. Functional requirements

### FR-1. Match first, then create

For each JSON entry, resolve the org unit in this order:

1. `orgUnit.id` when that id exists in `heart360tk_schema.org_units`.
2. `orgUnit.code` when `external_org_unit_mapping` already maps that code for this `source_key`.
3. If `orgUnit.parents` is a non-empty array, upsert the ancestor chain then the clinic.
4. If `orgUnit.display` matches exactly one existing org unit, use that org unit.
5. If `orgUnit.display` is present, create the clinic. Fill missing ancestor levels as specified in FR-3.
6. Otherwise reject the entry and write the rejection log. Other entries in the file still load.

### FR-2. Create uses name, level, and parent

Create calls `heart360tk_schema.upsert_org_unit_chain`. The chain is names from top to bottom with matching levels. A second file with the same names and parents returns the same central ids.

### FR-3. Missing ancestors are source-scoped unknown nodes

When the importer creates a clinic and an ancestor level between 1 and `level - 1` has no name, it inserts `UNKNOWN ({source_key})` at that level. `source_key` is the EHR reporter value. Infokes and Acme do not share one unknown region.

The importer does not use a bare `UNKNOWN` string. That would merge unrelated EHRs.

Default clinic level is 3 when `orgUnit.level` is omitted.

### FR-4. Parents in the JSON file

`orgUnit.parents` is optional. Each parent has `display` and `level`. `name` is accepted as an alias of `display`. Parents load from low level to high level, then the clinic.

Example:

```json
"orgUnit": {
  "code": "FACILITY-001",
  "display": "Example Health Centre",
  "level": 3,
  "parents": [
    { "display": "Example Region", "level": 1 },
    { "display": "Example District", "level": 2 }
  ]
}
```

### FR-5. Duplicate names with different parents

Two clinics can share a display name when their parents differ. The unique key is `(name, level, parent_id)`, the same as ZIP import. Unique display match in FR-1 step 4 only applies when `parents` is omitted.

### FR-6. Do not steal a ZIP clinic

If a JSON file matches an existing org unit by id, mapped code, or unique display, it must not create a second row. One producer should own one clinic. Vendor docs must say this.

### FR-7. Counts follow the resolved org unit

After resolve or create, indicator writes stay as they are today. Missing counts stay null.

### FR-8. ZIP import stays unchanged

`import_org_units` in `base.py` does not gain unknown-parent logic.

## 8. Non-functional requirements

- Idempotent. Replaying the same JSON file does not duplicate org units.
- Deterministic. The same names, levels, and parents resolve to the same ids.
- Vendor-actionable rejects. A row that still cannot resolve writes a plain reason.
- Small change. Org unit policy lives in `aggregate_json.py` and the existing SQL functions.

## 9. Success criteria

- A JSON file for a new clinic with region and district names creates three org units and stores the counts.
- A JSON file for a new clinic with only a display name creates `UNKNOWN ({source_key})` at the missing ancestor levels, then the clinic, then stores the counts.
- A JSON file for an existing unique clinic name does not create a duplicate.
- Two source keys that omit parents do not share an unknown region.
- Existing scenario tests still pass, with the unknown-clinic case updated to the new create rule.
- ZIP import behaviour is unchanged.

## 10. Already decided

- Transport stays the import folder. No new API.
- Dashboards keep calculating percentages from counts.
- Partial indicator counts stay allowed. A missing count stays null.
- JSON must create clinics. That flag in the investigation report is this feature.
