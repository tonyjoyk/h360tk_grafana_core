---
title: Plan to port the new screening and treatment cascades to H360-321
status: done (H360-321 5f69fa3, 2026-11-18)
created: 2026-11-18
method: Ponytail (DietrichGebert/ponytail, "ponytail" skill, full level): the smallest change that fully solves the task
---

# Port the new cascades to H360-321

## The branch today

| | |
|---|---|
| Branch | `simpledotorg/h360tk_grafana_core` `H360-321` |
| Last push | Nov. 13, 2026, 09:04 UTC, by Tony (`c5f6e4d`, "hearts360 charts work on phones and tablets") |
| Base | `0.7.0` (`55b7aa7`). H360-321 adds 2 commits, both Tony's. |
| Purpose | Temporary branch for 0.8.0 front-end work (commit `349d098`): the hearts360 look on the Hypertension, Diabetes and Overdue tabs. Only the program dashboard changes. SQL, access rules and variables stay as in 0.7.0. |
| Current cascade | `panel-stc`, "Screening-to-treatment cascade", 16 × 9 grid units, beside "Patients protected" (8 × 9). Screening numbers are fixed placeholders in the panel (30,500 / 14,030 / 7,320, target 46%, 14,500 estimate). Treatment numbers are live. |
| Local copy | `/Users/tony/Documents/GitHub/h360tk_grafana_core-H360-321`, clean at `c5f6e4d`, stack on http://localhost:3200 |

## What moves, and what stays out

**Moves:** only the new cascade card, which is the content of one dashboard element, `panel-stc`.

**Stays out** (another release):
- Medicine data, reports, chat, drug stock, security changes, migrations
- Demo seeds and `demo_up.sh`
- The Reports dashboard and BMAD files
- The build and check scripts

H360-321 has no `dashboard_src/`, no seeds and no `check_htn_dm_untouched.py`, so none of these go across.

## The smallest change (Ponytail ladder)

1. **Does it need to exist?** Yes, but only the card. The two-of-three-column layout already matches H360-321 (16 + 8, 9 high), so no layout change.
2. **Already in that codebase?** Yes. H360-321 keeps screening numbers as placeholders inside the panel query. Do the same. No tables, no seed, no migration.
3. **Reuse what exists.** The panel uses the same datasource (`postgres-hypertension-cached`) and the same variables (`org_unit`, `reference_month`, `isAllowed`). The columns it reads exist in 0.7.0: `cumulative_number_of_patients`, `nb_patients_under_care`, `nb_patients_controlled` and `get_descendant_ids`. The cached role can execute `get_descendant_ids`.
4. **Result:** one commit that changes one element in one JSON file.

## Steps

1. **Add a placeholder query on this branch** (source of truth stays here): `dashboard_src/cascade/panel_placeholder.sql`. It has the same output columns as `panel.sql`. It replaces the three `demo_cascade_*` tables with one inline row of the Indonesia example numbers (2,100,000 adults, 11.94% prevalence, 840,000 / 75,600 / 41,000 / 18,900). It scales that row by the place's share of registered patients, so a facility shows facility-sized numbers. In the code: `shortcut: placeholder scaled by registered share, replace when H360-501, H360-504 and H360-505 land`.
2. **Two small options in `scripts/build_cascade_panel.py`:** `--dashboard PATH` and `--sql PATH`, defaulting to today's values. Run it once:

   ```bash
   python3 scripts/build_cascade_panel.py --sql dashboard_src/cascade/panel_placeholder.sql \
     --dashboard "../h360tk_grafana_core-H360-321/grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension-diabetes.program.json"
   ```
3. **Check the diff in the H360-321 checkout:** `git diff --stat` shows one file. A JSON compare shows only `elements.panel-stc` changed: no layout, no variables, no other element.
4. **Check it live** on http://localhost:3200 (the H360-321 stack reloads provisioning in about 10 seconds):
   - All locations: screening 100% / 40% / 3.6% / 0.9%, treatment live, the card beside "Patients protected".
   - One facility: smaller numbers, same percents.
   - Laptop width (1366 px) and phone width.
5. **Commit on H360-321:** `feat(dashboard): new screening and treatment cascades (placeholder screening data)`.
6. **Push to `simpledotorg/H360-321`.** This step needs Tony's go-ahead, because it is the shared upstream repo.

## What does not change

- The other Hypertension panels, the Diabetes tab, the Overdue tab and the variables
- Any SQL file, script or container

## Risks

- The placeholder screening numbers do not come from data. The card's description says "example data, not program data", the same as H360-321 says "placeholder" today.
- When Gyan's tables land in 0.8.0, swap `panel_placeholder.sql` for `panel.sql` and rebuild. That changes only the `FROM` part of the query.
- Not checked yet: the card on the H360-321 stack. Step 4 covers it.
