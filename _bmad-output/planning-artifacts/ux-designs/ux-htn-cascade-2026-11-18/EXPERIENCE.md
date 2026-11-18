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
- The card is full width. The "Patients protected from heart attacks and strokes" chart is below it.
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

- Panel title: "Screening and treatment cascades".
- Screening info icon (Indonesia): "Steps 1 to 4 come from CKG. Diagnosed counts new I10 registrations in puskesmas EHR data, a different system. Targets are for the full year."
- Treatment info icon: "Under care means at least one visit in the last 12 months. BP controlled means below 140/90 at the last visit."
- Footnote: "Screening counts this year only. Treatment counts every patient ever registered. Each chart reads against its own first bar. Population, prevalence and screening counts are example data, not program data."

## Customization

A developer changes the `COUNTRIES` entry in `dashboard_src/cascade/cascade.js`, then runs `scripts/build_cascade_panel.py`. The steps are in `docs/cascades.md`. There is no admin screen for this in the first version.
