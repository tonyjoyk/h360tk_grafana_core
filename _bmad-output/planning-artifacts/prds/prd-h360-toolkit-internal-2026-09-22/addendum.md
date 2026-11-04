# Addendum — HEARTS360 leaf drug stock (not PRD body)

Technical and UX-transfer detail for architecture / UX skills. Not capability requirements.

Updated 2026-09-27 for party-mode MVP cut (tree-only org nav; no CSV in MVP).

## Recommended mechanism (from approved research)

```text
Facility staff → Google Form → Google Sheet (raw + optional curated tab)
  → ingest upsert → Postgres drug_stock_submission
  → SQL view: Latest Wins ⨝ Patients ⨝ coeff_config → Patient-Days
  → Leaf Grafana Postgres datasource → Table panel (thresholds)
```

- Do **not** use Google Sheets as Grafana system of record.
- Do **not** use Business Forms as v1 entry.
- Grafana Postgres user remains read-only for dashboards; writes only via ingest.

## Org-unit navigation (MVP)

Reuse Tree Panel V2 pattern from `tony_treepanel` / `heart360_showcase`:

- **Change location** row + `equansdatahub-tree-panel` → hidden `org_unit`
- Empty / All → nationwide (`get_descendant_ids` / all-org filter pattern from handoff)
- **Do not** ship top cascading `ou_1…ou_7` dropdowns in MVP (deferred; avoids dual-control overwrite)
- Copy variable + tree row + filter into a **new** Drug Stock dashboard file; do not mutate baseline HTN dashboards

Canonical handoff: UX imports `tree-panel-v2-handoff.md` + screenshot under  
`_bmad-output/planning-artifacts/ux-designs/ux-h360-toolkit-internal-2026-09-27/imports/`

## Simple → Grafana UX transfer notes

Match Simple Drug Stock **report semantics**, not Simple navigation DOM:

| Simple concept | Grafana-oriented expression (MVP) |
|----------------|-----------------------------------|
| My Facilities → Drug stock section | Dedicated dashboard UID + nav link |
| Category blocks CCB/ARB/Diuretic/Other | Table / row groups with category headers |
| Colour days remaining | Table field thresholds |
| `?` / `-` / `0` | Value mappings (required in MVP) |
| Month selector | Dashboard variable `reporting_month` |
| District / hospital / UHC chrome | **Do not port** — use Change Location tree |
| Download CSV | **Deferred** — not MVP |

## Patient-Days sketch (illustrative)

`Patient-Days = dose_normalized_stock / (Patients * LoadFactor * category_coeff)`

Example: `Amlo5 + (Amlo10 * 2)`. Coefficients from Simple PRD / IHCI ready reckoner as config.

## Rejected / deferred alternatives

| Option | Status |
|--------|--------|
| In-Grafana Business Forms entry | Rejected for v1 |
| Sheets datasource as SoT | Rejected |
| Cascading `ou_*` + tree dual control | Deferred (tree-only MVP) |
| CSV download | Deferred (was FR-8) |
| Full Simple port / central dashboard | Rejected |

## Downstream bindings

- **UX:** `bmad-ux` — Simple report semantics + tree-only nav + month; no CSV.
- **Architecture:** `bmad-architecture` — tables, ingest, coeff config, new dashboard JSON isolation.
- **Epics/Stories:** only after PRD + design + architecture approval.
