# Review: central aggregate JSON ingest

Date: 2026-10-15.

Reviewed the direct EHR aggregate path: `importer_scripts/import_versions/aggregate_json.py`, the importer folder loop, the vendor note, and the scenario tests.

Method. BMAD review lenses (adversarial, edge-case, verification) plus a three-voice pass: the EHR developer who writes the file, the district user who reads the dashboard, and the central operator who runs the importer. The feature map for driving this later is `.cursor/skills/verify-h360tk-grafana-core/features/`.

## What is working

The file lands in the same folder the central importer already watches. A leaf ZIP and an EHR JSON can both be there. The JSON writes the reporting tables the hypertension and diabetes dashboards already query, so no new dashboard was required.

A missing count stays null. A percentage code is ignored and the counts in the same entry are kept. An unknown facility is skipped and the rest of the file is saved. A later file for the same facility and month replaces the columns it sends. One file can carry several months by putting `period` on each entry.

`period.start` selects the calendar month. The dashboards are already one point per month, so a file sent daily, weekly, or monthly shows up as long as each entry is the full picture for that month.

The scenario tests cover counts only, a visit with no blood pressure, three months of registrations, diabetes fan-out, an unknown clinic, a percentage, a correction, and a negative value.

## What was unnecessary

The JSON used a second set of names (`bp_controlled`, `bs_controlled`, `missed_visit`) and a dictionary translated them into the toolkit columns. That translation did not change what was stored. It did create a clash: `missed_visit` in the file meant a hypertension patient with no visit, while `missed_visit` in the database means a diabetes patient with no blood sugar.

The `extensions` block invented `total_number_of_patients` by adding three other numbers. Nothing outside this branch sent that block. It was a private compatibility shim for the first sample.

## What stays

The registry stays. It is not a name translator. It is the allow-list, and it copies one count onto every column a current panel divides by.

- `nb_patients_under_care` fills `heart360_patients_under_care` and `heart360_patients_category`.
- `nb_dm_patients_under_care` fills `heart360_dm_patients_under_care`, the three blood-sugar denominator columns, and `heart360_dm_bp_control.dm_patients_under_care`.

Asking the EHR to repeat the same number five times would let the copies drift.

Two column names exist on both the hypertension table and the diabetes table: `nb_patients_lost_to_follow_up` and `total_number_of_patients`. Those codes include the table name. Every other code is the column name alone.

The folder snapshot stays. The next import reloads every JSON and ZIP still in the folder. That is the existing importer contract. Removing a month's file removes that month from the dashboard.

`period.end` is stored on the submission log and does not place the numbers. A range that crosses a month is stored under the start month. October needs an entry whose start falls in October.

## Actions taken

1. JSON codes are the toolkit column names, with the table name only where the column name collides.
2. The short aliases and the `extensions` total-invention are removed.
3. Fixtures, the vendor note, the checklist, and the technical note use the column names.
4. The vendor note no longer says the file must arrive once a month.

## Left as they are

The Grafana panels, the reporting-table refresh, and the ZIP line-list path are unchanged. This machine is not a central node, so turning the hourly line-list refresh back on would replace a JSON snapshot. That is an environment fact, not a defect in the file format.
