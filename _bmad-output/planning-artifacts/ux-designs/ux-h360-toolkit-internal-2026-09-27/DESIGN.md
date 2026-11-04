---
name: HEARTS360 leaf Drug Stock
description: Visual identity for the leaf Grafana Drug Stock prototype — Simple report semantics inside Grafana chrome, Tree Panel V2 location picker.
status: final
sources:
  - {planning_artifacts}/prds/prd-h360-toolkit-internal-2026-09-22/prd.md
  - {planning_artifacts}/prds/prd-h360-toolkit-internal-2026-09-22/addendum.md
  - {planning_artifacts}/ux-designs/ux-h360-toolkit-internal-2026-09-27/imports/tree-panel-v2-handoff.md
  - {planning_artifacts}/ux-designs/ux-h360-toolkit-internal-2026-09-27/imports/grafana-tree-panel-v2-screenshot.png
  - simple-server app/views/my_facilities/drug_stocks (report semantics reference only)
created: 2026-09-27
updated: 2026-09-27
colors:
  surface-dashboard: '#F4F5F5'
  surface-panel: '#FFFFFF'
  border-subtle: '#D8D9DA'
  text-primary: '#111217'
  text-muted: '#6E6E6E'
  grafana-accent: '#3D71D9'
  patient-days-critical: '#E02F44'
  patient-days-low: '#FF9830'
  patient-days-watch: '#F2CC0C'
  patient-days-ok: '#56A64B'
  cell-missing-bg: '#EFEFEF'
  cell-unknown: '#6E6E6E'
typography:
  dashboard-title:
    fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif'
    fontSize: '20px'
    fontWeight: '500'
  section-row:
    fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif'
    fontSize: '14px'
    fontWeight: '500'
  table-header:
    fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif'
    fontSize: '12px'
    fontWeight: '600'
  table-cell:
    fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif'
    fontSize: '13px'
    fontWeight: '400'
  microcopy:
    fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif'
    fontSize: '12px'
    fontWeight: '400'
rounded:
  sm: '2px'
  md: '4px'
  DEFAULT: '4px'
spacing:
  '1': '4px'
  '2': '8px'
  '3': '12px'
  '4': '16px'
  panel-gap: '8px'
  row-pad: '8px'
components:
  change-location-row:
    title-case: sentence
    chrome: '{colors.text-primary}'
    panel-title: ''
    transparent: true
  reporting-month-var:
    control: grafana-variable
  drug-stock-table:
    header: '{typography.table-header}'
    cell: '{typography.table-cell}'
    category-order: 'CCB → ARB → Diuretic → Other'
  patient-days-cell:
    critical: '{colors.patient-days-critical}'
    low: '{colors.patient-days-low}'
    watch: '{colors.patient-days-watch}'
    ok: '{colors.patient-days-ok}'
  missing-report-row:
    background: '{colors.cell-missing-bg}'
    glyph: '?'
  unknown-stock-cell:
    glyph: '—'
    color: '{colors.cell-unknown}'
  zero-stock-cell:
    glyph: '0'
---

# HEARTS360 leaf Drug Stock — Design Spine

> Draft for review (Fast path). Spines win on conflict with mocks/imports. UI system: **Grafana** + marketplace **equansdatahub-tree-panel**. Do not invent a parallel visual language.

## Brand & Style

Operational programme dashboard, not a marketing surface. Visual posture inherits **leaf HEARTS360 Grafana** (light theme, dense tables, sentence-case collapsible rows) as seen on Tree Panel V2. Drug Stock borrows **Simple’s stock-report meaning** (category blocks, patient-days colour bands, blank vs zero) without importing Simple’s Bootstrap chrome or district/hospital/UHC navigation.

Tone: calm, clinical, scannable. Colour is reserved for Patient-Days risk — not decoration.

## Colors

| Token | Role |
|-------|------|
| `{colors.surface-dashboard}` / `{colors.surface-panel}` | Grafana page vs panel fills — inherit host theme; tokens document intent. |
| `{colors.grafana-accent}` | Active tab underline / focus — match existing leaf dashboards. `[ASSUMPTION: use host Grafana blue; do not introduce a new brand blue]` |
| `{colors.patient-days-critical}` | Patient-Days **&lt; 30** (Simple `bg-red`). |
| `{colors.patient-days-low}` | Patient-Days **≥ 30 and &lt; 60** (Simple `bg-orange`). |
| `{colors.patient-days-watch}` | Patient-Days **≥ 60 and &lt; 90** (Simple `bg-yellow`). |
| `{colors.patient-days-ok}` | Patient-Days **≥ 90** (Simple `bg-green`). |
| `{colors.cell-missing-bg}` | Entire facility row when no Stock Submission for the Reporting Month. |
| `{colors.cell-unknown}` | Em dash / muted text when In-Stock left blank. |

Patient-Days colours apply as **colored cell background** (Grafana Table thresholds), matching Simple’s filled emphasis — not text-only.

## Typography

Inherit Grafana dashboard fonts. Roles:

- Dashboard title — `{typography.dashboard-title}`
- Collapsible row titles (e.g. “Change location”, “Stock on hand”) — `{typography.section-row}`, **sentence case**
- Table headers (drug name + dose, Patient days) — `{typography.table-header}`
- Numeric cells — `{typography.table-cell}`, tabular lining if available

Do not introduce display/serif faces for this prototype.

## Layout & Spacing

Vertical stack (top → bottom), same family as Tree Panel V2 screenshot:

1. Dashboard title + standard Grafana time/refresh chrome (host-owned; Drug Stock does not redesign it).
2. **Reporting Month** variable control (visible).
3. **Change location** collapsible row → search + tree (no top `ou_*` cascade row in MVP).
4. Optional single content tab or none — `[ASSUMPTION: Drug Stock is its own dashboard; no HTN/DM/Overdue tabs required on this board]`.
5. Collapsible **Stock on hand** (or equivalent) section containing the Drug Stock table.

Use `{spacing.panel-gap}` between rows; table stays full-width inside the panel. Prefer one primary table over card grids.

## Elevation & Depth

Flat Grafana panels. No marketing shadows. Collapsed/expanded rows use Grafana’s native row chrome only.

## Shapes

Corners `{rounded.sm}`–`{rounded.md}` via Grafana defaults. No pills for Patient-Days — rectangular threshold cells.

## Components

### Change location (tree)

- Row title: **Change location** (sentence case).
- Panel title empty; transparent panel — tree is the content.
- Search field above hierarchy; expand/collapse chevrons; place names only (no Region/District labels).
- Visual reference: `imports/grafana-tree-panel-v2-screenshot.png` (ignore the seven **All** cascades above the row — **out of MVP**).

### Reporting Month

- Standard Grafana dashboard variable dropdown showing end-of-month label (e.g. `Sep-2026` style). `[ASSUMPTION: last ~6 months like Simple, inclusive of current month if programme wants]`

### Drug Stock table

- Sticky facility column; category column groups in order **CCB → ARB → Diuretic → Other**; hide empty categories.
- Per drug: name + dose header; numeric In-Stock.
- Per category: **Patient days** summary column with threshold fill.
- Totals row (“All”) optional when nationwide — `[ASSUMPTION: include All totals row when org_unit empty]`.

### Cell glyphs (PRD FR-6)

| State | Appearance |
|-------|------------|
| Missing report | Greyed row; `?` in stock/patient-days cells |
| Unknown stock | `—` (em dash), muted — Simple blank pattern |
| Explicit zero | `0` |
| Patient-Days value | Number + threshold background |

## Do's and Don'ts

**Do**

- Reuse Tree Panel V2 Change location chrome and sentence-case rows.
- Keep Patient-Days colour bands aligned with Simple’s &lt;30 / &lt;60 / &lt;90 / ≥90 mapping.
- Distinguish `?` / `—` / `0` visually.

**Don’t**

- Ship the seven unlabeled cascade dropdowns on this dashboard in MVP.
- Port Simple’s district / hospital / UHC / Download Report controls.
- Use Patient-Days colours for non-risk decoration.
- Invent a custom org-unit widget when the tree plugin already exists.
