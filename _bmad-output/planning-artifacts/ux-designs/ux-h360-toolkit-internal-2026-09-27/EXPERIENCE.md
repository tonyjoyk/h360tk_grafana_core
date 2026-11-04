---
name: HEARTS360 leaf Drug Stock
status: final
sources:
  - {planning_artifacts}/prds/prd-h360-toolkit-internal-2026-09-22/prd.md
  - {planning_artifacts}/prds/prd-h360-toolkit-internal-2026-09-22/addendum.md
  - {planning_artifacts}/ux-designs/ux-h360-toolkit-internal-2026-09-27/imports/tree-panel-v2-handoff.md
  - forged-idea hearts360-drug-stock
  - simple-server my_facilities/drug_stocks (semantics reference only)
created: 2026-09-27
updated: 2026-09-27
---

# HEARTS360 leaf Drug Stock — Experience Spine

> Draft for review (Fast path). Paired with `DESIGN.md`. Spines win on conflict with imports/mocks.

## Foundation

**Form-factor:** (1) Leaf **Grafana** web dashboard for programme managers; (2) **Google Form** (mobile/desktop browser) for facility staff stock entry.

**UI system:** Grafana + `equansdatahub-tree-panel`. Visual identity: `DESIGN.md`. Behavioral delta only below — do not re-specify Grafana globals.

**Product framing:** Internal India/IHCI prototype. Simple Drug Stock is a **report-semantics** reference; navigation is HEARTS360 Tree Panel V2 **Change location** only.

## Information Architecture

| Surface | Reached from | Purpose |
|---------|--------------|---------|
| Drug Stock dashboard (Leaf Grafana) | Grafana Home / HEARTS360 folder | View In-Stock + Patient-Days by facility under selected Org Unit + Reporting Month |
| Change location (row on dashboard) | Always on Drug Stock dashboard | Pick Org Unit (or nationwide); writes hidden `org_unit` |
| Reporting Month (variable) | Dashboard header variables | Select which month’s Latest Wins stock to view |
| Stock on hand table | Main panel under location | Category-grouped stock + Patient-Days; missing/zero/unknown |
| Google Form — Stock Submission | Shared link (ops distributes) | Facility staff submit In-Stock for their facility + month |

**Explicitly not surfaces in MVP:** cascading `ou_1…ou_7` bar; CSV / Download Report; Simple My Facilities filter chrome; Drug consumption tab; central dashboard; in-Grafana Business Forms entry.

→ Visual refs: `imports/grafana-tree-panel-v2-screenshot.png` (tree chrome; ignore cascades), Simple `drug_stocks` table markup (semantics only). Spine wins on conflict.

## Voice and Tone

Microcopy for Grafana panel titles, empty states, and Form labels. Brand posture in `DESIGN.md`.

| Do | Don't |
|----|-------|
| “Change location” | “Select administrative hierarchy level 3” |
| “Stock on hand” | “Inventory SKU matrix” |
| “Patient days” | “DoS / MoS jargon without label” |
| “No report for this month” / show `?` | Show `0` when nothing was submitted |
| Form: “Leave blank if unknown” | Force every drug field |

## Component Patterns

| Component | Use | Behavioral rules |
|-----------|-----|------------------|
| Change location tree | Org filter | Single-select; search filters nodes; expand/collapse; selection sets `org_unit`; clearing / default empty = **nationwide** (all org units). No multi-select. |
| Reporting Month variable | Time grain for stock | Changing month reloads table to Latest Wins for that month; does not clear org selection. |
| Drug Stock table | Primary report | Rows = facilities in scope of `org_unit` (+ optional All totals). Columns = drugs by category then Patient days. Sort by facility name default. |
| Patient-Days cell | Risk scan | Shows integer days; background from `{components.patient-days-cell.*}` thresholds. Tooltip may show formula inputs later — `[ASSUMPTION: tooltip optional in MVP; number + colour sufficient]`. |
| Missing / unknown / zero | Data honesty | See State Patterns. Never coerce blank → 0. |
| Google Form | Entry | Fields: facility, Reporting Month, In-Stock per tracked Protocol Drug (optional blanks). Success confirmation on submit. Resubmit allowed (Latest Wins). |

## State Patterns

| State | Surface | Treatment |
|-------|---------|-----------|
| Nationwide (empty `org_unit`) | Table | All in-scope facilities (prototype cohort); optional All totals row. |
| Org Unit selected | Table | That node + descendants only. |
| Month with data | Table | Latest Wins In-Stock + computed Patient-Days. |
| Facility: no Stock Submission for month | Row | Greyed; `?` in cells (`{components.missing-report-row}`). |
| Drug: blank In-Stock | Cell | `—` unknown (`{components.unknown-stock-cell}`). |
| Drug: explicit 0 | Cell | `0`. |
| Patient-Days &lt;30 / &lt;60 / &lt;90 / ≥90 | Cell | critical / low / watch / ok fills per `DESIGN.md`. |
| No facilities in selection | Table region | Short empty copy: “No facilities for this location.” |
| Form validation error | Google Form | Native required/number validation; stay on form. |
| Form success | Google Form | Confirmation; user may close or submit another month. |

## Interaction Primitives

**Grafana (Vikram)**

- Open Drug Stock dashboard → set Reporting Month → expand Change location if needed → search/select place → scan Patient-Days colours.
- Collapse Change location to reclaim vertical space after selecting.
- Standard Grafana time-range picker remains host chrome; stock month is **Reporting Month**, not the Grafana time picker. `[ASSUMPTION: document in panel description so users don’t confuse the two]`

**Banned in MVP**

- Cascading dropdown org picker on this dashboard.
- Download / CSV actions.
- Navigating Drug Stock via Simple-style district → hospital → UHC controls.

**Google Form (Ananya)**

- Linear fill: facility → month → drug quantities → submit.
- Blank allowed per drug; `0` means none on shelf.

## Accessibility Floor

Behavioral; contrast tokens in `DESIGN.md`.

- Tree and month controls operable by keyboard within Grafana’s capabilities; do not add hover-only filters.
- Patient-Days meaning not colour-only: retain numeric value in cell.
- `?` / `—` / `0` are distinct characters, not colour alone.
- Form labels associated with inputs; required facility + month.
- `[ASSUMPTION: WCAG AA via Grafana defaults; no custom a11y plugin work in prototype]`

## Inspiration & Anti-patterns

**Inspiration:** Simple Stock-on-hand table (category colspan headers, Patient days column, blank em dash, patient_days colour bands); HEARTS360 Tree Panel V2 Change location + search.

**Anti-patterns:** Dual tree + cascade controllers; treating Grafana time picker as Reporting Month; showing `0` for never-reported facilities; adding Drug consumption as a second tab in MVP.

## Key Flows

### Flow A — UJ-1 Ananya submits month-end stock

1. Ananya opens the shared Google Form on her phone.
2. Selects her facility and Reporting Month.
3. Enters In-Stock for drugs she counted; leaves unknowns blank; enters `0` where the shelf is empty.
4. Submits → sees confirmation.
5. **Climax:** She knows the report was received without logging into Grafana.
6. Edge: She resubmits later the same month → Latest Wins replaces prior values for those drugs.

### Flow B — UJ-2 Vikram reviews availability

1. Vikram opens leaf Grafana → Drug Stock dashboard.
2. Sets Reporting Month to last month.
3. Opens **Change location**, searches “PHC-A”, selects it (or leaves nationwide).
4. Scans category Patient-Days cells; red/orange rows draw the eye.
5. **Climax:** He can name which facilities are &lt;30 Patient-Days for CCB without a spreadsheet.
6. Edge: A facility shows `?` → he knows they have not reported, not that stock is zero.

## Open questions / assumptions for Tony

1. `[ASSUMPTION]` Drug Stock is a **standalone dashboard** (no HTN/DM/Overdue tabs on the same board).
2. `[ASSUMPTION]` Reporting Month offers ~6 recent months (Simple-like).
3. `[ASSUMPTION]` Nationwide shows an **All** totals row.
4. `[ASSUMPTION]` Patient-Days tooltip deferred; colour + number enough for MVP.
5. Community-facility exclusion still PRD assumption — UX does not add a size filter control in MVP.
6. Confirm Patient-Days bands: Simple’s &lt;30 / &lt;60 / &lt;90 / ≥90 (maps PRD’s three cut-points plus green ok).
