---
name: Party mode. JSON org unit create
created: 2026-10-26
---

# Party mode: scope, gaps, and the execution plan

Personas: product, importer engineer, EHR vendor, district dashboard user, data steward.

The group first reviewed how ZIP creates org units. Then it decided what JSON should copy, what it should not copy, and what to build now.

## 1. What the ZIP path actually does

**Importer engineer.** The ZIP does not invent unknown parents. `orgunit.csv` is a dump of the leaf `org_units` table. The central importer upserts those rows in level order. If a child points at a parent that is not in the file, the import fails. If the file has one row and that row has no parent, that row becomes a root. It is not wrapped in unknown region and district nodes.

**Product.** The original guess was that a single org unit in the ZIP would create unknown parents. That guess describes leaf line-list ingest, not ZIP import. Leaf ingest writes `UNKNOWN` when the Facility column is empty. It skips a missing district. It uses `Demo Region` when the Region column is empty. That code is `inotify_scripts/ingest_file_h360tk.py`. It does not run on the central node.

**Data steward.** Copying the leaf `UNKNOWN` shortcut onto the national tree would be a mistake if every EHR shared one `UNKNOWN` node. Unrelated clinics would sit in one fake district.

**Locked fact.** JSON should copy ZIP identity rules: name, level, parent. JSON should not copy ZIP's "fail the file when a parent is missing", because a JSON entry is one clinic, not a full tree dump. JSON should not copy a global `UNKNOWN` string.

## 2. Scope debate

### Should JSON create clinics at all?

**Vendor.** Yes. We will not install a leaf node. Our sites are not in any ZIP. If you only match names, someone at the ministry types every clinic.

**Product.** Yes. The investigation already flagged this. This work is that flag.

**Steward.** Create, but match first. Do not duplicate a ZIP clinic.

Agreed. Create is in scope. Match stays first.

### Should the EHR send a full `orgunit.csv` inside the JSON?

**Engineer.** That is Option B. It is the closest copy of ZIP.

**Vendor.** We chose JSON to avoid thirteen CSVs. A second tree file puts that work back.

**Product.** Per-entry parents are enough. Repeat the region name on each clinic. That is cheaper than a second document type.

Agreed. No top-level tree array in this build.

### What if the EHR only sends the clinic name?

**Dashboard user.** I need a region and a district in Change location. A facility with no parent disappears from the usual drill-down.

**Steward.** Then invent parents, but label them with the EHR name. `UNKNOWN (infokes)` is a real node with an honest name. `UNKNOWN` alone is not.

**Engineer.** `upsert_org_unit_chain` can fill levels 1 and 2 with that label, then the clinic at level 3. The unique key keeps two EHRs apart.

**Vendor.** We will send real parents when we have them. The fallback lets a first test file land.

Agreed. Missing ancestors become `UNKNOWN ({source_key})`. Default clinic level is 3.

### What if they send better parents later?

**Engineer.** Upsert will not move the old clinic. A new parent means a new unique key, so a new clinic. The next snapshot writes counts to the new one. The old unknown clinic stays in `org_units` with no counts after truncate-and-reload.

**Steward.** Do not build merge in this feature. Tell vendors to send real parents on the first file.

**Product.** Accept the leftover node. ZIP also never deletes org units.

Agreed. No merge. Document the leftover.

### Can JSON pick the central id?

**Engineer.** No. ZIP already remaps leaf ids. Central `id` is serial. A JSON `id` that does not exist is ignored, then display or parents are used.

Agreed.

### Does ZIP import change?

**Engineer.** No. Mixing unknown-parent logic into `import_org_units` would change leaf ZIP behaviour.

Agreed. JSON only.

## 3. Things that were easy to miss

The group listed gaps, then kept or cut them.

| Gap | Decision |
| --- | --- |
| Unique display match must run before unknown-parent create, or `H360_AUDIT_PHC` grows a parallel clinic. | Keep match-before-create. |
| Two clinics can share a name under different districts. Unique display match cannot disambiguate them. | When `parents` is sent, skip unique-name match and upsert the chain. |
| `org_unit_lineage` might need a refresh. | It is a view. No refresh. |
| Grafana dashboard JSON might need new variables. | No. The tree reads `org_units`. |
| `partial_reject` today expects an unknown clinic to be skipped. | Update the fixture. A display name now creates. Keep a row with no display as the reject case. |
| Truncate of reporting tables does not remove org units. | Same as ZIP. Leave them. |
| Source key used in the unknown label must be the stable reporter value, not the file name. | Use the same `source_key` the importer already extracts from `reporter.identifier.value`. |
| A vendor sends `level: 1` for a clinic. | Honour the level. Do not force 3 when they sent it. Default 3 only when level is omitted. |
| HTTP API from the old JSON PRD. | Out of scope. Folder drop stays. |
| Clinic merge UI. | Out of scope. |

## 4. Locked strategy

1. Keep ZIP import as it is.
2. Extend JSON resolve in `aggregate_json.py`.
3. Reuse `upsert_org_unit_chain`. One writer into `org_units`.
4. Match by id, mapped code, then parent chain, then unique display, then create with source-scoped unknown ancestors.
5. Do not let JSON choose serial ids.
6. Update vendor docs in Simplified Technical English.
7. Prove with scenario tests against Postgres, including two source keys and an idempotent replay.

## 5. Execution plan

1. Write this PRD, UX, architecture, and epics. Done in this folder.
2. Change `_resolve_org_unit_id` and add chain helpers in `aggregate_json.py`.
3. Add fixtures and scenario functions. Update `scenario_partial`.
4. Update vendor docs and the investigation flag.
5. Run `test_aggregate_scenarios.py` in the importer image.
6. Open a pull request against `cursor/aggregate-ingest-mvp-9630`.
