# Demo data

The demo is one upload file plus two seeds:

- `demo_generated.xlsx`: every patient, visit, BP reading and medicine. 7,200 made-up patients
  (`DEMO-00001` to `DEMO-07200`, named "Demo Patient 00001" and so on), 1,200 in each of PHC-A to
  PHC-F, with about 30,000 visits from 2025-01-02 to 2026-10-13. The newest visit is 2026-10-13,
  so the reports open on Oct-2026.
- `seeds/30_calls.sql`: call results for 2026-05 to 2026-10, with the return visits they cause.
- `seeds/40_drug_stock.sql`: drug stock for the six PHCs, 2025-11 to 2026-10 plus 2026-11.

`./scripts/demo_up.sh` loads the file into a new database, then runs the seeds. The seeds only
insert, and each runs once. `seeds/retired/` holds the seeds the file replaced; they do not run.

## The upload file

One row per visit. The columns are those of a PHC export plus `Medicines`:

`Registration Date`, `Patient ID`, `First Name`, `Middle Name`, `Last Name`, `Date of Birth`,
`Gender`, `Phone Number`, `Region`, `District`, `Facility`, `Sub Facility`, `Systolic`,
`Diastolic`, `Visit Time`, `Blood Sugar Type`, `Blood Sugar Value`, `Diagnosis 1`, `Diagnosis 2`,
`Medicines`.

`Medicines` holds the visit's prescription in the Obat format, for example
`Amlodipine 5 mg - 1 x 1 Tablet Sehari; Atorvastatin 20 mg - 1 x 1 Tablet Sehari`. The importer
also accepts the header `Obat` or `Prescription`. It stores the text for that visit (source
`upload`); a blank cell or a missing column stores nothing, and re-importing the same file changes
nothing. `python3 scripts/test_ingest_medicines.py` tests this.

## What each PHC shows (Oct-2026)

| PHC | Story |
| --- | --- |
| All | Medicines stepped up at about 46% of high-BP visits, every month of the history. About 31% of patients aged 40 or more with diabetes are on a statin. About 27% of new patients do not come back within 90 days. Control about 46-51%, under the 60% "high control" line. |
| PHC-B | Low CCB stock: about 63 days in Aug, 45 in Sep, 18 in Oct (drug stock seed). |
| PHC-C | About 56% of new patients have no phone number. |
| PHC-D | About 38% of new patients do not come back within 90 days. |
| PHC-E | Control about 75%, but readings bunch just under 140 from 2026-Q2 (130-139 against 140-149: about 2.2 in Q2, 2.45 in Q3), and medicines are stepped up at only about 28% of high-BP visits. |
| PHC-F | Statins for about 21% of eligible patients. Chlorthalidone 25 left blank on the Oct stock form. |

The targets are CLINICAL-RULES section 7 and the BP Fudging PRD's quarterly rule.
`./scripts/verify_seed_targets.sh` checks them against the running stack.

Statin eligibility comes from age and diabetes only: the upload file has no column for heart
attack or stroke history.

## Regenerate

From the repository root:

```bash
python3 test_data/demo/build_demo_data.py
```

The same as-of date gives the same rows (fixed seeds and md5 picks). The as-of date is 2026-10-13
unless you run it in October 2026 or pass `--as-of YYYY-MM-DD`. The script prints the numbers it
planted. It also writes:

- `out/shifted_*.xlsx`: the source PHC files in `source_phc/`, shifted so the latest visit falls in
  the as-of month (not loaded by `demo_up.sh`);
- `verify_demo.sql`: checks for the cascade and cohort reporting tables, run after a refresh with
  `psql "$DATABASE_URL" -f test_data/demo/verify_demo.sql`.

After regenerating, load it into a new database with `./scripts/demo_up.sh --fresh` (this wipes the
local demo database).
