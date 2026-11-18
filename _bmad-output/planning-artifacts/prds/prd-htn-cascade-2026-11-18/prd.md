---
title: HEARTS360 hypertension cascades (screening and treatment), front-end build
status: final
created: 2026-11-18
updated: 2026-11-18
mode: bmad-prd Create, headless. Items we inferred have the tag [ASSUMPTION].
style: ASD-STE100 (about 80%). Short sentences. One instruction in one sentence. Active voice.
jira: H360-458, H360-463 (screening cascade); H360-399, H360-454 (treatment cascade). Owner Tony Joy.
inputs:
  - ../../research/htn-cascade-2026-11-18/imports/HTN_Cascades_Design_Decisions.md
  - ../../research/htn-cascade-2026-11-18/imports/HTN_Cascades_Indonesia_India_Ethiopia.html
  - ../../research/htn-cascade-2026-11-18/imports/HTN_Cascade_Data.md
  - ../prd-hearts360-mvp-2026-11-04/prd.md (numbering continues)
---

# PRD: hypertension cascades, front-end build

## 1. Purpose

This PRD tells the team how to put the new cascade design on the Hypertension tab. The branch is `cursor/hearts360-mvp-7579` on the tonyjoyk fork. The demo must show the design with Indonesia example data.

Tony owns the visual design and the front end. The design is complete. Gyan owns the backend data work in 0.8.0. After this build, Tony gives the branch to Gyan.

## 2. Problem

- The Hypertension tab shows an old screening-to-treatment cascade.
- The old cascade divides every location by one fixed number: 14,500 estimated patients.
- The old cascade does not use the new five-step standard.
- Reviewers cannot see the new design with live treatment numbers.

## 3. Goal

A reviewer opens the Hypertension tab and sees the new design. The design shows screening and treatment side by side, for the location that they select.

## 4. Users

- **Tony (design owner).** They check that the build matches the design.
- **Country reviewer (for example, the Indonesia team).** They read the chart and give feedback on names and steps.
- **Gyan (backend engineer).** They replace the temporary data with the real loads.

## 5. Scope

### In scope (front end)

- Replace the old cascade card on the Hypertension tab with the two new charts.
- The screening cascade, with five steps. Step 4 is optional.
- The treatment cascade, with four steps.
- Simple settings per country in the chart code: step names, targets, step 4 on or off.
- Temporary Indonesia data in a demo seed: adults aged 15+, prevalence and screening counts.
- The estimate of adults with hypertension, calculated from the example population and prevalence.

### Out of scope (Gyan's 0.8.0 stories, or later)

- Do not add a migration or a real table. Gyan owns the data loads: H360-496, H360-501, H360-503, H360-504, H360-505 and H360-498.
- Do not store targets in the database. H360-499 does that.
- Do not build India or Ethiopia data. Their settings are ready in the chart code.
- Do not build the "Enter data" panel or the Markdown file link from the HTML design. These are design tools only.
- Do not change the Diabetes tab or other Hypertension panels.
- Do not delete or change patient rows.

## 6. Functional requirements

Numbers continue from the MVP PRD (FR-49) and the review addendum (FR-88).

| ID | Priority | Requirement |
|---|---|---|
| FR-89 | P0 | The new cascade card replaces the old cascade card (`panel-stc`) in the Overview indicators row of the Hypertension tab. |
| FR-90 | P0 | The card shows the screening cascade on the left and the treatment cascade on the right. On a phone, the treatment cascade goes below. |
| FR-91 | P0 | The screening cascade has five slots: eligible, screened, raised BP, facility step and diagnosed. |
| FR-92 | P0 | Each bar shows its share of the first bar. The text under each count shows the step rate, or the progress against the target. |
| FR-93 | P0 | The screened bar shows the year target as a dashed line. The diagnosed bar shows the year goal as a dashed line. |
| FR-94 | P0 | Estimated adults with hypertension = population × prevalence. It is not a fixed number. |
| FR-95 | P0 | Registered, under care and BP controlled come from live patient data. |
| FR-96 | P0 | All numbers follow the selected location and the latest completed month. Screening counts are year to date. |
| FR-97 | P0 | Each country has one settings entry in the chart code: names, base, year start, target type, targets, step 4 and "set apart" labels. |
| FR-98 | P0 | The demo loads temporary Indonesia data. It matches the design example at national level. |
| FR-99 | P1 | When a step is bigger than the step before it, the card shows a grey warning. |
| FR-100 | P1 | When there is no screening or population data, the card says so. It does not show zero. |
| FR-101 | P1 | The card uses the same access rule as the other Hypertension panels. |

## 7. Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-16 | `scripts/check_htn_dm_untouched.py` exits 0. The new `panel-stc` content is a reviewed exception, by owner request on 2026-11-18. The layout and every other panel on the tab are unchanged. |
| NFR-17 | Seeds only add rows. `scripts/verify_seeds_insert_only.sh` exits 0. |
| NFR-18 | `scripts/build_cascade_panel.py --check` exits 0. |
| NFR-19 | No migration and no change to `pg_init_scripts/`. |
| NFR-20 | The card text has no banned words. `scripts/verify_banned_words.py` exits 0. |
| NFR-21 | The card says that population, prevalence and screening numbers are example data. |

## 8. Success check

- Tony opens the Hypertension tab. They compare the card with the HTML design. They find no difference in steps, names, colors or numbers at national level.
- Tony selects one location. The numbers change. The numbers stay in the correct order.

## 9. Assumptions

- [ASSUMPTION A-C1] Prevalence is 11.94% for adults aged 15+. We calculated it from the design example (250,800 ÷ 2,100,000). It is example data.
- [ASSUMPTION A-C2] The seed divides the national example numbers across the org units that have patients, by their share of patients.
- [ASSUMPTION A-C3] The latest completed month is October 2026. Screening counts grow evenly from January. Month m has m/10 of the October total.
- [ASSUMPTION A-C4] "Under care" means one or more visits in the last 12 months, as in the design info text.
- [ASSUMPTION A-C5] The "Patients protected from heart attacks and strokes" chart stays in the third column. The cascade card takes two of three columns, so the design is compact (UX audit 2026-11-18).

## 10. Open questions

| # | Question | Who answers | Blocks the demo? |
|---|---|---|---|
| Q-1 | Do we show "Given starter medicine" (step 4) for Indonesia? It is hidden for now. | Tony, Pusdatin | No |
| Q-2 | What is the real prevalence and population source for Indonesia? | Indonesia team, Gyan (H360-496, H360-504) | No |
| Q-3 | Does CKG report "Given starter medicine"? If not, set `showLinked: false`. | Pusdatin | No |
