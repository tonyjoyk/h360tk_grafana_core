---
name: HEARTS360 hypertension cascades
status: final
sources:
  - {planning_artifacts}/research/htn-cascade-2026-11-18/imports/HTN_Cascades_Design_Decisions.md
  - {planning_artifacts}/prds/prd-htn-cascade-2026-11-18/prd.md
  - {planning_artifacts}/ux-designs/ux-hearts360-mvp-2026-11-04/EXPERIENCE.md
created: 2026-11-18
updated: 2026-11-18
---

# Experience: hypertension cascades

## Where it is

- Dashboard: **Hypertension and Diabetes Program**. Tab: **Hypertension**. Row: **Overview indicators**. It is the first card.
- The card takes two of three columns. "Patients protected from heart attacks and strokes" is in the third column, as before.
- Direct link: `/d/heart360_showcase?var-org_unit=<id>&-dtab=Hypertension`

## How it works

1. The user opens the Hypertension tab.
2. The card uses the location from **Change location**.
3. The card uses the latest completed month, the same as the other Hypertension headlines.
4. The screening cascade shows counts from the start of the year to the end of that month.
5. The treatment cascade shows all registered patients at the end of that month.
6. The user selects a different location. Both halves change.

## States

| State | What the user sees |
|---|---|
| No access | "No data for this place." No numbers show. The query returns no row when `isAllowed` is not 1. |
| No screening data | Left half: "No screening data for this place and month." The right half still shows. |
| No population data | Right half: "No population data for this place, so there is no estimate." It still lists the three live counts. |
| Step bigger than the step before it | A grey line under the chart: "Raised BP (5,000) is bigger than Screened (4,000). Check the numbers." |
| Loading | "Loading the cascades…" |
| Phone | The halves stack. The screening chart scrolls sideways. |

## Text

- No panel title and no info icons. The panel description holds the definitions, the data sources and the example-data note.
- Screening subtitle (Indonesia): "Eligible adults (15+) in {place} screened and diagnosed, Jan to Oct 2026."
- Treatment subtitle: "Estimated adults (15+) in {place} with hypertension, as of Oct 2026."
- Screening labels (Indonesia): "Adults eligible for screening", "Adults screened", "Raised BP (140/90 or higher)", "Newly diagnosed with hypertension". "Given starter medicine" is hidden for now (owner, 2026-11-18).
- Treatment labels: "Estimated people with hypertension", "Cumulative registered patients", "Patients under care", "Patients with BP controlled".
- Status lines (screening only): "87% of target", "9% of screened", "7.9% of target".

## Customization

A developer changes the `COUNTRIES` entry in `dashboard_src/cascade/cascade.js`, then runs `scripts/build_cascade_panel.py`. The steps are in `docs/cascades.md`. There is no admin screen for this in the first version.
