---
name: HEARTS360 JSON org unit create
type: architecture-spine
status: draft-for-implementation
created: 2026-10-26
updated: 2026-10-26
---

# Architecture spine: JSON org unit create

## 1. Current baseline

ZIP import creates org units. JSON import only matches them.

ZIP path:

1. Leaf exporter writes `orgunit.csv` from `heart360tk_schema.org_units`.
2. `ImportVersion1.import_zip` calls `BaseImportVersion.import_org_units`.
3. `import_org_units` upserts each CSV row with `heart360tk_schema.upsert_org_unit(name, level, parent_id)`.
4. Leaf ids map through `import_facility_mapping`. Reporting CSV `org_unit_id` values are remapped.

JSON path today:

1. `_resolve_org_unit_id` in `importer_scripts/import_versions/aggregate_json.py` tries `id`, then mapped `code`, then unique `display`.
2. A miss rejects the entry. Counts are not stored.

`org_unit_lineage` is a view. Grafana reads it. No rebuild step is required after an insert.

## 2. How the ZIP upsert actually works

`upsert_org_unit` inserts on the unique key and then selects the id.

- Root: unique on `(name, level)` where `parent_id` is null.
- Child: unique on `(name, level, parent_id)`.

`upsert_org_unit_chain(names[], levels[])` walks the list from the top. Each step uses the previous id as `parent_id`. That is the function leaf line-list ingest already calls. JSON create should call the same function so there is one writer into `org_units`.

ZIP import does not call the chain helper. It walks `orgunit.csv` itself because the CSV carries leaf ids that must land in `import_facility_mapping`. JSON has no leaf id. The chain helper is the right writer.

ZIP import does not create `UNKNOWN` parents. A missing parent in `orgunit.csv` fails the file.

## 3. Design options

### Option A. Per-entry parent chain, then `upsert_org_unit_chain`

The EHR puts `display`, `level`, and optional `parents` on each `orgUnit`. The importer builds a name list and calls `upsert_org_unit_chain`. Missing ancestor levels become `UNKNOWN ({source_key})`.

Pros.

- One extra field on the object vendors already send.
- Reuses the SQL the leaf already uses.
- Source-scoped unknown nodes do not merge vendors.
- Entries stay self-contained. One file can mix known clinics and new clinics.

Cons.

- The same region name is repeated on every entry.
- A later file with better parent names creates a second chain. It does not move the old clinic.

### Option B. Top-level `orgUnits` array that copies `orgunit.csv`

The JSON file gains a ZIP-shaped tree. Entries then point at those nodes by code.

Pros.

- Closest copy of the ZIP document.
- One place to describe the tree.

Cons.

- Vendors who chose JSON did so to avoid `orgunit.csv`.
- Two shapes in one file. Entries still need a clinic pointer.
- JSON would grow a second mapping table similar to `import_facility_mapping`.

### Decision

Choose Option A. Option B copies the ZIP document that vendors already declined. Graft from Option B: keep the unique key as name plus level plus parent, and keep match-before-create so a JSON file can still attach to a ZIP clinic.

## 4. Module map

All create policy lives in `importer_scripts/import_versions/aggregate_json.py`.

| Function | Job |
| --- | --- |
| `_resolve_org_unit_id` | Keep match-by-id and match-by-code. Call create when match fails and a display name is present. |
| `_parents_from_payload` | Read `orgUnit.parents`. Accept `display` or `name`, plus `level`. |
| `_chain_for_create` | Build `(names, levels)` from parents, default level 3, and `UNKNOWN ({source_key})` fillers. |
| `_upsert_org_unit_chain` | `SELECT heart360tk_schema.upsert_org_unit_chain(%s::varchar[], %s::integer[])`. |
| `_remember_code` | Unchanged. Call it after create. |

`importer.py` stays unchanged. File discovery, truncate, and ZIP import stay as they are.

## 5. Resolve algorithm

Input: `source_key`, `orgUnit` object.

1. If `id` is an integer and that row exists, remember code and return it.
2. If `code` maps for this `source_key`, return the mapped central id.
3. If `parents` is a non-empty list, build the chain from those parents plus `display`, upsert, remember code, return the leaf id.
4. If `display` matches exactly one `org_units` row, remember code and return it. If it matches several rows, reject with the current multiple-match reason.
5. If `display` is a non-empty string, build the chain with unknown fillers, upsert, remember code, return the leaf id.
6. Reject.

A non-existent `id` is ignored. The function continues. Central ids are serial. JSON cannot pick them.

## 6. Chain rules

Let `target_level` be `orgUnit.level` when it is an integer, else the maximum parent level plus one, else 3.

Let `named[level] = parent.display` for each valid parent. The clinic name is `orgUnit.display` at `target_level`.

For each level `L` from 1 to `target_level - 1`:

- If `named[L]` is set, use it.
- Else use `UNKNOWN ({source_key})`.

The clinic name is never replaced with unknown. No display means reject, not an unknown clinic.

Skip a parent whose level is not an integer, or whose display is empty, and write a rejection for that entry.

## 7. Data that does not change

- `org_units` columns stay `id, name, level, parent_id`.
- Unique indexes stay as they are.
- `external_org_unit_mapping` stays the JSON code map. ZIP keeps `import_facility_mapping`.
- Reporting upserts stay keyed by `(org_unit_id, ref_month)`.

## 8. Tests

Add fixtures under `test_data/aggregate_scenarios/`:

- `create_with_parents.json`. New region, district, and clinic. Assert three org units and the stored count.
- `create_without_parents.json`. New clinic only. Assert unknown ancestors use the source key, and the count is stored.
- `create_two_sources_unknown.json`. Two source keys, same clinic display, no parents. Assert two unknown regions.
- `create_idempotent.json`. Import twice. Assert one clinic id.

Change `partial_reject.json` / `scenario_partial`:

- `Unknown Clinic` with a display name now creates. Keep a second entry that still matches id 3.
- Add a third entry with no display and no id. That entry is still rejected.

Existing unique-name fixtures that point at `H360_AUDIT_PHC` must keep matching the seeded clinic. They must not create a parallel unknown chain.

## 9. Docs to update after the code

- `docs/ehr-aggregate-indicator-requirements.md`
- `docs/ehr-aggregate-json-ingest-mvp.md`
- `docs/ehr-vendor-aggregate-json-checklist.md`
- `docs/central-aggregate-ingest-investigation.md` flag section
- `.cursor/skills/verify-h360tk-grafana-core/features/central-aggregate-json.md`

## 10. Risks

- A vendor later sends real parents. The importer creates a second clinic. Counts move to the new chain on the next snapshot. The old unknown clinic remains empty. Document this. Do not auto-merge.
- A JSON file that uses the same display name as a ZIP clinic, without id or code, attaches to the ZIP clinic when the name is unique. That is intended. Vendors must not send a different site under that name.
- `UNKNOWN ({source_key})` at two levels under the same parent is allowed. The unique key includes `level`.
