# Retired demo seeds

`scripts/demo_up.sh` runs only `test_data/demo/seeds/*.sql`, so nothing in this folder runs.

These four seeds planted patients, visits and medicines in the database after the demo file was
loaded. Since 2026-11-05 the upload file `test_data/demo/demo_generated.xlsx` carries all of that
itself, medicines included (the `Medicines` column), so the demo needs one upload plus the drug
stock and call seeds. They are kept here for reference only.

| Seed | What it planted | Where it is now |
| --- | --- | --- |
| `10_visits.sql` | Extra established, new and call-cohort patients; PHC-C new patients without a phone; PHC-D second-visit loss; PHC-E control top-up and bunching; heart attack and stroke history | The demo file (`build_demo_data.py`). Heart attack and stroke history is not in the file (the upload has no column for it), so statin eligibility comes from diabetes alone. |
| `20_prescriptions.sql` | One prescription per visit, step-ups at high-BP visits from 2026-08 only, statin lines | The demo file's `Medicines` column, with step-ups across the whole history |
| `45_phc_c_phones.sql` | More PHC-C new patients without a phone | The demo file |
| `50_fudging_quarters.sql` | Extra visits so the quarterly BP readings ratio flags PHC-E | The demo file |

Do not move them back: they would add a second, different set of demo patients on top of the file.
