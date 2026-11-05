# Drug stock

**Each facility should have enough BP medicine for its patients. This board shows how many days of medicine are left, and lets staff enter their stock count.**

Where it is: `/d/heart360_drug_stock`, linked as **Medicine stock** from the home dashboard and Reports.

Source it follows: the established drug stock report, which shows patient days per medicine group.

## Days of medicine left

For each facility and each medicine group (CCB, ARB, Diuretic):

**Patient days** = tablets in stock, weighted by strength / (registered patients × daily load × group share).

- Tablets count only for protocol medicines and strengths.
- Registered patients is the facility's cumulative registered patients.
- A group with any medicine not reported is shown as **not reported**, not as zero.

Colours: under 30 days red, 30 to 59 orange, 60 to 89 yellow, 90 or more green.

At a district, the All row pools the facilities that reported: the line above the table says how many reported, for example "1 of 1 facilities reported".

The **Tablets in stock** row (closed by default) shows the raw tablet counts.

The chat reads the same patient days. When a group is under 30 days, the chat says to check stock before stepping up medicine or calling patients.

## Enter stock

The form sits under the table. **Enter stock** at the top jumps to it.

- Pick the month: this month or one of the five before.
- Enter the tablets in stock for each protocol medicine and strength. Leave a box blank if not counted. Enter 0 if there is none.
- Whole numbers from 0 to 1,000,000 only.
- At a district, pick the facility first. Stock is entered per facility.
- **Save stock** sends the counts to h360-api, which checks again that the user can see that facility. The Grafana datasource stays read-only.
- The newest count wins. Every save is kept in a history table, with who saved it and when. The line under the button says "Last saved <date> by <user>".

After a save, the board moves to the saved month and shows the new days.

In this demo, 12 months of stock for the six PHCs are loaded from `test_data/demo/seeds/`. In a real install, stock comes from this form.

SQL: `drug_stock_patient_days`, `drug_stock_patient_days_all` (`0.6.6_to_0.6.7`), `save_drug_stock_entry` (`0.6.14_to_0.6.15`), `chat_drug_stock_gate` (`0.6.13_to_0.6.14`). Threshold: `chat.stock_days_below` 30.
