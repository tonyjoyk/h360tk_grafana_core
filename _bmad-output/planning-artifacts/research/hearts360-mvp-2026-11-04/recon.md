---
title: HEARTS360 MVP build, recon facts (2026-11-04)
status: final
---

# Recon facts

Facts observed in the repos on 2026-11-04 (IST night). Read with `imports/01-GOALS-hearts360-build.md` and `imports/02-CONTEXT-hearts360-build.md`. Decisions taken without the owner are in `../../../../ASSUMPTIONS.md` at the repo root.

## Access

| Repo | Reachable | Notes |
| --- | --- | --- |
| `simpledotorg/h360tk_grafana_core` | yes | `demo/cascade-cohort` tip `08a2894`, on `0.6.0`. Upstream also has `0.6.1`, `0.7.0`, `main`; none add migrations past `0.5.1_to_0.6.0`. |
| `tonyjoyk/h360tk_grafana_core` | yes, push | `feature/drug-stock-mvp` tip `4a3f900`, on `0.5.1`. |
| `tonyjoyk/rea` | yes | A general reverse-engineering toolkit (binaries, JS apps, Android, MCP). It holds no titration or adherence logic. |
| `tonyjoyk/protocol_adherance_report_tool` | **no** (not found / private) | Rules must come from the feature map in section 5 of the context file. |
| `tonyjoyk/hearts360ai` | **no** (not found / private) | Answer shape comes from section 8 of the context file. |
| Section 7 source docs (Jimma, Addis Ketema, Chattogram, cross-country findings, SQL library, Sylhet HTML) | **no** (never pushed) | Thresholds and evidence table in section 7 of the context file are the only copy. |

No `ANTHROPIC_API_KEY` or other Claude key is set on the build machine.

## Integration branch

`cursor/hearts360-mvp-7579` on the `tonyjoyk` fork = `upstream/demo/cascade-cohort` + merge of `feature/drug-stock-mvp` + merge of the BMAD install. Git merged both textually clean. Real conflicts are semantic:

- Fresh install runs `00_schemas.sql`, `01_heart360_tables.sql`, `02_load_data.sh` from `/docker-entrypoint-initdb.d`. On `0.6.0`, `01_heart360_tables.sql` is the full 0.6.0 schema (no `\ir`). Drug stock appends `\ir migrations/0.5.1_to_0.5.2.sql` … `0.5.5_to_0.5.6.sql` at its end. These run after the 0.6.0 schema, so the version names lie but the order works. Renumber onto `0.6.x`.
- Dashboards. `0.6.0` merged the HTN and DM dashboards into `heart360.hypertension-diabetes.program.json` (Grafana v2 schema, `spec.elements` + `spec.layout`, uid `heart360_showcase`). Drug stock is its own file `heart360.drug.stock.json`. Drug stock did not edit the HTN/DM file, so there is no JSON conflict, only nav links to add.
- PR 7 (HTN quarterly cohort on `0.5.0`) overlaps `43d62be`/`85e2664`. Keep the cascade branch's version. Do not merge PR 7.
- PR 5 (drug stock demo seed) deletes and inserts patient rows. Not merged.

## Stack

- `grafana/grafana:latest` (unpinned) + plugins `volkovlabs-table-panel`, `yesoreyeram-infinity-datasource`, `marcusolsson-dynamictext-panel` (Business Text), `volkovlabs-echarts-panel`, `equansdatahub-tree-panel` (drug stock).
- Postgres with `pg_cron`. Schemas `heart360tk_schema` (raw + views), `heart360tk_reporting` (materialised copies refreshed by cron). Roles: `heart360tk` (owner of both schemas), `heart360tk_cached` (reads reporting), `grafana` (Grafana's own DB).
- Run: `docker compose up -d --build`. Grafana on `:3000`, filebrowser upload on `:8080`, pgAdmin `:5050`.
- Demo data: `test_data/demo/build_demo_data.py` writes xlsx files that go in through the filebrowser upload and `inotify_scripts/ingest_file_h360tk.py`. About 8,000 patients over 6 PHCs through Oct 2026. Encounters carry BP only. **There is no medicine data anywhere in the schema.**

## Core tables (heart360tk_schema)

`org_units(id, name, level, parent_id)`, `patients(patient_id, patient_name, gender, phone_number, patient_status, registration_date, birth_date, death_date, org_unit_id)`, `patient_diagnoses(patient_id, diagnosis_code in I10|E11)`, `encounters(id, patient_id, encounter_date, org_unit_id)`, `blood_pressures(encounter_id, systolic_bp, diastolic_bp)`, `blood_sugars`, `scheduled_visits(patient_id, scheduled_date, org_unit_id)`, `call_results(patient_id, call_date, result_type, removed_reason, org_unit_id)`. Helpers: `org_unit_lineage`, descendant functions, `HEART360_*` views, `HEART360_OVERDUE_PATIENTS_CALLED`, `HEART360_OVERDUE_RETURNED_TO_CARE`.

## Security hole, as built

- `grafana_provisioning/datasources/heart360.yml`: `postgres-hypertension` connects as `heart360tk`, the owner role.
- The overdue list (`panel-ov-quick`, Business Text afterRender JS) builds `INSERT INTO call_results … ON CONFLICT DO UPDATE` in the browser and posts it to `/api/ds/query` against that datasource with the viewer's session. `panel-ov-1` (Business Table) has an Update SQL with the same insert.
- Access checks are `WHERE '${isAllowed}' = '1'`, filled in by the browser. A direct API call skips them.

## Design system

hearts360 tokens (from `docs/demo-screening-cascade.md`): controlled `#3bb231`, uncontrolled `#eeab00`, no visit `#ed6300`, 12-month LTFU `#ff3355`, under care `#b51bdc`, registrations `#007ee4`, estimated `#dae0e1`. Latest completed month for headlines, running month dashed. ECharts for trends with the shared `tip()` tooltip; Business Text (HTML/CSS, `renderMode: everyRow`) for cards and lists. Drug stock adds patient-day thresholds `#E02F44` / `#FF9830` / `#F2CC0C` / `#56A64B`, `?` missing, `—` unknown, `0` zero.

## Drug stock known bugs (from the context file, confirmed in code)

1. Latest wins is sheet row order, not `submitted_at` (`drug_stock/pull/pull.py`).
2. Real Form response sheet is wide; `pull.py` expects long rows.
3. No submitter identity, no history.
4. No per-user location scoping on the drug stock board.
5. Patient-days wrong when strength is blank; the All row reads too low.
