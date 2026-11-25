---
name: HEARTS360 hypertension cascades
description: Visual rules for the compact cascade card on the Hypertension tab (2 of 3 columns). Colors and bars from the approved HTML design; hierarchy from the hearts360.org reference and the UX audit.
status: final
sources:
  - {planning_artifacts}/research/htn-cascade-2026-11-18/imports/HTN_Cascades_Indonesia_India_Ethiopia.html
  - {planning_artifacts}/research/htn-cascade-2026-11-18/imports/HTN_Cascades_Design_Decisions.md
  - {planning_artifacts}/prds/prd-htn-cascade-2026-11-18/prd.md
created: 2026-11-18
updated: 2026-11-18
colors:
  base: '#e3e7ec'
  base-ink: '#5e6875'
  screened: '#5f5bd4'
  screened-tint: '#e6e5f9'
  raised: '#c9525c'
  facility-step: '#2f9aa8'
  diagnosed: '#2f7bdb'
  diagnosed-tint: '#dde9f9'
  registered: '#2f7bdb'
  under-care: '#a830d6'
  controlled: '#55a93f'
  ink: '#16202b'
  ink-2: '#4a5562'
  ink-3: '#646e7a'
  line: '#e6e9ee'
---

# Design: hypertension cascades

**Source of truth:** `HTN_Cascades_Indonesia_India_Ethiopia.html`. When this file and the HTML file are different, the HTML file is correct.

## Layout (compact card, 2026-11-18)

The owner asked for the card at two of three columns, with "Patients protected" in the third column. The UX audit (`ux-audit-2026-11-18.md`) set the rules below. The reference is the hearts360.org treatment cascade.

- One card, 16 of 24 grid columns, 9 rows high. No Grafana panel title: the two charts carry their own titles.
- Two charts of equal width, side by side, with a thin line between them. Below a 560 px panel width they stack.
- Each chart, from top to bottom:
  1. Title, 14 px medium weight, the same as Grafana's panel titles beside it. No info icon. The definitions are in the panel description.
  2. A subtitle of one sentence that names who is counted, the place and the period. Two lines are reserved, so both charts start at the same height.
  3. Bars, 120 px high. No y-axis. A thin dotted line between columns, the same in every country.
  4. Under each bar: the exact count (regular weight, 11 to 13 px, it shrinks with the card width), then the descriptive label in grey (11 px).
  5. Screening only: one status line in grey. "9% of screened" is the share of the step before. On a bar with a target, the line is the progress in the target color: "87% of target", "7.9% of goal".

## Bars

- The first bar is the denominator: grey, "100%" inside.
- Every other percent is a share of the first bar, 16 px bold, in the bar color. It is inside the bar when the bar is 28 px high or more, otherwise above the bar.
- When a target line is above a short bar, the percent sits above the line and its label.
- A bar above zero is at least 3 px high.
- Every bar looks the same in every country: solid fill, no hatching. One dotted line separates every column. A bar from another data system (Indonesia: newly diagnosed, from EHR; India: examined by MO) only loses its step rate; the reason is written in words (the country caveat, the panel description), not shown with a different look.

## Targets

- A target is a dashed line in the bar color, with a light tint up to the line. A small label sits just above the line, centered, in the target color: "Target = 46%" (10 px, regular weight). When a short bar's percent would touch the line, the percent sits above the label.
- The status line under the bar says the progress: "87% of target".

## Text and numbers

- Only the percents are bold. Counts are regular weight.
- Counts are exact, with a thousands comma: 2,100,000.
- Percent: whole number at 10% or more, one decimal below 10%.
- Use sentence case. Do not use em dashes.

## Do not

- Do not add colors.
- Do not stack two numbers in one bar.
- Do not show a zero when there is no data.

## Revision 2026-11-26 (owner)

Supersedes the target and step-rate rules above where they differ.

- **No target lines.** The screened target and the diagnosed target, their tint and their "x% of target" lines are removed.
- **Copy.** "Newly diagnosed with hypertension" is now "Diagnosed with hypertension this year".
- **Starter medicine (step 4) shows only when its indicator has data.** `panel.sql` returns `linked` as NULL until the real indicator exists, so the chart has four bars. Returning a value brings the fifth bar back with no other change.
- **Two percentages per bar.**
  - The big percent above or in the bar is always the share of the first bar (all eligible). It is unchanged.
  - Under each label from "Raised BP" on, a second line gives the share of the bar just before it, for example "**9%** of screened" or "**25%** of raised BP". With five bars it reads "of given starter medicine" on the last bar. The number is semibold in the bar's color; the words use the label color, at 12 px.
- **Bars fill their column edge to edge.** Separators are solid, light (`--csc-line`) and full height, including after the last column. Percents above short bars are left-aligned. This applies to both cascades.
- **Kept as today.** No "EHR data" divider and no other mockup extras. The treatment cascade keeps a single percent per bar.
