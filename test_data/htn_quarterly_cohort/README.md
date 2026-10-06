# Hypertension quarterly cohort fixture

Invented patients only. Ids `910001` through `910018`. Names are `Fixture Cohort NN`. No real patient data.

The follow-up window is the quarter after registration. Controlled is systolic under 140 and diastolic under 90. The latest visit in that quarter is the one that counts. A later visit with no complete blood pressure is `visited_no_bp`.

## Oracle

`Cohort Sample Facility` (`org_units.id` 127 after a load on this database). Latest closed registration quarter is called Q0. Q1 is the quarter before that.

| Quarter | Controlled | Uncontrolled | Missed visit | Visited, no BP | Cohort size |
|---|---:|---:|---:|---:|---:|
| Q0 | 4 | 2 | 2 | 4 | 12 |
| Q1 | 1 | 1 | 1 | 0 | 3 |
| Q0 minus 2, 3, and 4 quarters | 0 | 0 | 0 | 0 | 0 |

Percents for Q0 are 33.3, 16.7, 16.7, and 33.3. Percents for Q1 are 33.3, 33.3, 33.3, and 0. The Q1 percents sum to 99.9 because each third rounds to 33.3.

`Cohort Sample District` adds patient `910013` (controlled, Q0) to that facility. The district total for Q0 is 13 patients. `Cohort Empty Facility` is five zero rows.

Patients `910014` (registration quarter still open) and `910015` (diabetes only) are absent.

## Commands

From the repo root, with the `postgres` container running.

```sh
test_data/htn_quarterly_cohort/prove.sh
test_data/htn_quarterly_cohort/load_sample.sh
```

`prove.sh` rolls back. `load_sample.sh` keeps the patients and refreshes every reporting snapshot, including the monthly tables behind the overview charts.

Open Grafana on port 3000.

`http://localhost:3000/d/heart360_drilldown/hearts360-hypertension-dashboard?orgId=1&var-region=1&var-district=126&var-facility=127`

Login `admin` / `admin`. Select Cohort Sample Facility if the district id on your database is not 126. The Cohort report row is at the bottom of Hypertension Program.
