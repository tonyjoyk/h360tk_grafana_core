# BP fudging (BP readings check)

**If many more readings fall at 130 to 139 than at 140 to 149, BP may be rounded down to just under 140.** This report compares the two bands, quarter by quarter.

Where it is: the home dashboard's **BP fudging** tab, and the **BP readings check** tab in Reports. The chat and the Start here grid use the same rule.

Source it follows: the BP Fudging PRD.

## The rule

1. Take every BP reading in a quarter. Use the systolic number (the top number).
2. Count readings of **130 to 139** and readings of **140 to 149**.
3. **Ratio** = readings of 130 to 139 / readings of 140 to 149, to 2 decimals.

| Ratio | Colour | Meaning |
| --- | --- | --- |
| under 1.8 | green | no sign |
| 1.8 or more | yellow | watch |
| 2.0 or more | red | check how BP is measured |
| fewer than 20 readings in the two bands | grey | too few to judge |

A facility with readings of 130 to 139 but none of 140 to 149 is red.

## Which quarters

- The tabs show the last 4 completed quarters up to the reporting month. For Oct-2026 that is Q4 2025 to Q3 2026.
- The flag, the Start here grid and the chat use the newest completed quarter. For Oct-2026 that is Q3 2026.
- The quarter in progress is left out.

A patient's readings count towards the place where the patient is registered.

## Second chart

**% of facilities with a ratio of 2.0 or more, by quarter.** Of the facilities in view with enough readings, the share that is red.

## How to read it

A red ratio is a reason to look, not proof. Some patients really are at 130 to 139. Next step: watch BP being measured on the next visit.

SQL: `report_fudging_quarterly` and `report_fudging_share` (`0.6.15_to_0.6.16`), `report_fudging` and `report_fudging_histogram` (`0.6.16_to_0.6.17`). Thresholds: `fudging.min_readings` 20, `fudging.warn_ratio` 1.8, `fudging.flag_ratio` 2.0.
