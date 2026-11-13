# Overdue calls

**Overdue patients should be called early, and called patients should come back. This report shows both.**

Where it is: the **Overdue calls** tab in Reports, and the **Overdue patients** section of the home dashboard's Hypertension tab.

Source it follows: the Overdue list (the same overdue rule), and the hearts360 overdue charts.

## The rules

- **Overdue at the start of the month**: alive, last visit more than 45 days before the 1st of the month, and not removed from the overdue list by a call since that visit. Same rule as the Overdue list. No diagnosis filter.
- **With a phone**: the phone number has 8 or more digits.
- **Called**: an overdue patient with a phone whose first call in the month was made in that month. "Pending to call" does not count as a call.
- **Called early**: the first call was within 14 days of the patient becoming overdue.
- **Came back within 30 days**: a visit within 30 days of that first call. The denominator is every patient called in the month, whatever the call outcome. Patients called late in the month may still come back; the tab shows how many are still open.
- **New patients not back**: first visit 90 to 179 days before the month end, and no visit in the 90 days after it.
- **Usable phone (new patients)**: 8 or more digits, and never marked "Wrong phone number".

## What you see (Reports tab)

- Headline: Called, Calls made early, Came back within 30 days, New patients not back.
- **Came back within 30 days, by when we called**: early calls against later calls.
- **What happened on the calls**: Agreed to visit, Call again later, Removed from list.
- **A plan you can do**: one nurse calls about 25 a week, so 100 in 4 weeks.
- **Facility comparison**, with a link to each facility's overdue list.

## Flags

- Called under 10% of overdue patients with a phone.
- Early calls under 50% of calls.
- Under 50% of new patients have a usable phone.

No flag with fewer than 10 overdue patients with a phone, or fewer than 10 new patients.

## The Hypertension tab's Overdue patients section

Three columns per month: **Overdue at the start of the month**, **Overdue patients called**, **Overdue patients that returned to care**. The first two use the same rules as above, from the same function, so they match the Reports tab.

**One difference to know:** the third column still counts a visit **within 15 days** of the call (the hearts360 0.3.9 chart, view `HEART360_OVERDUE_RETURNED_TO_CARE`). The Reports tab and the chat count **within 30 days**. For Oct-2026 at PHC-E both give 7 of 20, but earlier months differ. Moving the home row to 30 days needs a change to that reviewed row.

SQL: `report_calling` and `report_calling_return` (`0.6.15_to_0.6.16`), `report_new_patients` (`0.6.12_to_0.6.13`). Thresholds: `report_flag_thresholds`, reports `calling` and `new_patients`.
