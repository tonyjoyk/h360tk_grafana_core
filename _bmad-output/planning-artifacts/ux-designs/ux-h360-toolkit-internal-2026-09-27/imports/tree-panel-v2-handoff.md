# Handoff: HEARTS360 Tree Panel V2 (org-unit UX) → drug stock Grafana

Stored 2026-09-27 for Drug Stock UX/architecture. Source: agent handoff + Tony screenshot.

## What this feature is
Grafana-native org-unit picker for multi-level facility hierarchy:
- 7 cascading dropdowns with no fixed level titles (place names only, hideLabel)
- Collapsible **Change location** row with equansdatahub-tree-panel (single-select, no panel title)
- All charts/tables filter on one hidden variable: `org_unit`
- Tabs share that selection
- Not a custom plugin we wrote — dashboard JSON + SQL + marketplace tree plugin

## Canonical artifact
| Item | Value |
|------|-------|
| Branch | `tony_treepanel` on simpledotorg/h360tk_grafana_core |
| File | `grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension-diabetes.treepanel.v2.json` |
| Title | Hypertension & Diabetes Program (Tree Panel V2) |
| UID | `heart360_showcase` |
| Format | Grafana V2 dashboard |

Ignore older `heart360.hypertension.treepanel.json` (Arnaud baseline).

## Plugin
`grafana cli plugins install equansdatahub-tree-panel` in `docker_build/heart360.grafana.docker`

Settings: dashboardVariableName=`org_unit`, multiSelect=false, label/id/parent columns name/id/parent_id, query `SELECT * FROM org_units`, panel title "", transparent.

## Data model
`org_units`: id, name, level (1=top), parent_id. Descendants via `get_descendant_ids`. Facts join `org_unit_id`.

## Variable pattern
ou_1…ou_7 cascading (hideLabel); org_unit = coalesce deepest non-0; tree writes same org_unit.

## Chart filter
org_unit_id IN (all org_units if empty OR get_descendant_ids(selected)).

## UX decisions to keep
- No fixed level labels
- Max 7 cascade slots
- Sentence-case open rows
- Empty org_unit = nationwide (no ::int crash)

## Drug stock adaptation
Copy variable block + Change location row + filter; new dashboard file; swap queries to stock metrics; keep Grafana-native.

## Screenshot
See `grafana-tree-panel-v2-screenshot.png` in this imports folder.
