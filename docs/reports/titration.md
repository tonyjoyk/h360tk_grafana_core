# Titration

**When a patient's BP is high, the medicine should be stepped up. This report shows how often that happens.** A low rate means patients stay on the same treatment while their BP stays high.

Where it is: the home dashboard's **Titration** tab, and the **Stepping up** tab in Reports.

Source it follows: the Metabase titration report. A monthly table with one row per month, the place beside the average of all places, and a line chart of both.

## The rule

For each month, look at the 90 days that end on the last day of that month.

1. **High-BP visit**: a visit in those 90 days with BP 140/90 or above (systolic 140 or more, or diastolic 90 or more).
2. **Leave out visits that are too recent**: the visit is in the last 30 days before the newest data. There has not been time for a next visit.
3. **Leave out visits with no earlier prescription**: there is nothing to compare with.
4. **Stepped up**: the high-BP visit, or the patient's next visit within 30 days, has a stronger prescription than the visit before it. Stronger means a higher ladder step, or more BP medicines, or the same number at a higher dose.
5. **Titration rate** = stepped-up visits / high-BP visits that are left.

## What you see

- **Monthly table**: 9 months, oldest first. For each month: high-BP visits, stepped up, and the rate, for the place and for the average of all places. The newest month is the headline.
- **Line**: the place against the average, 0 to 100%.
- **Average of all places**: every place in the database pooled. Sum of stepped-up visits / sum of high-BP visits. This is what the Metabase report called the network average.

## Flag (Stepping up tab)

Flagged when the rate is under 40%. No flag when there are fewer than 10 high-BP visits.

When the facility's BP control is 60% or more and it is still flagged, the tab says **Control looks fine, check stock**. Good control can hide missing medicine.

SQL: `report_titration` (`0.6.9_to_0.6.10`) and `report_titration_monthly` (`0.6.15_to_0.6.16`). Thresholds: `report_flag_thresholds`, report `titration`.
