# Protocol adherence

**Most patients should be on a protocol step, and patients on a higher step should be more likely to be controlled.** This report shows where each patient sits on the treatment ladder at their latest visit, and how many are controlled at each step.

Where it is: the home dashboard's **Protocol adherence** tab, and the **Right medicines** tab in Reports.

Source it follows: the Excel protocol adherence table (`protocol_engine.py`, `write_protocol_report_table`). Same rows, same order, same columns. Cells the Excel tool leaves blank are blank here too.

## The ladder

| Step | Medicines |
| --- | --- |
| Step 1 | Amlodipine 5 mg |
| Step 2 | Amlodipine 10 mg |
| Step 3 | Amlodipine 10 mg + Lisinopril or Telmisartan (standard dose) |
| Step 4 | Amlodipine 10 mg + Lisinopril or Telmisartan (full dose) |
| Step 5 | Step 4 + Hydrochlorothiazide or Chlorthalidone 12.5 mg |
| Step 6 | Step 4 + Hydrochlorothiazide or Chlorthalidone 25 mg |

The labels come from the database (`h360_ladder_step_labels`), so a country can change the ladder without changing the report.

## Rows

Each patient counts once, in the group of the medicines at their latest visit up to the end of the reporting month.

- **Protocol medicines**: everyone on protocol medicines only. That is Steps 1 to 6 plus "Other mix".
- **On a protocol step**: Steps 1 to 6.
- **Step 1 to Step 6**: one row each.
- **Other mix of protocol medicines**: protocol medicines, but not in a ladder combination.
- **Medicine outside the protocol**: any medicine that is not on the protocol list.
- **No BP medicine at last visit**: no BP medicine, or no prescription.
- **Could not read the entry**: the medicine text could not be read.
- **All patients**.

## Who counts

Alive patients with diagnosis I10, in the place, with any visit up to the end of the month.

## Columns

| Column | Meaning |
| --- | --- |
| Number of patients | patients in the row |
| % of all patients | row / All patients |
| % of patients on any protocol step | row / On a protocol step (step rows only) |
| Patients counted | patients whose latest visit is in the 90 days to the month end, registered before those 90 days |
| Controlled | of those, BP under 140/90 at that visit |
| % controlled | Controlled / Patients counted |
| Cumulative control by step | running share of controlled patients, from Step 1 to this step |

The Right medicines tab can also count new patients. Use **Include new patients** at the top of the tab.

## Flags (Right medicines tab)

A facility is flagged when, among patients counted:

- 20% or more are off protocol (another mix, or a medicine outside the protocol); or
- 60% or more are on one medicine (Step 1 or Step 2).

No flag when fewer than 20 patients are counted. The headline "BP controlled" is the Hypertension tab's number, so the two always agree.

SQL: `report_adherence_steps`, `report_adherence_summary` and `report_adherence` (migrations `0.6.8_to_0.6.9` and `0.6.15_to_0.6.16`). Thresholds: `report_flag_thresholds`, report `adherence`.
