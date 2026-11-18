---
name: HEARTS360 hypertension cascades
description: Visual rules for the cascade card on the Hypertension tab. They copy the approved HTML design. They do not add new styles.
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

## Layout

- One full-width card in the Overview indicators row holds two halves. A thin line separates them. The Grafana panel is the card, so the inner card has no second border.
- Left half: **Screening cascade**. Right half: **Treatment cascade**.
- Each half has these parts, from top to bottom:
  1. Title and an info icon.
  2. A grey period chip. Screening: "This year: Jan to Oct 2026". Treatment: "All registered patients, as of Oct 2026".
  3. A subtitle that names the base. Example: "Of **2,100,000 adults aged 15+**, how many reached each step this year."
  4. A bar chart, 210 px high, with a y-axis from 0% to 100%.
  5. Under each bar: the count (in the bar color), the step name and one or two small grey lines.
- A bar that is "set apart" has a dashed divider on its left and a hatched fill. Its grey line says why. Example: "From EHR, not CKG".
- Below 860 px width, the two halves go one above the other. The screening chart keeps a 420 px minimum width and scrolls sideways.

## Bars

- Bar height is the share of the first bar.
- The percent is inside the bar when the bar is 34 px high or more. When the bar is shorter, the percent goes above the bar.
- A bar above zero is never less than 5 px high.
- Corners: 2 px on bars, 6 px on the card.

## Targets

- A target is a dashed line in the bar color. A light tint fills the space up to the line.
- The label is above the line. Example: "Year target 46%". For the diagnosed bar: "Year goal 11%".
- The grey line under the count says how close the count is to the target. Example: "87% of year target".

## Text and numbers

- Font: the Grafana font. Numbers use tabular figures.
- Counts are 12 px when a chart has five bars or a count has 8 or more characters (for example 2,100,000). This stops overlap.
- Counts use a thousands comma: 2,100,000.
- Percent: whole number at 10% or more. One decimal below 10%.
- Use sentence case. Do not use em dashes.

## Do not

- Do not add colors.
- Do not stack two numbers in one bar.
- Do not show a zero when there is no data.
