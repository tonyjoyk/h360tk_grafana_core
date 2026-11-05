# Statins

**Patients with diabetes, or who had a heart attack or stroke, should be on a statin from age 40. This report shows how many are.**

Where it is: the home dashboard's **Statins** tab, and the **Statins** tab in Reports.

Source it follows: the Metabase statins report. A monthly table with the place beside the average of all places, and a line chart of both.

## The rule

A patient is **eligible** at the end of a month when all of these are true:

- alive;
- had a visit in the 12 months before the month end;
- aged 40 or older at the month end;
- has diabetes (diagnosis E11), or a heart attack or stroke recorded on or before the month end.

A patient is **on a statin** when their latest prescription up to the month end includes atorvastatin, simvastatin or rosuvastatin. An eligible patient with no prescription is not on a statin.

**% on a statin** = on a statin / eligible.

## What you see

- **Monthly table and line**: 9 months, the place against the average of all places (every place pooled).
- **Facilities, latest month** (home tab) and **Facility comparison** (Reports tab).
- **Patients to review** (Reports tab, at a facility only): eligible patients not on a statin, with age, why they are eligible and their last visit. Their number equals "Not on a statin" in the headline.

## Flag

Flagged when under 25% are on a statin. No flag when fewer than 10 patients are eligible.

The patient list is shown only in Grafana. The chat never sees it.

SQL: `report_statins`, `report_statins_patients` (`0.6.11_to_0.6.12`) and `report_statins_monthly` (`0.6.15_to_0.6.16`). Thresholds: `report_flag_thresholds`, report `statins`.
