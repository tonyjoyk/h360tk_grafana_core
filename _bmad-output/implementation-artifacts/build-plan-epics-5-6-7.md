---
created: 2026-11-05
branch: cursor/hearts360-mvp-7579
source_of_truth:
  - _bmad-output/planning-artifacts/epics-hearts360-mvp.md (Epics 5, 6, 7; stories, ACs, Deps, Owns, Cut)
  - _bmad-output/planning-artifacts/prds/prd-hearts360-mvp-2026-11-04/prd.md (FR-31 to FR-49, NFR-1 to NFR-9)
  - _bmad-output/planning-artifacts/ux-designs/ux-hearts360-mvp-2026-11-04/DESIGN.md and EXPERIENCE.md (UX-DR1 to UX-DR19)
  - _bmad-output/planning-artifacts/architecture/architecture-hearts360-mvp-2026-11-04/ARCHITECTURE-SPINE.md (AD-26 to AD-35, Grant matrix)
  - _bmad-output/planning-artifacts/architecture/architecture-hearts360-mvp-2026-11-04/CLINICAL-RULES.md (columns, thresholds, fixtures, seed targets)
  - _bmad-output/planning-artifacts/party-mode/party-hearts360-mvp-2026-11-04.md (PD-1 to PD-22, cut order; these override the others)
  - hearts360ai feature map (research/ai-work-history README): side panel, district summary, ranked facilities, evidence, stock chip
---

# Build plan: Reports (Epic 5), Chat (Epic 6), Verification (Epic 7)

## Why the Reports link and the chat are missing

On 2026-11-05 the sprint file showed every Epic 5 and Epic 6 story as `backlog`, and the code agrees:

- No `report_*` or `chat_*` function exists. Migrations `0.6.8_to_0.6.9` to `0.6.13_to_0.6.14` are empty placeholders (`BEGIN; COMMIT;`).
- No `dashboard_src/reports/`, no `scripts/build_reports_dashboard.py`, no `heart360.reports.json`. So `/d/heart360_reports` returns "Dashboard not found".
- The `Reports` links on the program and drug stock dashboards (stories 2.10 and 3.4, EP-9) already point at `heart360_reports`. That is why the button is there but goes nowhere.
- `h360_api/routes/` has only `write.py`. There is no registry, ranker, wording or chat route. No `docker_build/grafana_public/h360/chat-widget.js`, and the Grafana Dockerfile injects nothing. So no `Ask HEARTS360` pill appears.

The planning set is complete (`status: final` on the PRD, UX, spine and epics). No new BMAD planning documents are needed. This plan builds the existing stories exactly as written.

## Status corrections made with this plan

| Story | Was | Now | Evidence |
| --- | --- | --- | --- |
| 2-8 gate G1a | backlog | done | `verify_security.sh --g1a` on 2026-11-05: 42 PASS, 0 FAIL, exit 0 |
| 4-4 to 4-7 seeds | backlog | done | commit `36d6c5e`; `demo_seed_marker` holds `10_visits`, `20_prescriptions`, `30_calls`, `40_drug_stock` |
| 4-8 insert-only guard | backlog | done | `scripts/verify_seeds_insert_only.sh` exists (commit `36d6c5e`) |

## Build waves (from "Dispatch waves" in the epics file)

Each unit owns only the files listed in its stories' `Owns` line. Nobody else edits `01_heart360_tables.sql`. Every SQL unit ships its `verify_*.sh` with the CLINICAL-RULES fixture and runs it with `PSQL="docker exec -i postgres psql -U h360tk_root"`, then applies its migration to the running demo database.

| Wave | Unit | Stories | Owns | Needs |
| --- | --- | --- | --- | --- |
| A | U7 common + adherence | 5.1, 5.7 | `0.6.8_to_0.6.9.sql`, `verify_report_common.sh`, `verify_adherence.sh` | G1a (done), 4.3 (done) |
| B | U8 titration | 5.4 | `0.6.9_to_0.6.10.sql`, `verify_titration.sh` | 5.1 |
| B | U9 BP readings | 5.2, 5.3 | `0.6.10_to_0.6.11.sql`, `verify_fudging.sh` | 5.1 |
| B | U10 statins | 5.8, 5.9 | `0.6.11_to_0.6.12.sql`, `verify_statins.sh` | 5.1 |
| B | U11 calling + new patients | 5.5, 5.6 | `0.6.12_to_0.6.13.sql`, `verify_calling.sh`, `verify_new_patients.sh` | 5.1 |
| B | U13 shell + builder | 5.11 | `dashboard_src/reports/_shell.json`, `scripts/build_reports_dashboard.py`, `heart360.home.json`, generated `heart360.reports.json` | 5.1 |
| C | U12 flags + chat SQL | 5.10, 6.1, 6.2 | `0.6.13_to_0.6.14.sql`, `verify_report_flags.sh`, `verify_chat_levers.sh` | wave B SQL |
| D | U13a-e tabs + strip | 5.12 to 5.17 | `dashboard_src/reports/1-adherence.json` … `5-calling.json`, strip row in `_shell.json` | 5.10, 5.11, own report |
| D | U14 chat API | 6.3 to 6.7 | `h360_api/{registry,ranker,wording}.py`, `h360_api/routes/chat.py`, tests | 6.1, 6.2 |
| D | U15 chat widget | 6.8, 6.9 | `docker_build/grafana_public/h360/chat-widget.js`, `docker_build/heart360.grafana.docker` | 6.3 contract |
| E | U17 verification | 7.1 to 7.6 | `scripts/verify_all.sh`, `verify_seed_targets.sh`, `verify_banned_words.py`, `verify_upgrade_path.sh`, `verify_chat.sh` | all shipped |
| E | U18 docs | 7.7 | `docs/reports/*.md` | 7.1 to 7.6 |
| — | human | 7.8 | rehearsal and recording | 7.7 |

Wave B units run in parallel. Wave D units run in parallel. The coordinator regenerates and commits `heart360.reports.json` after each tab merge (EP-7), and commits each unit separately.

## Rules every unit follows

- PD-1 to PD-22 override the PRD, UX and spine. Visible tab names and slugs are PD-4 (`Right medicines`, `Stepping up`, `BP readings check`, `Statins`, `Overdue calls`). The table column is `Why look here`. BP wording is PD-5 (no visible `fudg`).
- Thresholds live only in `report_flag_thresholds` (AD-27). No literal threshold in report SQL, panels or `h360_api`.
- Report functions are `STABLE SECURITY DEFINER`, owner `heart360tk`, pinned `search_path`, `REVOKE ALL ... FROM PUBLIC`, grants per the Grant matrix in the same file (AR-2).
- Panels call `report_*` only, through `postgres-hypertension`, ending `WHERE '$isAllowed' = '1'`, reusing the cascade tokens and shared `tip()` (NFR-4). No new plugins.
- `reporting_month` defaults to `2026-10-01` (PD-9). The Grafana time picker is hidden (PD-8).
- The chat is offline by default (PD-14). Claude wording only when `ANTHROPIC_API_KEY` is set (cut-1 if short on time).
- Hard limits: the HTN and DM tabs stay unchanged (`check_htn_dm_untouched.py` exits 0). PRs 5 and 7 stay out. Seeds stay insert-only. `postgres-hypertension` stays on `heart360tk_reader`.

## Feature map alignment (hearts360ai)

The chat answers the prototype's questions inside Grafana, with numbers from the same `report_*` functions as the tabs:

| hearts360ai feature | Built here as |
| --- | --- |
| Resizable right side panel, embed into HEARTS360 | Injected `Ask HEARTS360` pill and 380px panel on every Grafana page (6.8) |
| Ranked facilities needing attention | `visit_first` district answer (6.7) and the Needs-a-look strip (5.12) |
| Insight bullets with evidence | Two or three ranked reasons with numbers and `What to do` (6.4, 6.5) |
| KPIs: control, titration, statins, BP fudging | The five report tabs (5.13 to 5.17) |
| Drug-stock chip | Stock gate line `Fix drug stock first …` (6.1, 6.4) |
| Notes, pin, mark visited (localStorage) | Not in scope (PRD non-goal: no chat history, read-only chat) |

## Done means

- `/d/heart360_reports` opens with five tabs and the strip, with no panel errors, at PHC-E and District-D for `2026-10-01`.
- `Ask HEARTS360` appears on every signed-in page and answers each live chip offline in under 3 s, with the honesty line.
- Every shipped verify script passes, and `verify_all.sh` is green.
- `check_htn_dm_untouched.py` exits 0 and G1a still passes.
- Sprint status shows each built story as `done`.
