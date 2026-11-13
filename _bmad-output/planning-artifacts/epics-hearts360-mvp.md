---
status: final
stepsCompleted:
  - step-01-validate-prerequisites
  - step-02-design-epics
  - step-03-create-stories
  - step-04-final-validation
mode: headless (no human; decisions recorded under "Planning decisions")
created: 2026-11-04
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-hearts360-mvp-2026-11-04/prd.md
  - _bmad-output/planning-artifacts/prds/prd-hearts360-mvp-2026-11-04/addendum.md
  - _bmad-output/planning-artifacts/ux-designs/ux-hearts360-mvp-2026-11-04/DESIGN.md
  - _bmad-output/planning-artifacts/ux-designs/ux-hearts360-mvp-2026-11-04/EXPERIENCE.md
  - _bmad-output/planning-artifacts/architecture/architecture-hearts360-mvp-2026-11-04/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/architecture/architecture-hearts360-mvp-2026-11-04/CLINICAL-RULES.md
  - _bmad-output/planning-artifacts/party-mode/party-hearts360-mvp-2026-11-04.md
  - ASSUMPTIONS.md
---

# HEARTS360 MVP - Epics and Stories

## Overview

Epics and stories for the HEARTS360 MVP integration branch (`cursor/hearts360-mvp-7579`): merged cascade and drug stock, security fix, five drug stock fixes, medicine model, five reports, floating chat, deterministic fake data, local demo. Numbering continues the PRD (FR-15 to FR-49, NFR-1 to NFR-9). This file is separate from the older `epics.md`, which covers the drug stock MVP (FR-1 to FR-14) and is not touched.

**Precedence.** The party-mode `Decisions for the build` (PD-1 to PD-22) and `Cut order` override the PRD, UX, architecture and clinical-rules files wherever they conflict. Where the architecture spine and `CLINICAL-RULES.md` disagree with the older PRD addendum, the spine wins (as `CLINICAL-RULES.md` states). Every conflict found is listed under "Conflicts resolved".

**How to read a story.** Each story names its build `Unit` (U1 to U18, G1a, G1b from the spine's "Build plan and model mapping"), the `Model` that unit is mapped to, the `Cut` position, `Deps` (story ids), `Owns` (files only that story edits), `Refs`, and testable acceptance criteria. `Cut` is `floor` (must ship), `cut-N` (position N in the cut order; cut from 1 upward, stop when the floor is safe) or `keep` (not in the cut order and not floor: ships unless the coordinator decides otherwise after cut 10).

**Dispatch is by dependency, not by story number.** Epics group work by theme. Some stories in an early epic wait on later epics (for example 1.2 waits on 2.9). The `Deps` lines and the wave table are the source of truth for the coordinator.

## Requirements Inventory

### Functional Requirements

FR-15: One integration branch holds cascade plus drug stock, all dashboards provisioned, fresh `compose up` works.
FR-16: Drug stock migrations run as `0.6.0_to_0.6.1` to `0.6.4_to_0.6.5`; new work continues from `0.6.5`; fresh install equals upgrade from 0.6.0.
FR-17: PR 5 and PR 7 stay out; no statement deletes or rewrites existing patient rows.
FR-18: `./scripts/demo_up.sh` starts the stack, loads fake data, is idempotent, prints dashboard URLs.
FR-19: Drug stock Latest Wins by `submitted_at`; ties to the later ingested row.
FR-20: Wide Google Form sheet converts to long rows via the field spec; blank stays unknown, `0` stays zero.
FR-21: Submitter and history stored; board shows Latest Wins.
FR-22: Drug stock board is scoped per user by Grafana Team, with the HTN access banner.
FR-23: Blank strength no longer corrupts Patient-Days; the All row is sum-based.
FR-24: Dashboard datasources connect as read-only roles; Viewer writes via `/api/ds/query` fail.
FR-25: Writes go through `h360-api` (session check, `SECURITY DEFINER` function, server-side validation).
FR-26: The Overdue tab saves through `h360-api`; look and behaviour unchanged.
FR-27: A script proves a Viewer cannot write directly or for another location.
FR-28: Obat cell stored raw; one Prescription Line per medicine; unparseable entries kept as Unrecognized.
FR-29: One classifier assigns each visit to Step 1-6, Other Protocol, Non-Protocol or Unrecognized; ladder is data.
FR-30: Deterministic, additive fake data with planted facilities; patient rows never deleted.
FR-31: Reports dashboard shell with five tabs, one location, one month, design tokens and `tip()` reused.
FR-32: Plain states: never a silent blank, never `0%` for too few; every flag has a reason sentence.
FR-33: Adherence: patients by Step with BP control; counts sum to the cohort.
FR-34: Adherence window is 90 days; Strict default; toggle adds newer patients and shows cohort size.
FR-35: Titration rate per place with both exclusions counted and shown.
FR-36: Titration flag under 40%; too few visits shows `Too few visits`; sorted so large facilities surface.
FR-37: Fudging score with two decimals; counts visible on hover.
FR-38: Fudging flag at 2.0 or more; guards for too few readings and zero denominator; two-sided pill.
FR-39: Statins: eligible, on statin, percent, not on statin per place.
FR-40: Eligible-not-on-statin list for a facility, overdue-list pattern, no export.
FR-41: Calling coverage and timeliness per place.
FR-42: Calling outcomes and return to care, early versus later.
FR-43: Floating button opens a chip panel on any dashboard; national scope offers `Pick a district`.
FR-44: Every chat answer comes from a fixed query library; no free SQL.
FR-45: Two or three ranked reasons, each with a number and a what-to-do; short plain sentences.
FR-46: Plan nudge returns a four-week calling plan from a stored query.
FR-47: Reasons ranked by the evidence table then gap; two-sided Also check; stock gating; district ranks by uncontrolled patients.
FR-48: Every answer ends with the honesty line; banned words absent.
FR-49: Offline Mode with no key; Claude Mode with a key, falling back to offline on failure.

### NonFunctional Requirements

NFR-1: HTN and DM tabs stay unchanged (tab definitions diff empty); Overdue tab changes only its save path.
NFR-2: PR 5 and PR 7 not merged.
NFR-3: Security (FR-24 to FR-27) lands before any new write path, report or chat. Refined by PD-1 into G1a and G1b.
NFR-4: Reuse hearts360 design tokens, drug stock thresholds, ECharts with shared `tip()`, Business Text; no new plugins.
NFR-5: All new SQL is additive, idempotent and fresh-install safe.
NFR-6: Report panels load within 5 s and offline chat answers within 3 s on demo data (the dashboard verifier fails over 2 s per panel, PD-18).
NFR-7: No patient names, phones or ids leave the machine; the chat is read-only; the API key is server-side only.
NFR-8: Plain language: flag reasons and chat sentences are 20 words or fewer; BP is the only abbreviation.
NFR-9: Every rule has a verify script with a hand-checked fixture.

### Additional Requirements (Architecture)

AR-1 (AD-13): Migration chain `0.6.0` to `0.6.14` renamed once; one owner per file; every migration one transaction, idempotent, starts `SET ROLE heart360tk` (except `0.6.5_to_0.6.6`); order is the `\ir` order. No starter template: the work extends the existing repository.
AR-2 (AD-14, AD-15): Roles `heart360tk_reader`, `grafana_reader`, `h360_api` per the Grant matrix; `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ... FROM PUBLIC`; every new function: owner `heart360tk`, pinned `search_path`, `REVOKE ALL FROM PUBLIC`, explicit `GRANT EXECUTE` in the same file.
AR-3 (AD-16, AD-17): `h360-api` is the only runtime write path; identity only from the Grafana session; CSRF and CORS rules; only the Overdue tab's save paths change in the program dashboard.
AR-4 (AD-18 as amended by PD-1): Gate G1a (read-only roles, datasource flip, `db-grants`, dashboard query verifier) before any report or chat; G1b (write path and `verify_security.sh`) separately.
AR-5 (AD-19 to AD-22): Latest Wins by `submitted_at` with history; wide Form sheet primary input; board access-gated; Patient-Days with blank strength, All row and subtree N.
AR-6 (AD-23 to AD-25): `medicines` catalogue; raw prescriptions parsed by one SQL function; ladder is data; one `visit_step` classifier.
AR-7 (AD-26, AD-27): One `report_window`, one attribution, rates as sum over sum; report function contract and columns; thresholds only in `report_flag_thresholds`.
AR-8 (AD-28, AD-29): One Reports dashboard assembled from one source file per tab by `build_reports_dashboard.py`; deep-link format; links added to home, program, drug stock.
AR-9 (AD-30 to AD-32): Chat registry of stored queries; deterministic ranker; Claude writes wording only; server owns numbers and honesty line.
AR-10 (AD-33): Widget injected into Grafana's `index.html` at image build; build fails unless the tag appears exactly once.
AR-11 (AD-34): Seeds are deterministic insert-only SQL guarded by `demo_seed_marker`; demo users via Grafana API.
AR-12 (AD-35): Every rule ships a `verify_*.sh` with a hand-checked fixture; `PSQL` overridable; `verify_all.sh` runs everything.
AR-13: Stack: PostgreSQL 16 plus pg_cron, Grafana latest (13.3.0 at authoring), Python 3.12-slim, FastAPI 0.162.0, uvicorn 0.54.0, psycopg 3.3.6, httpx 0.28.1, anthropic 2.4.0.

### UX Design Requirements

UX-DR1: Reports shell: title `HEARTS360 Reports`, subtitle `Demo data. Facility names and numbers are made up.`, variables `Reporting Month` (last 12, default `2026-10-01`) and `Patients counted`, collapsed `Change location` row, five tabs, link `← Program dashboard`, Grafana time picker hidden (PD-8, PD-9, PD-19).
UX-DR2: Needs-a-look strip above the tabs: up to three facilities, report chips linking to tabs, empty state `No facility is flagged.` (PD-7).
UX-DR3: Tab skeleton: question, headline strip, one chart, `Look at these first` (max three), facility table, `How this is worked out`; column `Why look here` replaces `Flag and reason` (PD-4).
UX-DR4: Shared facility table: `Needs a look first` sort chip, 10 rows per page, flagged-row bar and tint, guard row, clean row, `All places in view` summed first row, never sorted by control by default.
UX-DR5: Two-sided pill only on `BP readings check` (`◆ Looks fine, check readings`) and `Stepping up` (`◆ Looks fine, check medicines`), each with `Also flagged on …` link to the other tab (PD-6).
UX-DR6: States: `No data for this place.`, `Too few …` with minimum and never `0%`, existing HTN access banner, `No facility is flagged.`
UX-DR7: Per-tab content for the five tabs as in DESIGN.md "Components - per tab", amended by PD-4, PD-5, PD-8, PD-10.
UX-DR8: Charts: no trend lines; Stepping up and Statins are facility bars with a dashed 40% and 25% flag line; shared `tip()`; running-month dashed where a monthly measure is charted (PD-8).
UX-DR9: Tokens: flag, step and chat tokens from DESIGN.md; no red for flags; meaning never colour-only.
UX-DR10: Voice: sentences of 20 words or fewer, plain words, no `will`, `guarantee`, `fudg`, no jargon beyond BP (PD-5).
UX-DR11: Chat widget: `Ask HEARTS360` pill (right 64px, bottom 20px, 48px high), 380px panel, header with place and month, mode badge, close button, light theme.
UX-DR12: Chat chips per scope, driven by the registry; facility floor of three; national shows `Pick a district` only (PD-12).
UX-DR13: Answer card order, plan card, honesty line drawn once per thread after the plan card (PD-13).
UX-DR14: Chat states: loading skeleton with `Still working…` at 3 s and error at 10 s, Claude-failed line, no data, too few, signed out.
UX-DR15: Chat accessibility: real buttons, non-modal dialog, live region, focus to answer title, `Esc` closes, 36px targets, reduced motion.
UX-DR16: Badges `Written from your reports` and `Claude wording` (PD-14); widget adds 72px bottom clearance, or a 48px icon-only pill if the selector fails (PD-15).
UX-DR17: Accessibility floor: real tables with `th scope`, `aria-sort`, flag pills as text, chart descriptions with the takeaway.
UX-DR18: `Patients to review` list (Statins, facility level only): reason chips, search, 20 rows per page, no export.
UX-DR19: Return wording: `Came back within 30 days` plus muted line `The Overdue tab counts 15 days.` (PD-10).

### FR Coverage Map

FR-15: Epic 1 (1.1), Epic 7 (7.4)
FR-16: Epic 1 (1.1), Epic 7 (7.4)
FR-17: Epic 1 (1.1), Epic 4 (4.8)
FR-18: Epic 1 (1.2), Epic 4 (4.4 to 4.8), Epic 7 (7.1)
FR-19: Epic 3 (3.1)
FR-20: Epic 3 (3.3)
FR-21: Epic 3 (3.1)
FR-22: Epic 3 (3.4)
FR-23: Epic 3 (3.2)
FR-24: Epic 2 (2.1, 2.4, 2.6, 2.7, 2.8)
FR-25: Epic 2 (2.3, 2.9, 2.10)
FR-26: Epic 2 (2.10)
FR-27: Epic 2 (2.7, 2.11, 2.12)
FR-28: Epic 4 (4.2)
FR-29: Epic 4 (4.1, 4.3)
FR-30: Epic 4 (4.4 to 4.7)
FR-31: Epic 5 (5.11 to 5.17)
FR-32: Epic 5 (5.1, 5.13 to 5.17)
FR-33: Epic 5 (5.7, 5.16)
FR-34: Epic 5 (5.7, 5.11, 5.16)
FR-35: Epic 5 (5.4, 5.14)
FR-36: Epic 5 (5.4, 5.14)
FR-37: Epic 5 (5.2, 5.13)
FR-38: Epic 5 (5.2, 5.3, 5.13)
FR-39: Epic 5 (5.8, 5.17)
FR-40: Epic 5 (5.9, 5.17)
FR-41: Epic 5 (5.5, 5.15)
FR-42: Epic 5 (5.5, 5.6, 5.15)
FR-43: Epic 6 (6.3, 6.8, 6.9)
FR-44: Epic 6 (6.3)
FR-45: Epic 6 (6.4, 6.5)
FR-46: Epic 6 (6.1, 6.5)
FR-47: Epic 6 (6.2, 6.4, 6.7)
FR-48: Epic 6 (6.5), Epic 7 (7.3)
FR-49: Epic 6 (6.5, 6.6)

## Epics in this plan

**Epic 1: Integration and demo boot**
One clean branch and one command that brings the whole demo up and says where to click.
**FRs covered:** FR-15, FR-16, FR-17, FR-18

**Epic 2: Security: read-only dashboards and one write path**
A Viewer can no longer write through Grafana's query API, and the Overdue save still works through `h360-api`. Split into gate G1a (read-only) and gate G1b (write path).
**FRs covered:** FR-24, FR-25, FR-26, FR-27

**Epic 3: Drug stock fixes**
Drug stock shows the newest submission, takes a real Form sheet, keeps history, respects location access, and computes Patient-Days correctly.
**FRs covered:** FR-19, FR-20, FR-21, FR-22, FR-23

**Epic 4: Medicine data and fake data**
Postgres holds what each patient was prescribed, and deterministic fake data gives every report something to find.
**FRs covered:** FR-28, FR-29, FR-30

**Epic 5: Reports**
A manager opens one Reports dashboard and names the facility to visit, and why, in two minutes.
**FRs covered:** FR-31 to FR-42

**Epic 6: Chat**
A manager asks why control is low and gets two or three ranked reasons, a plan, and the honesty line, with or without a network.
**FRs covered:** FR-43 to FR-49

**Epic 7: Verification and demo readiness**
Every shipped rule is checked, the demo is rehearsed, and the images are frozen.
**FRs covered:** cross-cutting (FR-15, FR-16, FR-18, FR-48; NFR-1, NFR-6, NFR-8, NFR-9)

## Readiness gate (bmad-sprint-planning, headless)

**Verdict: CONCERNS, proceeded** (no human available; the owner asked for a decision, not a question). Every requirement FR-15 to FR-49, NFR-1 to NFR-9, UX-DR1 to UX-DR19 and PD-1 to PD-22 traces to at least one story, and every story traces back to a requirement. Open concerns:

1. Story 1.2 waits on 2.4, 2.9 and 5.11, which sit in later epics (by design: the hardened `demo_up.sh` needs the services it waits for). All other cross-epic dependencies point backward. There is no cycle.
2. Story 7.8 needs a human (a person who did not build the product, and a screen recording).
3. EP-1 to EP-13 and C1 to C19 are headless decisions the owner has not seen. `ASSUMPTIONS.md` was not edited as instructed; copy them as A86 onward after review.
4. The acceptance criteria of the in-progress stories (2.1 to 2.4, 3.1 to 3.3, 4.1 to 4.3) were written from the spine while the units were already running. Compare them with the units' output before marking those stories done.
5. The numeric demo targets (CLINICAL-RULES section 7) are verified only in 7.2, after all seeds and reports exist.

## Dispatch waves (coordinator view)

Spine waves, updated for the G1a/G1b split (PD-1) and the build order (PD-3). A wave starts when its listed gate or deps are met.

| Wave | Stories | Gate |
| --- | --- | --- |
| 0 done | 1.1 | none |
| 1 in progress | 2.1, 2.2, 2.3, 2.4 (U2); 3.1, 3.2 (U5a); 3.3 (U5b); 4.1, 4.2, 4.3 (U6) | none |
| 1b | 2.5, 2.6, 2.7, then **2.8 G1a**; 2.9 (skeleton) in parallel | 2.8 closes G1a |
| 2 after G1a, medicine model first | 5.1 (common) then 5.2 and 5.5 in parallel (no medicine data); 3.4; 4.4, 4.6, 4.7, 4.8; G1b track 2.10, 2.11, 2.12 | G1a |
| 3 after the medicine model is green (4.3) | 5.4, 5.7, 5.8, 5.9; 4.5; 5.3, 5.6 | 4.3 |
| 4 | 5.10; 6.1, 6.2; 5.11, then 5.12 and tabs 5.13 to 5.17; 6.3 to 6.7; 6.8, 6.9 | 5.10 for tabs and chat |
| 5 | 7.1 to 7.8 | all shipped stories |

If 4.3 is not green at its gate: 5.4, 5.7, 5.8 become stubs and the floor is `BP readings check`, `Overdue calls` and a chat with `why_control_low` and `who_to_call`, announced as such (PD-3). No hand-faked prescriptions.

## Cut order (PD, "Cut order if short on time")

| # | Cut | Stories affected |
| --- | --- | --- |
| 1 | Claude mode, offline only | 6.6 |
| 2 | Statins patient list | 5.9; the `Patients to review` row of 5.17 |
| 3 | Statins tab (stub, drop `statin_gap` chip) | 5.8, 5.17 |
| 4 | Adherence `Patients counted` toggle (strict only) | the toggle parts of 5.7, 5.11, 5.16 |
| 5 | Chips beyond the floor of three (`medicines_adjusted`, then `readings_reliable`) | the chip parts of 6.3 |
| 6 | Fudging histogram becomes two bars | 5.3 |
| 7 | Needs-a-look strip; the tab list starts on `BP readings check` | 5.12 |
| 8 | Adherence tab (stub; classifier stays) | 5.7, 5.16 |
| 9 | District chip `visit_first` and `facility_rank_district` | 6.2, 6.7 |
| 10 | `h360-api` write path (G1b): Overdue quick panel read-only with `Saving is switched off in this build.` | 2.3, 2.10, 2.11, 2.12 |

**Floor (never cut):** G1a; HTN/DM diff empty; `demo_up.sh` idempotent; `BP readings check`, `Stepping up`, `Overdue calls`; chat with three chips, plan card and honesty line.

**Stub rule (PD-2).** A cut report function keeps its contract signature and column list, returns zero rows, and carries `COMMENT ON FUNCTION ... IS 'h360:stub'`. `report_flags` and the chat registry tolerate it; the registry hides chips whose function carries the marker. The builder's `TABS` list drops the tab; its `verify_*.sh` leaves `verify_all.sh` with it.

## Planning decisions (made headless; each reversible)

| Id | Decision | Where |
| --- | --- | --- |
| EP-1 | U3 splits into a skeleton story (2.9, floor, chat host) and a write story (2.10, cut-10). U4 splits into the dashboard verifier (2.6), `verify_security.sh --g1a` (2.7) and the write checks (2.11). Reason: G1b is cut 10 but the chat (floor) needs the API host. | 2.6 to 2.11 |
| EP-2 | U7 splits into common (5.1, floor, no medicine dependency) and adherence (5.7, cut-8). Reason: PD-3 says fudging and calling start without the medicine model. U8 to U11 depend on 5.1 plus only the data they read. | 5.1, 5.7 |
| EP-3 | A shared invoker helper `h360_control_summary(month, org)` (HTN tab formulas) lives in 5.1; `report_fudging` and `report_titration` call it for `control_pct`; `chat_control_summary` wraps it. Reason: PD-6 says the formula comes from `chat_control_summary`, which is built later. | 5.1, 5.2, 5.4, 6.1 |
| EP-4 | `report_flags` gains one trailing column `patients_n` (under-care patients of the facility). Reason: PD-7 sorts the strip by patients and `report_flags` has no other source for it; the strip may only call `report_*`. | 5.10 |
| EP-5 | Stubs carry the comment `h360:stub`; `/chat/chips` reads it to hide dead chips (PD-12). | 6.3 |
| EP-6 | `h360_api/app.py` auto-mounts any module in `h360_api/routes/` that exposes `router`. U14 adds files only and never edits U3's `app.py`. | 2.9, 2.10, 6.3 |
| EP-7 | Tab units commit only their `dashboard_src/reports/<n>-<slug>.json`. The coordinator regenerates and commits `heart360.reports.json` at each merge (`build_reports_dashboard.py`, then `--check`). Reason: five parallel units would otherwise conflict on the generated file. | 5.11 to 5.17 |
| EP-8 | `patient_cvd_history` has no owner in the spine; it goes to U6 (4.2). | 4.2 |
| EP-9 | The `Reports` entry in the program dashboard's `spec.links` belongs to the U3 write story (2.10), as the spine's AD-17 lists; it stays even if the write path is cut. | 2.10 |
| EP-10 | `chat_call_plan` weeks are `LEAST(ceil(n/4), remaining)` so the four weeks sum to n (86 gives 22, 22, 22, 20); `calls_per_week` is `ceil(n/4)`. The spine's "ceil(n/4) per week" would overshoot n. | 5.5, 6.1 |
| EP-11 | The `BP readings check` title is `Are BP readings bunching just under 140?` (PD-5 fixes metric, flag, reason and note, not the title). The `Stepping up` table column is `Share stepped up` (DESIGN's `Titration rate` breaks the Voice rules). | 5.13, 5.14 |
| EP-12 | The calling table's `Few phone numbers` flag reads the new-patient usable-phone flag (below 50%, A38); `report_calling` has no phone-share flag of its own. | 5.15 |
| EP-13 | `report_flags` returns facility rows only (level 3, or the selected facility), report names `adherence`, `titration`, `fudging`, `statins`, `calling`. | 5.10 |

## Conflicts resolved

| # | Conflict | Resolution |
| --- | --- | --- |
| C1 | Spine AD-18 and the wave table gate reports and chat on one G1 (`verify_security.sh`). PD-1 splits it. | G1a gates reports and chat; G1b gates the write path only (2.8, 2.12). Round 5's "NFR-3 stricter gate stays" is read as G1a; the Decisions list governs. |
| C2 | Spine wave table: U7 needs U6, U8 to U11 need U7. PD-3: fudging and calling start without medicine data. | EP-2. |
| C3 | Spine wave table gives `report_flags` to U7; AD-27 and AD-13 create it in `0.6.13_to_0.6.14` (U12). | U12 owns it (5.10). |
| C4 | Tab names and slugs: AD-29, DESIGN and EXPERIENCE versus PD-4. | PD-4: `Right medicines`, `Stepping up`, `BP readings check`, `Statins`, `Overdue calls`; slugs `Right-medicines`, `Stepping-up`, `BP-readings-check`, `Statins`, `Overdue-calls`. Internal names (`report_fudging`, `panel-fudging-*`, files `1-adherence.json` to `5-calling.json`) stay. |
| C5 | Fudging wording: CLINICAL-RULES section 1 reasons, CR-4 and DESIGN tab 3 versus PD-5. | PD-5: `Bunching score`, flag `Readings bunch under 140`, reasons `{x.xx} readings just under 140 for every 1 just over. Check how BP is measured.` and `No 140-144 readings. Check how BP is measured.`; no visible `fudg`. Column `Flag and reason` becomes `Why look here`. |
| C6 | Two-sided pill on "any flag" (A36, DESIGN) versus PD-6. `report_titration` has no `control_pct` or `looks_fine_check` in CLINICAL-RULES. | PD-6: pill on two tabs with tab-specific text; `report_titration` gains both columns (5.4). |
| C7 | DESIGN: time picker `Last 12 months`, monthly line charts for Titration and Statins. No trend function exists. | PD-8, A75: picker hidden; facility bars with dashed 40% and 25% lines. |
| C8 | `reporting_month` default: latest completed (A34, AD-28) versus pinned `2026-10-01` (PD-9). | Pinned in `_shell.json` for the demo (5.11); `demo_up.sh` prints it (1.2). Revert after the demo. |
| C9 | Chip counts 5 and 6 (A41, EXPERIENCE) versus registry-driven with a floor of three (PD-12). | PD-12 (6.3, 6.8). |
| C10 | Badge `Offline answers` (DESIGN, EXPERIENCE) versus `Written from your reports` and `Claude wording` (PD-14). | PD-14 (6.9). |
| C11 | DESIGN reads `var-reference_month`; AD-33 and AD-28 use `var-reporting_month`. | `var-reporting_month` (AD-33). |
| C12 | Plan card repeats the honesty line (DESIGN) versus once per thread (PD-13). | API always returns it; widget draws it once after the plan card (6.9). |
| C13 | Chat for a high-control place: ranker title `Why is BP control low` (AD-31) versus PD-11. | PD-11 branch in 6.4. |
| C14 | NFR-1 "byte-identical" versus PD-21 (tab definitions only; numbers move after seeding, A84). | `check_htn_dm_untouched.py` compares tab definitions only; the runbook says numbers move (7.7). |
| C15 | NFR-6 (5 s) versus PD-18 (2 s per panel). | The verifier fails over 2 s; 5 s stays the outer bound (2.6, 7.6). |
| C16 | Ladder and Non-Protocol list: PRD addendum section 2 and PRD plain-words rule versus spine CR-1, A49 and CLINICAL-RULES (CCB-first ladder, five protocol drugs). DESIGN adherence row labels differ from `htn_ladder_steps.label`. | Spine and CLINICAL-RULES win; the chart labels come from `htn_ladder_steps.label` (5.7, 5.16). |
| C17 | PRD FR-42 reconcile with `HEART360_OVERDUE_RETURNED_TO_CARE` versus CR-6 (30 days versus 15). | CR-6 and PD-10: calls reconcile, returns do not; the tab says so (5.5, 5.15). |
| C18 | Cut order tail: items that are neither floor nor in the cut list (drug stock, new patients, drug stock seed). | Marked `keep`. |
| C19 | AD-28 fixes tab order 1 to 5; cut 7 says to start on `BP readings check` if the strip is cut. | The builder's `TABS` order is the tab order; 5.12 cut moves `BP readings check` first. |

## Epic 1: Integration and demo boot

One branch, one command, honest links.

### Story 1.1: Merge housekeeping and migration renumbering

As the coordinator, I want the drug stock migrations renumbered onto 0.6.x with placeholders reserved, so that every later unit edits only its own migration file.

**Unit** U1 · **Model** `composer-2.5-fast` · **Cut** floor · **Deps** none · **Status** done (commit `3274a22`)
**Owns** `pg_init_scripts/migrations/0.6.*`, `pg_init_scripts/01_heart360_tables.sql` (`\ir` lines), five `verify_*.sh` filenames and `PSQL` lines
**Refs** FR-15, FR-16, FR-17, NFR-2, NFR-5, AD-13

**Acceptance Criteria:**
- **Given** the branch, **When** the migrations folder is listed, **Then** `0.6.0_to_0.6.1` to `0.6.4_to_0.6.5` are the renamed drug stock files and placeholders `0.6.5_to_0.6.6` to `0.6.13_to_0.6.14` exist as header plus `BEGIN; COMMIT;`.
- **Given** `01_heart360_tables.sql`, **When** read, **Then** its `\ir` lines follow the AD-13 order and `0.5.1_to_0.6.0.sql` is not `\ir`'d.
- **Given** the five `verify_*.sh` scripts, **When** read, **Then** they use the new filenames and `PSQL="${PSQL:-sudo -u postgres psql}"`.

### Story 1.2: `demo_up.sh` hardening and deep links

As Tony, I want one command that waits for every service and then prints the three links I need, so that I can open the demo without guessing.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** floor · **Deps** 2.4, 2.9, 5.11 (slugs) · **Status** backlog
**Owns** `scripts/demo_up.sh` (hardening and hook lines)
**Refs** FR-18, SM-1, PD-9, PD-16, AD-34

**Acceptance Criteria:**
- **Given** empty volumes, **When** `./scripts/demo_up.sh --fresh` runs, **Then** it waits for `db-grants` to exit 0 and `GET /healthz` on `h360-api` to return 200 before printing any URL, and exits 0.
- **Given** the stack is already up, **When** the script runs a second time, **Then** row counts of `patients`, `encounters`, `prescriptions` and `call_results` are unchanged.
- **Given** a successful run, **When** the output is read, **Then** it prints Reports at the district with `var-reporting_month=2026-10-01`, PHC-E with the chat open, and the Overdue tab as `nurse.phc-a` (password `demo`), plus the expected month and the rule `open only http://localhost:3000`.
- **Given** the seed loop, **When** the script runs, **Then** it runs `scripts/demo_users.sh` after the seeds and the default `H360_ALLOWED_ORIGINS` includes `http://localhost:3000` and `http://127.0.0.1:3000`.

## Epic 2: Security: read-only dashboards and one write path

### Story 2.1: Read-only roles, grant matrix and function privilege hygiene

As an operator, I want every dashboard to connect as a role that can only read, so that a Viewer cannot change data.

**Unit** U2 · **Model** `claude-opus-5-5-high` · **Cut** floor · **Deps** 1.1 · **Status** in-progress
**Owns** `pg_init_scripts/migrations/0.6.5_to_0.6.6.sql` (roles, grants, hygiene)
**Refs** FR-24, NFR-3, NFR-5, AD-14, AD-15, Grant matrix

**Acceptance Criteria:**
- **Given** a fresh database, **When** the chain runs, **Then** `heart360tk_reader`, `grafana_reader` and `h360_api` exist with LOGIN and the matrix grants, and the migration starts with `RESET ROLE` then switches to `SET ROLE heart360tk` for its functions.
- **Given** `heart360tk_reader` or `heart360tk_cached`, **When** it runs `INSERT`, `UPDATE`, `DELETE` or `set_config('default_transaction_read_only','off',false)` followed by a write, **Then** the write is refused by privilege.
- **Given** the matrix, **When** `has_function_privilege` is checked, **Then** `heart360tk_reader` cannot execute `save_call_result`, `drug_stock_pull_apply`, `delete_leaf_node_data`, `start_async_refresh` or `H360TK_ADMIN_CLEAN_DATA`, and `h360_api` has no table privilege.
- **Given** the global default-privilege revoke and the per-function revokes, **When** a new function is created by `heart360tk`, **Then** `PUBLIC` cannot execute it.
- **Given** the migration is run twice, **Then** the second run changes nothing and raises no error.

### Story 2.2: `h360_access_allows` access rule

As a program manager, I want the server to apply the same location rule as the dashboards, so that writes and chat cannot reach places I cannot see.

**Unit** U2 · **Model** `claude-opus-5-5-high` · **Cut** floor · **Deps** 2.1 · **Status** in-progress
**Owns** `0.6.5_to_0.6.6.sql` (function), new `pg_init_scripts/migrations/verify_access_rule.sh`
**Refs** FR-25, AD-15, AD-16

**Acceptance Criteria:**
- **Given** `h360_access_allows(p_is_admin, p_team_names, p_org_unit_id)`, **When** a verify matrix of user, team and node is run, **Then** its result equals the program dashboard `isAllowed` query for every row (admin; empty or 0 node with an `_ALL` team; a team in `get_access_groups(ancestor, 'aggregated'|'patients')` over the lineage; an `_ALL` team at a level at or above the node's).
- **Given** the function, **When** inspected, **Then** it is `SECURITY DEFINER`, owned by `heart360tk`, has a pinned `search_path`, is revoked from `PUBLIC`, and `h360_api` can execute it.

### Story 2.3: `save_call_result` and `call_results_audit`

As Meera, I want an overdue call result saved only if I may see that patient's place, so that a direct call cannot write for another location.

**Unit** U2 · **Model** `claude-opus-5-5-high` · **Cut** cut-10 · **Deps** 2.1, 2.2 · **Status** in-progress
**Owns** `0.6.5_to_0.6.6.sql` (function and audit table)
**Refs** FR-25, FR-26, AD-16

**Acceptance Criteria:**
- **Given** a missing patient, **When** `save_call_result` runs, **Then** it returns `not_found`; a status outside the 11 overdue-list strings returns `bad_status`; an access refusal on the patient's `org_unit_id` returns `forbidden` and writes nothing.
- **Given** an allowed call, **When** it runs, **Then** it upserts on `(patient_id, CURRENT_DATE)`, sets `result_type` NULL for `Agreed to visit`, `Pending to call` and `Call again later` and `removed_from_overdue_list` otherwise, sets `removed_reason` to the status and `org_unit_id` to the patient's, and appends one `call_results_audit` row (actor, patient, status, time).
- **Given** the grants, **Then** only `h360_api` can execute it.

### Story 2.4: Datasource flip, Grafana defaults and `db-grants`

As an operator, I want Grafana's datasources to use the read-only roles and its own tables locked down, so that the query API cannot be used to write or escalate.

**Unit** U2 · **Model** `claude-opus-5-5-high` · **Cut** floor · **Deps** 2.1 · **Status** in-progress
**Owns** `grafana_provisioning/datasources/*.yml`, `grafana_provisioning/config/grafana.ini`, `db_grants/`, `docker-compose.yml` (`db-grants` service)
**Refs** FR-24, NFR-3, AD-14, A60, A66

**Acceptance Criteria:**
- **Given** the provisioning files, **When** read, **Then** `postgres-hypertension` connects as `heart360tk_reader` with `editable: false`, `postgres-grafana` as `grafana_reader`, `postgres-hypertension-cached` as `heart360tk_cached`, uids and names unchanged.
- **Given** `grafana_api.yml`, **Then** it is deleted and a `deleteDatasources` entry removes `GrafanaApi` from upgraded volumes; `grafana.ini` sets `auto_assign_org_role = Viewer`.
- **Given** `docker compose up`, **When** Grafana has created `grafana_schema.team_member`, **Then** the one-shot `db-grants` service (image `postgres:16-alpine`, `restart: "no"`) applies `db_grants/grafana_reader_grants.sql` as `h360tk_root` and exits 0, on every `up`.
- **Given** `grafana_reader`, **When** it selects `grafana_schema."user"(password)` or any column outside the grant list, **Then** the query is refused; before `db-grants` has run, `postgres-grafana` queries fail closed.
- **Given** an empty volume, **When** `docker compose up -d --build` runs, **Then** it starts without errors.

### Story 2.5: Demo Viewers for access tests

As a tester, I want two fixed demo Viewers, so that access and security checks run against real Grafana users.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** floor · **Deps** 2.4 · **Status** backlog
**Owns** `scripts/demo_users.sh`
**Refs** FR-22, FR-27, AD-34, A62

**Acceptance Criteria:**
- **Given** a running Grafana, **When** the script runs, **Then** Viewers `district.d` (team `heart360tk_district_view_patients_district-d`) and `nurse.phc-a` (team `heart360tk_facility_view_patients_phc-a`) exist with password `demo`, using the Grafana HTTP API only.
- **Given** the users exist, **When** the script runs again, **Then** it exits 0 and creates no duplicate user, team or membership.

### Story 2.6: Dashboard query verifier

As a coordinator, I want every provisioned panel and variable query run as its datasource's role, so that the datasource flip cannot silently break the HTN or DM tabs.

**Unit** U4 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 2.1, 2.4 · **Status** backlog
**Owns** `scripts/verify_dashboard_queries.py`
**Refs** FR-24, NFR-1, NFR-6, NFR-9, PD-1, PD-18

**Acceptance Criteria:**
- **Given** the compose stack, **When** the script runs, **Then** it executes every panel and variable SQL of every provisioned dashboard (including HTN/DM and drug stock) as that datasource's role with sample variable values, and exits nonzero on any permission or syntax error, naming the dashboard and panel.
- **Given** the run, **Then** it prints per-panel timing and fails any panel over 2 s on demo data.

### Story 2.7: `verify_security.sh` part 1 (G1a checks)

As a coordinator, I want a script that proves a Viewer cannot write through Grafana, so that G1a has evidence.

**Unit** U4 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 2.1, 2.4, 2.5 · **Status** backlog
**Owns** `scripts/verify_security.sh` (`--g1a` mode)
**Refs** FR-24, FR-27, NFR-3, AD-15, AD-18, PD-1

**Acceptance Criteria:**
- **Given** the two demo Viewers, **When** `verify_security.sh --g1a` runs, **Then** direct `INSERT`, `UPDATE`, `DELETE` and `set_config(...,'off')` plus `INSERT` posted to `/api/ds/query` are refused on all three Postgres datasources.
- **And** `UPDATE "user"` via `postgres-grafana` is refused, datasource `GrafanaApi` is absent, and `has_function_privilege` for every login role finds no function outside the matrix.
- **Given** any check fails, **Then** the script exits nonzero with the failing check's name.

### Story 2.8: Gate G1a

As the coordinator, I want one explicit gate for the read-only fix, so that no report or chat unit merges before it holds.

**Unit** G1a · **Model** coordinator (parent model) · **Cut** floor (never moves) · **Deps** 2.1, 2.2, 2.4, 2.6, 2.7 · **Status** backlog
**Owns** no files (records the gate result)
**Refs** FR-24, NFR-1, NFR-3, PD-1, A70

**Acceptance Criteria:**
- **Given** an empty volume, **When** the stack is up, **Then** `db-grants` has exited 0, `verify_dashboard_queries.py` is green on every provisioned panel including HTN/DM, and `verify_security.sh --g1a` is green.
- **And** `check_htn_dm_untouched.py` passes.
- **Then** the gate is recorded in sprint status notes; stories 5.1 onward and 6.3 onward may merge.

### Story 2.9: `h360-api` skeleton, auth and compose service

As a developer, I want a small API service that knows who is calling, so that the write path and the chat share one trusted identity check.

**Unit** U3 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 2.2, 2.4 · **Status** backlog
**Owns** `h360_api/{app.py,auth.py,config.py,requirements.txt,Dockerfile}`, `h360_api/routes/__init__.py`, `h360_api/tests/test_auth.py`, `docker-compose.yml` (`h360-api` service), `.env.example`
**Refs** FR-25, NFR-7, AD-16, AD-17 (CORS), Consistency Conventions (errors, logging, secrets), EP-6

**Acceptance Criteria:**
- **Given** a request with no `grafana_session` cookie or a non-200 answer from Grafana, **When** any non-health route is called, **Then** it returns `401` with `{"ok": false, "error": "unauthenticated", "message": ...}`.
- **Given** a valid session, **When** the service calls `GET /api/user` and `/api/user/teams` with only that cookie, **Then** `is_admin` comes from `isGrafanaAdmin` and teams are the team names; nothing about identity is read from the body.
- **Given** a `POST` without `Content-Type: application/json` and `X-H360-Request: 1`, or with an `Origin` outside `H360_ALLOWED_ORIGINS` (default `http://localhost:3000,http://127.0.0.1:3000`), **Then** it is refused with `403`; allowed origins get that exact origin and `Allow-Credentials: true`.
- **Given** the service starts, **Then** `GET /healthz` returns 200 without a session, every request logs one line (method, path, status, login, ms) and never cookies, keys, prompts or patient names, and modules in `h360_api/routes/` that expose `router` are mounted automatically.
- **Given** `docker compose up`, **Then** `h360-api` runs on 8090 as role `h360_api`, `depends_on` postgres and grafana, `.env.example` ships with `ANTHROPIC_API_KEY` blank, and `.env` is git-ignored.
- **Given** fake-Grafana unit tests, **Then** they pass (no cookie, Grafana 401, bad origin, good request).

### Story 2.10: Write endpoint and Overdue save through `h360-api`

As Meera, I want the Overdue quick list to save through the server, so that I see Saved and a direct call cannot bypass the check.

**Unit** U3 · **Model** `grok-4.7-high` · **Cut** cut-10 · **Deps** 2.3, 2.9 · **Status** backlog
**Owns** `h360_api/routes/write.py`, `h360_api/tests/test_write.py`, `heart360.hypertension-diabetes.program.json` (Overdue save paths and one `spec.links` entry)
**Refs** FR-25, FR-26, NFR-1, AD-16, AD-17, A59, EP-9, PD-1

**Acceptance Criteria:**
- **Given** `POST /write/call-result` with `{"patient_id": "<digits>", "status": "<string>"}`, **When** there is no session, **Then** `401`; for a patient outside the caller's location, `403` and no `call_results` row; for an allowed patient, `200 {"ok": true, ...}` with one `call_results` row and one audit row; a non-digit id or unknown status gives `400`.
- **Given** the program dashboard, **When** `panel-ov-quick` saves, **Then** it calls `fetch(H360_API + '/write/call-result', {method:'POST', credentials:'include', headers:{'Content-Type':'application/json','X-H360-Request':'1'}, body})`, and Saving, Saved, remove-with-reason and the error toast behave as before.
- **Given** `panel-ov-1`, **Then** its `update` block is gone and it is read-only; the only other program edit is one `Reports` entry in `spec.links`; `check_htn_dm_untouched.py` passes.
- **Given** the cut-10 fallback (G1b not green), **Then** the endpoint is not mounted, `panel-ov-quick` is read-only with the note `Saving is switched off in this build.`, and `panel-ov-1` and `spec.links` changes stay.

### Story 2.11: `verify_security.sh` part 2 (write path checks)

As a coordinator, I want the write path tested as two Viewers, so that G1b has evidence.

**Unit** U4 · **Model** `grok-4.7-high` · **Cut** cut-10 · **Deps** 2.7, 2.10 · **Status** backlog
**Owns** `scripts/verify_security.sh` (write checks)
**Refs** FR-27, NFR-3, SM-4, AD-18

**Acceptance Criteria:**
- **Given** the demo Viewers, **When** the full script runs, **Then** `POST /write/call-result` with no cookie returns 401, for a patient outside the Viewer's location returns 403 with no row written, and for an allowed patient returns 200 with one `call_results` row and one audit row.
- **And** a request with a foreign `Origin` is refused, and part 1 still passes.

### Story 2.12: Gate G1b

As the coordinator, I want the write path to pass its own gate, or be switched off cleanly, so that the demo never ships an unchecked write.

**Unit** G1b · **Model** coordinator (parent model) · **Cut** cut-10 · **Deps** 2.10, 2.11 · **Status** backlog
**Owns** no files (records the gate result)
**Refs** FR-26, FR-27, SM-4, PD-1, A70

**Acceptance Criteria:**
- **Given** the branch, **When** the full `verify_security.sh` is green and a manual save as `nurse.phc-a` shows Saving then Saved, **Then** G1b is recorded passed.
- **Given** it is not green when the coordinator needs to freeze, **Then** the 2.10 fallback is applied and the decision is recorded.

## Epic 3: Drug stock fixes

### Story 3.1: Latest Wins by `submitted_at`, submitter and history

As a program manager, I want the newest submission to win and every submission kept, so that sheet row order never decides what I see.

**Unit** U5a · **Model** `claude-opus-5-5-high` · **Cut** keep · **Deps** 1.1 · **Status** in-progress
**Owns** `0.6.6_to_0.6.7.sql` (Latest Wins part), `verify_drug_stock_pull.sh`
**Refs** FR-19, FR-21, NFR-5, NFR-9, AD-19, A33

**Acceptance Criteria:**
- **Given** cell `(F1, 2026-10-01, 329528)` with sheet row 3 (`2026-10-05`, 50) and row 4 (`2026-10-02`, 90), **When** both are applied, **Then** the stored value is 50 and history holds 2 rows.
- **Given** a re-pull of row 4 alone, **Then** the stored value stays 50 and history has no duplicate (`ON CONFLICT DO NOTHING` on the unique key).
- **Given** rows 5 (60) and 6 (70) with the same `submitted_at`, **Then** the stored value is 70.
- **Given** the schema, **Then** `drug_stock_submission` has `submitted_by` and `sheet_row`, `drug_stock_submission_history` is append-only, and `drug_stock_pull_apply` is the only writer.

### Story 3.2: Patient-Days with blank strength, a correct All row and subtree N

As a program manager, I want a blank strength to show `—` and the All row to be sum-based, so that no partial sum looks like a number.

**Unit** U5a · **Model** `claude-opus-5-5-high` · **Cut** keep · **Deps** 3.1 (same migration file) · **Status** in-progress
**Owns** `0.6.6_to_0.6.7.sql` (Patient-Days part), `verify_drug_stock_patient_days.sh`, `verify_drug_stock_on_hand.sh`
**Refs** FR-23, NFR-9, AD-22, A50, A51

**Acceptance Criteria:**
- **Given** CCB coeff 1.4, load 1.0 and the F1/F2/F3 fixture (N 100, 200, 300; Amlodipine 5 of 1400, 2800, blank; Amlodipine 10 of 0, 1400, 700), **Then** Patient-Days are 10.00, 20.00 and `—`.
- **And** the All row is 7000 / (300 × 1.4) = 16.67 with `reporting_n` 2 and `cohort_n` 3, and the old value 10.00 never appears.
- **Given** a facility whose patients sit at level 4, **Then** N is the sum of `cumulative_number_of_patients` over `get_descendant_ids(facility)` at `ref_month`.
- **Given** a cohort containing a node and its descendant, **Then** the verify script fails; the `-1` (submitted null) marker is kept.

### Story 3.3: Wide Form sheet puller

As Tony, I want a real Google Form response sheet to load without reshaping, so that facility staff's submissions reach the board.

**Unit** U5b · **Model** `grok-4.7-high` · **Cut** keep · **Deps** 1.1 (end-to-end check needs 3.1) · **Status** in-progress
**Owns** `drug_stock/pull/*` (`pull.py`, new `fixture_wide_form.json`)
**Refs** FR-20, FR-21, AD-12, AD-20, A33

**Acceptance Criteria:**
- **Given** a header row with `Timestamp` and at least one column label in `form_field_spec.json`, **When** the puller runs, **Then** it parses the wide layout; otherwise the existing long layout (`A:E`) still works.
- **Given** a wide fixture, **Then** each response yields one long row per spec column with `submitted_at` from `Timestamp` (serials converted with the sheet time zone), `submitted_by` from `Email Address`, `org_unit_id` from `Facility` (digits, or trailing `(digits)`), `reporting_month` normalised to the first of the month, `rxnorm_code` from the spec, and `sheet_row` the 1-based sheet row.
- **Given** blank or `?`, **Then** `in_stock` is NULL; `0` stays 0; a non-numeric value goes to the reject table.
- **Given** either layout, **Then** both end in one `drug_stock_pull_apply` call; a wide fixture goes end to end into Postgres and shows on the board.

### Story 3.4: Drug stock board access gate, coverage line and Reports link

As Vikram, I want to see drug stock only for my district, so that I do not see other districts' stock.

**Unit** U5c · **Model** `grok-4.7-high` · **Cut** keep · **Deps** 2.8, 3.2 · **Status** backlog
**Owns** `heart360.drug.stock.json`
**Refs** FR-22, FR-23, NFR-1, AD-21, AD-29

**Acceptance Criteria:**
- **Given** the board, **Then** it has `isAdmin`, `isAllowed` and `requiredGroups` copied verbatim from the program dashboard, every data query ends `WHERE '$isAllowed' = '1'`, and the access banner panel is the program dashboard's.
- **Given** `district.d`, **Then** only that district's facilities show; **Given** a user with no team, **Then** the access message and no rows show.
- **Given** a district view, **Then** the All row and a coverage line (`reporting_n` of `cohort_n` facilities) come from the SQL of 3.2.
- **Given** the board, **Then** it contains a link to Reports and passes `verify_dashboard_queries.py` as `heart360tk_reader`.

### Story 3.5: Drug stock entry form (owner request 2026-11-05)

As Meera, I want to type this month's stock of each protocol medicine into a short form on the Drug Stock board, so that stock is recorded without a Google Form.

**Unit** U19 · **Model** parent · **Cut** keep · **Deps** 2.9, 2.10, 3.1, 3.4 · **Status** backlog
**Owns** `pg_init_scripts/migrations/0.6.14_to_0.6.15.sql` (`save_drug_stock_entry`), `pg_init_scripts/migrations/verify_drug_stock_entry.sh`, `h360_api/routes/stock.py`, `h360_api/tests/test_stock.py`, the entry panel and link in `heart360.drug.stock.json`, the `\ir` line for `0.6.14_to_0.6.15` in `01_heart360_tables.sql` (coordinator)
**Refs** FR-19, FR-21, FR-25, AD-16, AD-19, AD-21, Grant matrix, owner request 2026-11-05

**Acceptance Criteria:**
- **Given** the Drug Stock board with one facility selected, **Then** a panel `Enter stock` shows one number field per protocol medicine and strength from `protocol_drugs` (blank means not counted, `0` means none in stock), the month (default the current month), and a `Save stock` button; above facility level it reads `Pick one facility to enter stock.`
- **Given** `Save stock`, **Then** the browser posts to `h360-api` `POST /write/drug-stock` with `credentials:'include'` and `X-H360-Request: 1`; the API takes identity only from the Grafana session, checks `h360_access_allows` for the facility, validates whole numbers 0 to 1,000,000, and calls one `SECURITY DEFINER` function `save_drug_stock_entry` that writes through `drug_stock_pull_apply` with `submitted_by` = the Grafana login's email and `submitted_at` = now, so Latest Wins (AD-19) and history apply.
- **Given** a Viewer without access to the facility, **Then** the API returns `403` and nothing is written; a direct `/api/ds/query` write still fails (G1a unchanged).
- **Given** a save, **Then** the panel shows `Saving…` then `Saved ✓`, and the board's stock tables show the new values after refresh; the grant matrix gains `h360_api` EXECUTE on `save_drug_stock_entry` only, and `verify_security.sh` stays green.

## Epic 4: Medicine data and fake data

### Story 4.1: `medicines` catalogue and protocol drug link

As an analyst, I want one medicine catalogue, so that drug stock, the classifier and statins never disagree on a drug name.

**Unit** U6 · **Model** `claude-opus-5-5-high` (whitelist rows: `composer-2.5-fast`) · **Cut** floor (fallback in 4.3) · **Deps** 1.1 · **Status** in-progress
**Owns** `0.6.7_to_0.6.8.sql` (catalogue part), `verify_medicine_model.sh`
**Refs** FR-29, NFR-5, AD-23, CLINICAL-RULES section 4

**Acceptance Criteria:**
- **Given** the migration, **Then** `medicines` has the AD-23 columns and checks, display-case `drug_name`, lowercase `aliases` including the lowercase name, and the seed rows of CLINICAL-RULES section 4 (five protocol drugs, the non-protocol HTN list, three statins, the non-HTN list).
- **Given** the existing `protocol_drugs.drug_name` strings, **When** the FK is added, **Then** every one matches a `medicines` row first (the migration checks before adding the FK) and `protocol_drugs.drug_category = medicines.stock_category` holds in verify.
- **Given** the migration is re-run, **Then** nothing changes.

### Story 4.2: Prescription storage, `parse_obat` and CVD history

As an analyst, I want the Obat cell stored as received and parsed by one SQL function, so that no Python parser can disagree with SQL.

**Unit** U6 · **Model** `claude-opus-5-5-high` · **Cut** floor (fallback in 4.3) · **Deps** 4.1 · **Status** in-progress
**Owns** `0.6.7_to_0.6.8.sql` (tables, function, trigger), `verify_medicine_model.sh`
**Refs** FR-28, AD-24, EP-8, CLINICAL-RULES section 3

**Acceptance Criteria:**
- **Given** the CLINICAL-RULES section 3 table, **When** `parse_obat` runs, **Then** every input row returns the stated lines: `Lisinopril 10 mg - 1 x 2 Tablet Sehari` gives 20 mg a day; comma decimals and `½` parse; `amlodipin` resolves through the alias; `Xyzapril` is `unknown_drug`; `Obat herbal 2 x sehari` is `unparsed` with NULL fields; an empty string gives no lines.
- **Given** an insert or update of `prescriptions.obat_raw`, **Then** the `AFTER INSERT OR UPDATE OF obat_raw` trigger rewrites `prescription_lines`, keeps unparsed lines, and `daily_mg = strength_mg × doses_per_day × tablets_per_dose`.
- **Given** the migration, **Then** `patient_cvd_history(patient_id, event_type MI|STROKE, event_date)` exists, and `parse_obat` is an invoker function.

### Story 4.3: HTN ladder and the visit classifier

As an analyst, I want one classifier that puts every visit on the ladder, so that all reports and the chat agree.

**Unit** U6 · **Model** `claude-opus-5-5-high` · **Cut** floor; if not green at its gate, stories 5.4, 5.7, 5.8 become stubs (PD-3) · **Deps** 4.2 · **Status** in-progress
**Owns** `0.6.7_to_0.6.8.sql` (ladder, view, wrapper), `verify_medicine_model.sh`
**Refs** FR-29, SM-5, AD-25, CR-1, CLINICAL-RULES sections 5 and 6

**Acceptance Criteria:**
- **Given** `htn_ladder_steps` seeded with the six CR-1 tuples and the section 5 labels, **When** one encounter per class is classified through `visit_step`, **Then** Steps 1 to 6 match the ladder tuples.
- **And** `Lisinopril 10 mg` alone is Other Protocol; Amlodipine 10 + Lisinopril 20 + Telmisartan 80 is Other Protocol; `Losartan 50` is Non-Protocol; `Obat herbal` is Unrecognized/unreadable; no prescription is Unrecognized/no_prescription; Metformin only is Unrecognized/no_htn_medicine.
- **Given** same-drug lines, **Then** they are summed first (A67); `n_htn_drugs` and `dose_units` are returned.
- **Given** a changed ladder row in a scratch database, **Then** the bucket changes with no code edit; `classify_visit_step(encounter_id)` wraps the view.

### Story 4.4: Seed 10: visits, phones and CVD history

As Tony, I want fake patients and visits that plant the demo patterns, so that every report has something to find.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** floor · **Deps** 1.1, 4.2 · **Status** backlog
**Owns** `test_data/demo/seeds/10_visits.sql`
**Refs** FR-18, FR-30, AD-34, A32, A55, A56, A84, CLINICAL-RULES section 7

**Acceptance Criteria:**
- **Given** the seed, **Then** it starts with `SET ROLE heart360tk`, creates `demo_seed_marker(seed PK, anchor date, applied_at)` if absent, stores the anchor (newest source encounter date) and runs only if its marker row is absent.
- **Given** the plan, **Then** it adds about 220 PHC-C new patients without phones (ids from 900000001), second visits until loss targets hold, PHC-E extra 135-139 visits and 140-144 readings on non-latest visits, and `patient_cvd_history` for about 4% of patients aged 40 or older.
- **Given** all choices, **Then** they come from `md5(id||':'||salt)` and never `random()`; the seed only `INSERT`s with `ON CONFLICT DO NOTHING`.
- **Given** a second run, **Then** it is a no-op and row counts are unchanged. Numeric targets are checked in 7.2.

### Story 4.5: Seed 20: prescriptions and statin use

As Tony, I want a prescription on every visit, so that adherence, titration and statins have medicine data.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** floor (statin lines: cut-3) · **Deps** 4.3, 4.4 · **Status** backlog
**Owns** `test_data/demo/seeds/20_prescriptions.sql`
**Refs** FR-30, AD-34, A29, A56, CLINICAL-RULES section 7

**Acceptance Criteria:**
- **Given** the seed, **Then** every encounter has one `prescriptions` row from a per-patient regimen walk with start mix 70% Step 1-2, 12% Step 3-4, 6% Non-Protocol, 4% Other Protocol, 3% unreadable text and 5% no HTN medicine (counts within 1 point of the mix).
- **Given** an uncontrolled visit, **Then** a step-up happens at that visit with the facility's titration probability; eligible patients carry a statin line at the facility's statin rate.
- **Given** the trigger of 4.2, **Then** `prescription_lines` fill from the raw text; the seed never `UPDATE`s; a second run adds nothing.

### Story 4.6: Seed 30: overdue calls

As Tony, I want fake calls that follow the planted patterns, so that Overdue calls has early and late calls to compare.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** floor · **Deps** 4.4 · **Status** backlog
**Owns** `test_data/demo/seeds/30_calls.sql`
**Refs** FR-30, AD-34, A55, CLINICAL-RULES section 7

**Acceptance Criteria:**
- **Given** months 2026-05 to 2026-10, **Then** calls are inserted at each facility's called share of that month's start-of-month overdue-with-phone list, early calls drawn more often from patients who returned (about 50% early, 25% later).
- **Given** outcomes, **Then** about 50% `Agreed to visit`, 30% `Call again later`, 20% removed (PHC-C mostly `Wrong phone number`), and no `Died` and no `Pending to call` row exists.
- **Given** a second run, **Then** nothing is added; no row is updated or deleted.

### Story 4.7: Seed 40: drug stock submissions

As Tony, I want drug stock submissions that show a low CCB facility and a reverse-order submission, so that the board and the chat stock line have something to show.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** keep · **Deps** 3.1, 4.1 · **Status** backlog
**Owns** `test_data/demo/seeds/40_drug_stock.sql`
**Refs** FR-30, AD-19, AD-22, AD-34, A56

**Acceptance Criteria:**
- **Given** the six PHCs as the cohort, **Then** months 2026-09, 2026-10 and 2026-11 load through `drug_stock_pull_apply` with `submitted_by` emails, and the cohort holds no node together with its descendant.
- **Given** PHC-B November, **Then** it has two submissions in reverse time order and the newer one is stored; PHC-F leaves Chlorthalidone 25 blank in October; PHC-B October CCB Patient-Days are under 30.

### Story 4.8: Insert-only seed guard

As the coordinator, I want a check that no seed can change or delete existing rows, so that the hard rule holds on every future edit.

**Unit** U16 · **Model** `composer-2.5-fast` · **Cut** floor · **Deps** 4.4 · **Status** backlog
**Owns** `scripts/verify_seeds_insert_only.sh`
**Refs** FR-17, FR-18, NFR-2, PD-17, A13, A55

**Acceptance Criteria:**
- **Given** the seeds folder, **When** the script runs, **Then** it fails if any seed contains `UPDATE`, `DELETE` or `TRUNCATE` (case-insensitive, outside comments), and passes on the shipped seeds.
- **Given** a seed with a planted `UPDATE`, **Then** the script exits nonzero and names the file.

## Epic 5: Reports

### Story 5.1: Report common: window, thresholds and control helper

As a developer, I want one window, one threshold table and one control formula, so that all tabs and the chat use the same period and numbers.

**Unit** U7 · **Model** `claude-opus-5-5-high` · **Cut** floor · **Deps** 1.1, 2.8 (G1a) · **Status** backlog
**Owns** `0.6.8_to_0.6.9.sql` (common part), `verify_report_common.sh`
**Refs** FR-32, NFR-5, NFR-9, AD-26, AD-27, EP-3, CLINICAL-RULES section 2

**Acceptance Criteria:**
- **Given** `report_window(date)`, **Then** for month 2026-09 it returns `window_end` 2026-09-30 and `window_start` 2026-07-03; `data_end` is the newest `encounter_date::date` at or before `window_end`; NULL means the latest completed month.
- **Given** `report_flag_thresholds(report, key, value)`, **Then** it holds all 30 rows of CLINICAL-RULES section 2 and no report SQL or API code contains a threshold literal.
- **Given** `h360_control_summary(month, org)` (invoker helper), **Then** it uses `nb_patients_controlled / nb_patients_under_care_registered_before_the_past_3_months` from `heart360tk_reporting.heart360_patients_category` and returns the same control percentage as the HTN tab for a fixture node.
- **Given** the grants, **Then** `report_window` is executable by `heart360tk_reader` and `h360_api`, `PUBLIC` cannot execute it, and node selection uses `get_descendant_ids(node)` with 0 or NULL meaning all.

### Story 5.2: BP readings report SQL (`report_fudging`)

As Vikram, I want a per-facility count of readings just under and just over 140, so that I can see where readings bunch.

**Unit** U9 · **Model** `claude-opus-5-5-high` · **Cut** floor · **Deps** 5.1 · **Status** backlog
**Owns** `0.6.10_to_0.6.11.sql` (`report_fudging`), `verify_fudging.sh`
**Refs** FR-37, FR-38, NFR-8, NFR-9, AD-27, CR-4, PD-5, PD-6

**Acceptance Criteria:**
- **Given** cases (135-139, 140-144) of (541, 100), (542, 100), (200, 100), (199, 100), (12, 5), (25, 0), **Then** scores are 5.41 flagged, 5.42, 2.00 flagged, 1.99 not flagged, too few (no score), and score NULL flagged.
- **Given** `a + b < 20`, **Then** `too_few` is true and `flag` false; **Given** `b = 0` and `a + b >= 20`, **Then** the reason is `No 140-144 readings. Check how BP is measured.`
- **Given** a flag, **Then** `flag_reason` reads `{x.xx} readings just under 140 for every 1 just over. Check how BP is measured.` (20 words or fewer) and no returned string contains `fudg`.
- **Given** the columns `readings_n, band_135_139_n, band_140_144_n, score, control_pct, looks_fine_check`, **Then** `control_pct` comes from `h360_control_summary`, `looks_fine_check = flag AND control_pct >= common.high_control_pct`, rows are the selection plus level-3 children, and rates are sums over sums.

### Story 5.3: BP readings histogram (`report_fudging_histogram`)

As Vikram, I want to see the bunching as a histogram, so that I can see it without reading a number.

**Unit** U9 · **Model** `claude-opus-5-5-high` · **Cut** cut-6 · **Deps** 5.2 · **Status** backlog
**Owns** `0.6.10_to_0.6.11.sql` (`report_fudging_histogram`), `verify_fudging.sh`
**Refs** FR-38, AD-27, A39, CR-4

**Acceptance Criteria:**
- **Given** a selection, **Then** the function returns seven systolic bands 120-124 to 150-154 with `readings_n` and `highlight` true for 135-139 and 140-144; the two highlighted counts equal `band_135_139_n` and `band_140_144_n` of `report_fudging`.
- **Given** cut 6, **Then** it returns only the two highlighted bands and the tab draws two bars.

### Story 5.4: Stepping up report SQL (`report_titration`)

As Vikram, I want the share of high-BP visits followed by a stronger prescription, so that I can see where medicine is rarely stepped up.

**Unit** U8 · **Model** `claude-opus-5-5-high` · **Cut** floor (stub if 4.3 is not green) · **Deps** 5.1, 4.3 · **Status** backlog
**Owns** `0.6.9_to_0.6.10.sql`, `verify_titration.sh`
**Refs** FR-35, FR-36, NFR-9, AD-27, CR-3, PD-3, PD-6

**Acceptance Criteria:**
- **Given** month 2026-09 and fixture patients T1 to T6 plus a filler visit on 2026-09-30, **Then** T1 and T2 and T6 count as stepped up, T3 does not (its next visit is 36 days later), T4 is excluded (no baseline), T5 is excluded (too recent), giving 3 of 4 = 75.0% with `too_few` true and `flag` false.
- **Given** a second fixture of 200 uncontrolled visits with 59 stepped up, **Then** `titration_pct` is 29.5%, flagged, with reason `Medicine rarely stepped up: 29.5% of 200 high BP visits.`
- **Given** the columns, **Then** `excluded_too_recent_n` and `excluded_no_baseline_n` are returned and `control_pct` and `looks_fine_check` (flag and control at or above 60) are added to the CLINICAL-RULES column list.
- **Given** the step-up rule, **Then** ladder steps compare by `step_no`, otherwise by `n_htn_drugs` then `dose_units` (A68), and `Unrecognized` is never a step-up.
- **Given** the cut-8 or medicine-model fallback, **Then** a zero-row stub with the same columns and `h360:stub` replaces the body.

### Story 5.5: Overdue calls report SQL (`report_calling`)

As Vikram, I want to know how many overdue patients with a phone were called, how early, and who came back, so that I can see if calling works.

**Unit** U11 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 5.1 · **Status** backlog
**Owns** `0.6.12_to_0.6.13.sql` (`report_calling`), `verify_calling.sh`
**Refs** FR-41, FR-42, NFR-9, AD-27, CR-6, EP-10, A63

**Acceptance Criteria:**
- **Given** month 2026-09 and fixtures C1 to C5 with a filler visit on 2026-10-31, **Then** overdue is 3, called 2, `called_pct` 66.7, `early_pct` 50.0, returned 1 of 2 known, `too_few` true.
- **Given** the CR-6 rules, **Then** `Pending to call` rows do not count as calls, patients removed in the earlier window are not overdue, a phone needs 8 or more digits, and calls with `call_date + 30` after the newest encounter go to `return_not_yet_known_n`.
- **Given** `overdue_with_phone_n = n`, **Then** `calls_per_week = ceil(n / 4)`.
- **Given** demo data, **Then** `called_n` is at most `HEART360_OVERDUE_PATIENTS_CALLED` for the same node and month (equal on demo data); returns are not reconciled to the 15-day measure.
- **Given** flags, **Then** called under 10% and early under 50% flag, never when `too_few`, with reasons `Few overdue patients are called: 4.0%.` and `Most calls are late: 32.0% within 14 days.`

### Story 5.6: New patients report SQL (`report_new_patients`)

As Vikram, I want to know how many new patients did not come back and how many have a usable phone, so that the first lever in the chat has a number.

**Unit** U11 · **Model** `grok-4.7-high` · **Cut** keep · **Deps** 5.5 (same migration file) · **Status** backlog
**Owns** `0.6.12_to_0.6.13.sql` (`report_new_patients`), `verify_new_patients.sh`
**Refs** FR-42, NFR-9, AD-27, CR-6, A53, A54

**Acceptance Criteria:**
- **Given** window end 2026-09-30, **Then** the cohort is patients whose first encounter is in 2026-04-04 to 2026-07-02 inclusive; first visits on 2026-04-03 and 2026-07-03 are outside.
- **Given** a fixture of 10 cohort patients where 3 have no encounter within 90 days of the first, and 6 have a phone of 8 or more digits and never `Wrong phone number` (the other four: blank, blank, 5 digits, marked wrong), **Then** `new_loss_pct` is 30.0 and `new_usable_phone_pct` is 60.0, and the phone flag is false.
- **Given** fewer than 10 new patients, **Then** `too_few` is true; a phone share below 50% flags with `Few new patients have a usable phone number: 44.0%.`

### Story 5.7: Right medicines report SQL (`report_adherence`)

As Vikram, I want patients counted by medicine step with BP control, so that I can see who is off the protocol.

**Unit** U7 · **Model** `claude-opus-5-5-high` · **Cut** cut-8 (toggle: cut-4) · **Deps** 5.1, 4.3 · **Status** backlog
**Owns** `0.6.8_to_0.6.9.sql` (adherence part), `verify_adherence.sh`
**Refs** FR-33, FR-34, NFR-9, AD-27, CR-2, C16

**Acceptance Criteria:**
- **Given** month 2026-09 and nine patients, one per bucket, first visit 2026-01-01 with Steps 1 to 3 controlled and the rest not, **Then** `report_adherence_buckets` returns nine rows (`bucket_order` 1 to 9, labels from `htn_ladder_steps.label`) whose counts sum to the cohort of 9.
- **Given** a tenth patient with a first visit on 2026-08-01, **Then** it appears only when `p_include_new` is true, and `cohort_n` shows the resulting size.
- **Given** the measures, **Then** `off_protocol_pct` and `one_medicine_pct` follow CR-2; flags at 20% and 60%; `too_few` when the cohort is under 20; reasons `Many patients are on medicines outside the protocol: 23.5%.` and `Most patients stay on one medicine: 64.0%.`
- **Given** cut 4, **Then** `p_include_new` is ignored (strict only); **Given** cut 8, **Then** both functions are zero-row stubs with `h360:stub`.

### Story 5.8: Statins report SQL (`report_statins`)

As Vikram, I want the share of eligible patients on a statin per place, so that I can see where statin use is low.

**Unit** U10 · **Model** `claude-opus-5-5-high` · **Cut** cut-3 · **Deps** 5.1, 4.2 · **Status** backlog
**Owns** `0.6.11_to_0.6.12.sql` (`report_statins`), `verify_statins.sh`
**Refs** FR-39, NFR-9, AD-27, CR-5, A4, A29

**Acceptance Criteria:**
- **Given** `window_end` 2026-09-30, **Then** age 39 with `E11` is not eligible, age 40 with `E11` is eligible, age 55 with an MI on 2025-03-01 and no `E11` is eligible, and age 60 with `E11` who is dead is not eligible.
- **Given** an eligible patient whose earlier prescription had atorvastatin but whose latest prescription has none, **Then** the patient is not on a statin.
- **Given** the measures, **Then** `eligible_n`, `on_statin_n`, `on_statin_pct`, `not_on_statin_n` are returned; flag under 25% with reason `Few eligible patients are on a statin: 21.0%.`; `too_few` under 10 eligible.
- **Given** cut 3, **Then** the function is a zero-row stub with `h360:stub`.

### Story 5.9: Statins patient list SQL (`report_statins_patients`)

As Meera, I want the names of eligible patients not on a statin at my facility, so that I can review them.

**Unit** U10 · **Model** `claude-opus-5-5-high` · **Cut** cut-2 · **Deps** 5.8 · **Status** backlog
**Owns** `0.6.11_to_0.6.12.sql` (`report_statins_patients`), `verify_statins.sh`
**Refs** FR-40, NFR-7, AD-27, CR-5

**Acceptance Criteria:**
- **Given** a selection at level 3 or below, **Then** it returns `patient_id, patient_name, age, reason_eligible` (`Diabetes`, `Heart attack or stroke` or `Both`), `last_visit_date`, `org_unit_name`, and the row count equals `not_on_statin_n` of `report_statins` for the same place and month.
- **Given** a selection above level 3, **Then** it returns no rows.
- **Given** the grants, **Then** only `heart360tk_reader` can execute it and `h360_api` cannot.
- **Given** cut 2, **Then** it is a zero-row stub with `h360:stub`.

### Story 5.10: `report_flags` union

As Vikram, I want one place that lists every flagged facility and the reports that flagged it, so that the strip and the `Also flagged on` links agree with the tabs.

**Unit** U12 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 5.2, 5.4, 5.5, 5.6, 5.7, 5.8 (real or stub) · **Status** backlog
**Owns** `0.6.13_to_0.6.14.sql` (`report_flags`), `verify_report_flags.sh`
**Refs** FR-31, FR-47, AD-27, A35, EP-4, EP-13, PD-2, PD-7

**Acceptance Criteria:**
- **Given** the five reports, **Then** `report_flags(month, org)` returns `org_unit_id, org_unit_name, report, flag_reason, patients_n` for facility rows with `flag` true, where `report` is `adherence`, `titration`, `fudging`, `statins` or `calling`.
- **Given** a report that is a stub, **Then** the function still returns the other reports' flags without error.
- **Given** the seeded demo district for month 2026-10-01, **Then** PHC-E appears for `fudging` and `titration`.
- **Given** the grants, **Then** `heart360tk_reader` and `h360_api` can execute it and `PUBLIC` cannot.

### Story 5.11: Reports builder and dashboard shell

As Tony, I want one Reports dashboard assembled from one file per tab, so that tabs can be built in parallel and cut with one line.

**Unit** U13 · **Model** `grok-4.7-high` · **Cut** floor (the `include_new` variable: cut-4) · **Deps** 5.1, 2.8 · **Status** backlog
**Owns** `dashboard_src/reports/_shell.json`, `scripts/build_reports_dashboard.py`, `heart360.reports.json` (generated), `heart360.home.json`
**Refs** FR-31, FR-32, NFR-4, AD-28, AD-29, EP-7, PD-4, PD-8, PD-9, PD-19, UX-DR1

**Acceptance Criteria:**
- **Given** `_shell.json`, **Then** it defines dashboard uid `heart360_reports`, title `HEARTS360 Reports`, subtitle `Demo data. Facility names and numbers are made up.`, variables `org_unit`, `isAdmin`, `isAllowed`, `requiredGroups`, `selected_level` copied verbatim from the program dashboard, `reporting_month` (`YYYY-MM-DD` first of month, last 12 completed months, default `2026-10-01`) and `include_new` (`Established patients only` default, `Include new patients`), and the layout `RowsLayout[Change location (collapsed, tree), untitled row → TabsLayout]`.
- **Given** the shell, **Then** the Grafana time picker is hidden, and links point to the program and drug stock dashboards and `← Program dashboard`.
- **Given** the builder, **Then** a `TABS` list holds title, slug and source file for `Right medicines`/`Right-medicines` (`1-adherence.json`), `Stepping up`/`Stepping-up` (`2-titration.json`), `BP readings check`/`BP-readings-check` (`3-fudging.json`), `Statins`/`Statins` (`4-statins.json`), `Overdue calls`/`Overdue-calls` (`5-calling.json`); the list order is the tab order; removing a line drops the tab.
- **Given** a tab file with a duplicate key or a key without the prefix `panel-<slug>-`, **Then** the build fails; `--check` fails when the committed `heart360.reports.json` is stale; deep links use `/d/heart360_reports?var-org_unit=<id>&var-reporting_month=<YYYY-MM-DD>&-dtab=<slug>`.
- **Given** `heart360.home.json`, **Then** it has a `Reports` entry in its dashboard links and its redirect script is unchanged.
- **Given** the build, **Then** the dashboard opens at `/d/heart360_reports` with no panel error and its variable SQL passes `verify_dashboard_queries.py`.

### Story 5.12: Needs-a-look strip

As Vikram, I want the top facilities to look at, above the tabs, so that the landing tab does not decide whether I find the answer.

**Unit** U13 · **Model** `grok-4.7-high` · **Cut** cut-7 (then `BP readings check` is first in `TABS`) · **Deps** 5.10, 5.11 · **Status** backlog
**Owns** `dashboard_src/reports/_shell.json` (strip row)
**Refs** FR-31, A35, A74, PD-7, UX-DR2

**Acceptance Criteria:**
- **Given** the demo district and month `2026-10-01`, **Then** a row above the tabs shows at most three facilities from `report_flags`, those flagged on two or more reports first, then by `patients_n`, each with report chips that link to the matching tab with the same location and month; PHC-E is listed with chips for `BP readings check` and `Stepping up`.
- **Given** no flagged facility, **Then** the strip reads `No facility is flagged.`
- **Given** a stub report, **Then** the strip still renders from the others; the query ends `WHERE '$isAllowed' = '1'`.

### Story 5.13: Tab `BP readings check`

As Vikram, I want a tab that shows where readings bunch just under 140 and that flags a facility that looks fine, so that I can find the Kolfe-like clinic.

**Unit** U13c · **Model** `grok-4.7-high` · **Cut** floor (histogram: cut-6) · **Deps** 5.2, 5.10, 5.11 (5.3 for the full histogram) · **Status** backlog
**Owns** `dashboard_src/reports/3-fudging.json`
**Refs** FR-31, FR-32, FR-37, FR-38, NFR-4, NFR-8, PD-4, PD-5, PD-6, EP-7, EP-11, UX-DR3 to UX-DR10, UX-DR17

**Acceptance Criteria:**
- **Given** the tab, **Then** element keys start `panel-fudging-`, the title reads `Are BP readings bunching just under 140?`, the strip shows `Bunching score` (two decimals, orange at 2.00 or more), the readings of 135 to 139 and of 140 to 144, and the table columns are `Facility`, `BP controlled`, `135–139`, `140–144`, `Bunching score`, `Why look here`.
- **Given** the demo district, **Then** the first row is PHC-E with its green control number, an orange bar, `◆ Looks fine, check readings`, the flag `Readings bunch under 140`, the reason sentence, and a link `Also flagged on Stepping up` keeping the location.
- **Given** a facility with `too_few`, **Then** it shows the grey `Too few readings` pill, `—` for the score, sorts after flagged rows and before clean rows; clean rows read `No flag`; the table is sorted `Needs a look first`, never by control.
- **Given** the chart, **Then** it is a histogram with 5-point bands, a dashed line between 139 and 140 labelled `140: high BP starts`, tooltip through the shared `tip()`, and (cut 6) two bars only.
- **Given** the note, **Then** it says a high score is a reason to look at how BP is measured, lists cuff, habit, training or rounding as possible causes and says it does not prove any of them; no visible string contains `fudg`.

### Story 5.14: Tab `Stepping up`

As Vikram, I want a tab that shows the share of high-BP visits followed by stronger treatment, so that I can see where medicine is rarely stepped up.

**Unit** U13b · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 5.4, 5.10, 5.11 · **Status** backlog
**Owns** `dashboard_src/reports/2-titration.json`
**Refs** FR-31, FR-32, FR-35, FR-36, NFR-4, PD-4, PD-6, PD-8, EP-7, EP-11, UX-DR3 to UX-DR10, UX-DR17

**Acceptance Criteria:**
- **Given** the tab, **Then** element keys start `panel-titration-`, the strip shows the percent stepped up (green at 40% or more, orange under), the high-BP visits counted, and the visits left out (`{a} too recent to check, {b} with no earlier prescription`).
- **Given** the chart, **Then** it is bars by facility with a dashed line labelled `Flag line: 40%` and no month line chart.
- **Given** the table, **Then** columns are `Facility`, `BP controlled`, `High-BP visits`, `Stepped up`, `Share stepped up`, `Why look here`, sorted flagged first then by high-BP visits.
- **Given** PHC-E, **Then** its row shows `◆ Looks fine, check medicines`, the flag `Medicine rarely stepped up`, its reason, and `Also flagged on BP readings check`.
- **Given** a facility with fewer than 10 visits, **Then** it shows the grey `Too few visits` pill and `Need at least 10; this place has {n}.`

### Story 5.15: Tab `Overdue calls`

As Vikram, I want a tab that shows whether overdue patients are called early and come back, so that I can see if calling works.

**Unit** U13e · **Model** `grok-4.7-high` · **Cut** floor (new patients row: keep) · **Deps** 5.5, 5.6, 5.10, 5.11 · **Status** backlog
**Owns** `dashboard_src/reports/5-calling.json`
**Refs** FR-31, FR-32, FR-41, FR-42, NFR-4, PD-4, PD-10, EP-7, EP-12, UX-DR3 to UX-DR10, UX-DR19

**Acceptance Criteria:**
- **Given** the tab, **Then** element keys start `panel-calling-`, the strip shows Called, Calls made early, and `Came back within 30 days` with a muted line `The Overdue tab counts 15 days.`, and the tab note repeats that line.
- **Given** the chart, **Then** two bars (`Called within 14 days`, `Called later`) show the share who came back, with end label `{p}% · {n} of {N}`.
- **Given** the side card `What happened on the calls`, **Then** it lists Agreed to visit, Call again later, Removed from list, the total, and a link `Open the overdue list to call` to the program dashboard Overdue tab with the same location.
- **Given** the table, **Then** columns are `Facility`, `Overdue with a phone`, `Called`, `Calls made early`, `Came back`, `Why look here`, with flags `Few called`, `Mostly late calls`, `Few phone numbers` (from the new-patient phone flag), `Too few patients`, and at most two pills per row.
- **Given** the `New patients` row, **Then** it shows the loss share and usable-phone share from `report_new_patients` with `n of N`.
- **Given** the calls total, **Then** it matches the call plan total in the chat for the same place and month.

### Story 5.16: Tab `Right medicines`

As Vikram, I want a tab that shows patients by medicine step and how many are controlled, so that I can see who is off the protocol.

**Unit** U13a · **Model** `grok-4.7-high` · **Cut** cut-8 (toggle: cut-4) · **Deps** 5.7, 5.10, 5.11 · **Status** backlog
**Owns** `dashboard_src/reports/1-adherence.json`
**Refs** FR-31, FR-32, FR-33, FR-34, NFR-4, PD-4, EP-7, C16, UX-DR3 to UX-DR10, UX-DR17

**Acceptance Criteria:**
- **Given** the tab, **Then** element keys start `panel-adherence-`, the strip shows BP controlled, on two or more medicines, and off protocol, and the subtitle prints the patients counted and the window end.
- **Given** the chart, **Then** it has nine horizontal bars in the indigo ramp with labels from `htn_ladder_steps.label`, end label `{n} patients · {p}% controlled`, and the nine counts sum to the cohort.
- **Given** the `Patients counted` variable, **When** switched to `Include new patients`, **Then** only the cohort changes and its size is printed (cut 4: no toggle).
- **Given** the table, **Then** columns are `Facility`, `Patients`, `On 2 or 3 medicines`, `Off protocol`, `BP controlled`, `Why look here`, with flags `Many off protocol`, `Mostly one medicine`, `Too few patients`.
- **Given** cut 8, **Then** the file is removed from `TABS` and the report functions are stubs.

### Story 5.17: Tab `Statins`

As Vikram, I want a tab that shows the share of eligible patients on a statin, so that I can see where statin use is low.

**Unit** U13d · **Model** `grok-4.7-high` · **Cut** cut-3 (`Patients to review` row: cut-2) · **Deps** 5.8, 5.10, 5.11 (5.9 for the list) · **Status** backlog
**Owns** `dashboard_src/reports/4-statins.json`
**Refs** FR-31, FR-32, FR-39, FR-40, NFR-4, PD-4, PD-8, EP-7, UX-DR3 to UX-DR10, UX-DR17, UX-DR18

**Acceptance Criteria:**
- **Given** the tab, **Then** element keys start `panel-statins-`, the strip shows eligible, on a statin and not on a statin, and the chart is bars by facility with a dashed line labelled `Flag line: 25%`, no month line chart.
- **Given** the table, **Then** columns are `Facility`, `Eligible`, `On a statin`, `Not on a statin`, `% on a statin`, `Why look here`, with flags `Few on a statin` and `Too few patients`; no download link appears anywhere on the tab.
- **Given** a facility selection, **Then** the `Patients to review` row shows chips `All`, `Diabetes`, `Heart attack or stroke`, `Both` with counts, search by name or Patient ID, 20 rows per page, and its header count equals `not_on_statin_n`.
- **Given** a selection above facility level, **Then** the banner `The patient list is available only at the facility level.` shows.
- **Given** cut 2, **Then** the row is removed; **Given** cut 3, **Then** the file leaves `TABS`.

### Story 5.18: Overdue section on the Hypertension tab (owner request 2026-11-05)

As Vikram, I want overdue patients, overdue patients called and overdue patients who returned to care on the Hypertension tab, so that the follow-up story sits next to control.

**Unit** U20 · **Model** parent · **Cut** keep · **Deps** 1.1 · **Status** backlog
**Owns** the Hypertension tab of `heart360.hypertension-diabetes.program.json` (this section only), the baseline in `scripts/check_htn_dm_untouched.py`
**Refs** owner request 2026-11-05 (supersedes NFR-1 for this section only), hearts360 overdue charts on `origin/0.3.9` (`heart360.facility.dashboard.json` panels 13 to 16), DESIGN tokens, shared `tip()`

**Acceptance Criteria:**
- **Given** the Hypertension tab, **Then** a section `Overdue patients` sits directly above the facility comparison chart at the bottom, built as one continuous card in the same style as the redesigned key indicators section (not three loose panels).
- **Given** the section, **Then** it shows the three measures from the 0.3.9 charts (Overdue patients, Overdue patients called, Overdue patients that returned to care) with their monthly trend, the headline number for the reporting month, and `n of N` lines, using the same queries and definitions as 0.3.9 adapted to the current schema and the `isAllowed` gate.
- **Given** the change, **Then** no other Hypertension or Diabetes panel changes, `check_htn_dm_untouched.py` compares against the new reviewed baseline and exits 0, and `verify_dashboard_queries.py` passes with every new query under 2 s.

## Epic 6: Chat

### Story 6.1: Chat SQL: control summary, stock gate and call plan

As the chat, I want stored queries for control, stock and the call plan, so that every number I say comes from SQL that matches a tab.

**Unit** U12 · **Model** `grok-4.7-high` · **Cut** floor (stock gate: keep) · **Deps** 5.1, 5.5, 5.10 (same migration file), 3.2 · **Status** backlog
**Owns** `0.6.13_to_0.6.14.sql` (`chat_control_summary`, `chat_drug_stock_gate`, `chat_call_plan`), `verify_chat_levers.sh`
**Refs** FR-46, FR-47, NFR-9, AD-27, AD-31, EP-3, EP-10

**Acceptance Criteria:**
- **Given** a fixture place, **Then** `chat_control_summary` equals `h360_control_summary` and the `control_pct` of `report_fudging` for the same place and month, with `under_care_n, controlled_n, controlled_pct, uncontrolled_n, uncontrolled_pct, missed_visit_pct, ltfu_pct`.
- **Given** PHC-B October CCB Patient-Days under 30, **Then** `chat_drug_stock_gate` returns `low` true for category CCB, using `chat.stock_days_below`.
- **Given** 86 overdue patients with a phone, **Then** `chat_call_plan` returns weeks 22, 22, 22 and 20 (EP-10) and the total equals `overdue_with_phone_n` of `report_calling`.
- **Given** the grants, **Then** these functions go to `h360_api` only.

### Story 6.2: Chat SQL: district facility ranking

As Vikram, I want facilities in a district ranked by uncontrolled patients, so that the chat can name three to visit.

**Unit** U12 · **Model** `grok-4.7-high` · **Cut** cut-9 · **Deps** 6.1 · **Status** backlog
**Owns** `0.6.13_to_0.6.14.sql` (`chat_facility_rank_district`), `verify_chat_levers.sh`
**Refs** FR-47, AD-31, CLINICAL-RULES section 1

**Acceptance Criteria:**
- **Given** a district, **Then** it returns `org_unit_id, org_unit_name, uncontrolled_n, breaches, also_check, rank`, ranked by `uncontrolled_n`, with `breaches` listing the Chattogram lines hit (control under 50, uncontrolled over 20, missed visits over 25, LTFU over 20) from `report_flag_thresholds`.
- **Given** a facility with control at 60% or more and a fudging or titration flag, **Then** `also_check` is true.
- **Given** cut 9, **Then** the function is a zero-row stub with `h360:stub`.

### Story 6.3: Chat registry, chips and access

As Vikram, I want chips that only offer questions the system can answer, so that I never see a dead button.

**Unit** U14 · **Model** `grok-4.7-high` · **Cut** floor (chips beyond three: cut-5; `statin_gap` chip with cut-3) · **Deps** 2.2, 2.8, 2.9, 5.10, 6.1 · **Status** backlog
**Owns** `h360_api/registry.py`, `h360_api/routes/chat.py` (chips and request handling), `h360_api/tests/test_registry.py`
**Refs** FR-43, FR-44, NFR-7, AD-30, EP-5, EP-6, PD-12, UX-DR12

**Acceptance Criteria:**
- **Given** the registry, **Then** it is a dict keyed `control_summary`, `new_patient_return`, `phone_capture`, `overdue_calling`, `titration_rate`, `fudging_score`, `statin_gap`, `drug_stock_gate`, `facility_rank_district`, `call_plan`, each naming one SQL function with only `org_unit_id` and `reporting_month` as parameters, and `first_appointment_gap` is absent.
- **Given** a scope node, **When** `h360_access_allows` refuses, **Then** the API returns `403` and the widget text is `You do not have access to this place.`
- **Given** `GET /chat/chips?org_unit_id&reporting_month`, **Then** it returns `{scope, place, month, mode, chips: [{id, label}]}` with scope facility for level 3 and below (the level-3 ancestor), district for level 2, national for level 1 or empty (single chip `Pick a district`).
- **Given** a function that carries `h360:stub`, **Then** its chip is absent; the facility floor is `why_control_low`, `who_to_call` plus `readings_reliable` or `medicines_adjusted`; chip ids and labels are exactly the UX table.
- **Given** typed text of up to 200 characters, **Then** a keyword table maps it to a chip, otherwise the reply is `I can only answer the questions above. Pick one.`
- **Given** `POST /chat` with `{"chip_id"|"text", "org_unit_id", "reporting_month"}` and no month, **Then** the latest completed month applies; no code path runs SQL other than the registry's functions.

### Story 6.4: Evidence ranker

As Vikram, I want reasons ranked by evidence and by how far the place is from target, so that the first reason is the one most worth acting on.

**Unit** U14 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 6.3, 5.6 · **Status** backlog
**Owns** `h360_api/ranker.py`, `h360_api/tests/test_ranker.py`
**Refs** FR-45, FR-47, AD-31, A57, A78, PD-11

**Acceptance Criteria:**
- **Given** facts with new-patient loss over 25%, usable phone under 90%, called under 10% or early under 50%, and titration under 40%, **Then** triggered levers are ordered by tier then gap, at most three; with fewer than two triggered, the list pads to two with the lowest-tier untriggered lever worded as on target; with no data or too few, one plain sentence and no ranking.
- **Given** any protocol category under 30 Patient-Days, **Then** calling and titration reasons get `Fix stock first.` and a stock line is added.
- **Given** control of 60% or more (PD-11), **Then** the title is `What to check at {place}? {x}% controlled, looks fine.`, flagged fudging or titration rows for the place come first (at most two), then triggered levers up to three in total, and at facility scope `Also check` describes this facility.
- **Given** control below 60%, **Then** `Also check` names at most one other place in scope with control at 60% or more and a fudging or titration flag.
- **Given** the same inputs, **Then** the output is identical on every run (unit tests with fixed facts); control percentages come from `chat_control_summary`.

### Story 6.5: Offline wording, plan and honesty line

As Vikram, I want a written answer with a plan and the honesty line even with no network, so that the demo works anywhere.

**Unit** U14 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 6.4 · **Status** backlog
**Owns** `h360_api/wording.py` (offline part), `h360_api/tests/test_wording.py`
**Refs** FR-45, FR-46, FR-48, FR-49, NFR-7, NFR-8, AD-30, AD-32, PD-5, PD-13, PD-14, A47

**Acceptance Criteria:**
- **Given** no `ANTHROPIC_API_KEY`, **When** each live chip is asked, **Then** the answer has the shape `{mode, place, month, reasons, also_check, stock_line, nudge, plan, honesty, links}` with `mode` `offline`, at most three reasons, no sentence over 20 words and at most 150 words before the honesty line, and returns in under 3 s on demo data.
- **Given** every registry answer, **Then** `honesty` is present verbatim (`These actions explain only 2% to 12% of why one facility does better than another. Treat them as the best next steps, not a promise.`) and no user-visible `h360_api` string contains `will`, `guarantee`, `guarantees`, `guaranteed` or `fudg`.
- **Given** the nudge, **Then** the plan total equals `overdue_with_phone_n` of the Overdue calls tab for the same place and month and the plan text starts with the patients overdue longest.
- **Given** `who_to_call`, **Then** it returns one reason plus the plan inline with nudge `Who is overdue longest?` linking to the overdue list; report links use the PD-4 slugs and the scope node id.
- **Given** a number token in an answer, **Then** it appears in the facts JSON for that place and month.

### Story 6.6: Claude wording

As Tony, I want Claude to rewrite the sentences when a key is set, so that the answer reads better without changing a number.

**Unit** U14 · **Model** `grok-4.7-high` · **Cut** cut-1 · **Deps** 6.5 · **Status** backlog
**Owns** `h360_api/wording.py` (Claude part), `h360_api/tests/test_claude.py`
**Refs** FR-49, FR-48, NFR-7, NFR-8, AD-32, A26, A58

**Acceptance Criteria:**
- **Given** `ANTHROPIC_API_KEY` is set, **Then** one `messages.create` call (model `ANTHROPIC_MODEL`, default `claude-sonnet-5-5`, 8 s timeout) rewrites only the facts JSON sentences, and the payload contains no patient rows, names or ids.
- **Given** a reply, **Then** every number token is in the facts, no `will` or `guarantee*`, no sentence over 20 words and at most 150 words; any failure or timeout gives the offline answer with `mode = offline_fallback`.
- **Given** the honesty line, **Then** the server appends it after the checks and never sends it through Claude; the key is read from the environment only and appears in no log, response, browser file or repository file.
- **Given** tests with a fake client, **Then** they pass with no network.

### Story 6.7: District answers (`visit_first`)

As Vikram, I want the chat to name up to three facilities to visit first, so that I can plan the week at district level.

**Unit** U14 · **Model** `grok-4.7-high` · **Cut** cut-9 · **Deps** 6.2, 6.5 · **Status** backlog
**Owns** `h360_api/registry.py` (district entries), `h360_api/ranker.py` (district ranking), `h360_api/tests/test_district.py`
**Refs** FR-47, AD-30, AD-31, PD-12, UX-DR12

**Acceptance Criteria:**
- **Given** a district, **When** `visit_first` is asked, **Then** facilities with a Chattogram breach are sorted by uncontrolled patients, the top three are returned, the third slot is reserved for an `also_check` facility if one exists, and the nudge is `Why is control low at {first facility}?`
- **Given** district scope, **Then** the chips are `why_control_low`, `visit_first`, then the facility chips (six at most).
- **Given** cut 9, **Then** `visit_first` is absent and the district falls back to the facility chips.

### Story 6.8: Widget injection, button, panel and chips

As Vikram, I want a floating button on every dashboard that opens a chip panel, so that I can ask a question without leaving the page.

**Unit** U15 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 2.9, 6.3 (contract) · **Status** backlog
**Owns** `docker_build/grafana_public/h360/chat-widget.js`, `docker_build/heart360.grafana.docker`
**Refs** FR-43, NFR-7, AD-17, AD-33, A17, A40, A82, UX-DR11, UX-DR12, UX-DR14, UX-DR15

**Acceptance Criteria:**
- **Given** the Grafana image build, **Then** the file is copied to `/usr/share/grafana/public/h360/` and `<script nonce="[[.Nonce]]" src="public/h360/chat-widget.js" defer></script>` is inserted before the single `</body>` of `public/views/index.html`; the build fails unless the tag appears exactly once.
- **Given** a signed-out page, **Then** nothing renders; **Given** `window.grafanaBootData.user.isSignedIn`, **Then** the `Ask HEARTS360` pill shows bottom right (right 64px, bottom 20px, 48px high).
- **Given** the URL, **Then** `var-org_unit` is read from `location.search` on load, on `popstate` and by a 1 s poll, and `var-reporting_month` is sent only on `/d/heart360_reports`.
- **Given** the panel, **Then** it opens at 380px wide with header `{place} · {Mon-YYYY}` and `Hypertension only`, chips from `/chat/chips` (never a blank box), a secondary 200-character text box, and `Pick a district` at national scope closes the panel, expands Change location and focuses its search.
- **Given** the code, **Then** it calls only `H360_API` with `credentials:'include'` and `X-H360-Request: 1`, never Postgres or Claude, and `Esc` closes the panel and returns focus to the button.

### Story 6.9: Widget answer card, plan card, badges and clearance

As Vikram, I want a readable answer, a plan card and a pill that never covers my pager, so that the chat is usable on a small screen.

**Unit** U15 · **Model** `grok-4.7-high` · **Cut** floor · **Deps** 6.5, 6.8 · **Status** backlog
**Owns** `docker_build/grafana_public/h360/chat-widget.js`
**Refs** FR-43, FR-45, FR-46, FR-48, NFR-8, A47, A79, A80, A82, PD-13, PD-14, PD-15, UX-DR9, UX-DR13 to UX-DR16

**Acceptance Criteria:**
- **Given** an answer, **Then** the card shows the title and control line, up to three numbered reasons with `What to do`, the nudge button and the `See this in Reports: <tab>` link, the `Also check` line, the stock callout, and the draw order of UX-DR13; it renders only the fields of the API contract.
- **Given** the nudge click, **Then** the plan card shows the total, four week cells, the line `Start with the patients overdue longest.` and `Open the overdue list`; a second click scrolls to it.
- **Given** a thread, **Then** the honesty line is drawn once, last, after the plan card.
- **Given** `mode`, **Then** the badge reads `Written from your reports` or `Claude wording`, with a `title` that says the numbers are the same; on `offline_fallback` the line `Claude was not available, so this is written from a template.` shows.
- **Given** loading, **Then** a skeleton and `Looking at your reports…` show, `Still working…` at 3 s and the error card at 10 s; signed-out shows `Your session ended. Reload the page and sign in.`; 403 shows `You do not have access to this place.`
- **Given** the page, **Then** 72px of bottom scroll padding is added to Grafana's page container; if the selector fails, a 48px icon-only pill is used; the Overdue pager and a Reports table pager stay clickable at 1366x768 and 125% zoom.
- **Given** accessibility, **Then** chips are buttons in a labelled group, answers land in a `role="log"` live region with focus on the answer title, targets are at least 36px and motion is off under `prefers-reduced-motion`.

## Epic 7: Verification and demo readiness

### Story 7.1: `verify_all.sh`

As the coordinator, I want one script that runs every check for the shipped features, so that a single green run freezes the demo.

**Unit** U17 · **Model** `grok-4.7-high-fast` · **Cut** floor · **Deps** 2.6, 2.8, 4.8, 5.11 · **Status** backlog
**Owns** `scripts/verify_all.sh`
**Refs** FR-18, NFR-1, NFR-9, AD-35, PD-17, PD-22

**Acceptance Criteria:**
- **Given** the stack, **When** the script runs with `PSQL="docker exec -i postgres psql -U h360tk_root"`, **Then** it runs every shipped `verify_*.sh`, `verify_dashboard_queries.py`, `verify_security.sh` (part 1, and part 2 when G1b ships), `check_htn_dm_untouched.py`, `build_reports_dashboard.py --check`, `verify_seeds_insert_only.sh`, the `h360_api` tests and 7.3, and fails on the first failure naming it.
- **Given** a cut report, **Then** its verify script is removed from the script's shipped list with it.
- **Given** `demo_up.sh` run twice, **Then** the script compares `patients`, `encounters`, `prescriptions` and `call_results` counts and fails on any difference.

### Story 7.2: Seed target and pill check

As Tony, I want the planted numbers printed and checked, so that the demo patterns are real before I rehearse.

**Unit** U17 · **Model** `grok-4.7-high-fast` · **Cut** floor · **Deps** 4.4, 4.5, 4.6, 5.2, 5.4, 5.5, 5.10 · **Status** backlog
**Owns** `scripts/verify_seed_targets.sh`
**Refs** FR-30, SM-3, SM-5, AD-34, PD-17, A56, CLINICAL-RULES section 7

**Acceptance Criteria:**
- **Given** month 2026-10-01, **Then** the script prints each facility's control, bunching score, titration, new-patient loss, usable phone, called, early, on-statin and CCB Patient-Days and fails when a value is outside the CLINICAL-RULES section 7 target range (for shipped reports).
- **Given** the `looks_fine_check` columns, **Then** exactly one facility, PHC-E, carries the pill, and the others sit near 60% control without flipping.

### Story 7.3: Banned-word and plain-language check

As the coordinator, I want every visible string checked for banned words and length, so that neutral wording cannot regress.

**Unit** U17 · **Model** `grok-4.7-high-fast` · **Cut** floor · **Deps** 5.13, 5.14, 5.15, 6.5 · **Status** backlog
**Owns** `scripts/verify_banned_words.py`
**Refs** FR-48, NFR-8, PD-5, UX-DR10

**Acceptance Criteria:**
- **Given** the generated Reports dashboard, the other provisioned dashboards' new strings, the report function outputs and the `h360_api` answer strings, **Then** the script finds no `fudg`, `will`, `guarantee`, `guarantees` or `guaranteed` in user-visible text (internal ids and element keys are excluded).
- **Given** every flag reason and chat sentence, **Then** none exceeds 20 words; a planted violation makes the script exit nonzero.

### Story 7.4: Fresh install, upgrade parity and clean boot

As the coordinator, I want a fresh install and an upgrade from 0.6.0 to end at the same schema, so that the migration chain is trustworthy.

**Unit** U17 · **Model** `grok-4.7-high-fast` · **Cut** floor · **Deps** 5.10, 6.1 · **Status** backlog
**Owns** `scripts/verify_upgrade_path.sh`
**Refs** FR-15, FR-16, NFR-5, AD-13

**Acceptance Criteria:**
- **Given** a scratch database at 0.6.0, **When** the 0.6.x files run in `\ir` order with `psql -U h360tk_root`, **Then** its normalised `pg_dump --schema-only` equals a fresh install's.
- **Given** the chain is run twice, **Then** the second run changes nothing; **Given** an empty volume, **Then** `docker compose up -d --build` starts with no errors and the program and drug stock dashboards show data.

### Story 7.5: Chat verification

As Tony, I want every chip tested against the reports, so that a number in the chat is a number on a tab.

**Unit** U17 · **Model** `grok-4.7-high-fast` · **Cut** floor · **Deps** 6.5, 6.9, 7.2 · **Status** backlog
**Owns** `scripts/verify_chat.sh`
**Refs** FR-43 to FR-49, SM-3, NFR-7

**Acceptance Criteria:**
- **Given** the stack with no key, **When** every chip is asked at PHC-E and at the district as `district.d`, **Then** each answers in under 3 s with the honesty line, and each number appears in the matching report function for that place and month.
- **Given** a user without access to a place, **Then** the answer is `403`; **Given** a grep of the browser files, logs and repository, **Then** no API key value is found.
- **Given** PHC-E (control 72-78%), **Then** the title is `What to check at PHC-E?…` and the first reasons are the fudging and titration flags.

### Story 7.6: Slow-laptop browser pass

As Tony, I want the demo path checked at 1366x768 and 125% zoom, so that it works on a slow laptop.

**Unit** U17 · **Model** `grok-4.7-high-fast` · **Cut** floor · **Deps** 6.9, 5.13, 5.14, 5.15, 2.6 · **Status** backlog
**Owns** no product files (evidence under `_bmad-output/implementation-artifacts/`)
**Refs** NFR-6, PD-15, PD-18

**Acceptance Criteria:**
- **Given** 1366x768 at 125% zoom and a 4x CPU throttle, **When** the run order is walked (strip, `BP readings check`, `Stepping up`, chat at PHC-E, plan card, Overdue save), **Then** each tab renders in under 5 s and no step fails.
- **Given** a tab switch, **Then** hidden tabs fire no `/api/ds/query` calls; a tab that runs the same `report_*` call in four or more panels and is slow shares one query through the Dashboard datasource.
- **Given** the chat pill, **Then** it does not cover the Overdue pager or a Reports table pager.

### Story 7.7: Report docs, demo runbook and image freeze

As Tony, I want a short runbook and one page per report, so that I can run the demo and explain each number.

**Unit** U18 · **Model** `claude-sonnet-5-5-high` · **Cut** floor · **Deps** 7.1 to 7.6 · **Status** backlog
**Owns** `docs/reports/*.md`, PRD, UX and epics touch-ups
**Refs** SM-1, SM-2, PD-20, PD-21, A8, A83, A84

**Acceptance Criteria:**
- **Given** `docs/reports/`, **Then** one page per shipped report states its rule in plain words, including the ladder (`protocol-adherence.md`, A3).
- **Given** `docs/reports/demo-runbook.md`, **Then** it lists the run order (strip, BP readings check, Stepping up, chat at PHC-E, plan card, Overdue save), the rule to open only `http://localhost:3000`, the pinned month and how to revert it, the output of `docker images --digests`, the rule `no docker pull and no build after the last green verify_all.sh`, and the note that HTN/DM tab numbers moved because of seeds while tab definitions did not (A84).

### Story 7.8: Rehearsal and backup recording

As Tony, I want one rehearsal by someone who did not build it and a backup video, so that the demo survives bad luck.

**Unit** U17 and U18 · **Model** `grok-4.7-high-fast` (clean run) with the owner or a stand-in (human step) · **Cut** floor · **Deps** 7.7 · **Status** backlog (needs a human)
**Owns** no product files
**Refs** SM-1, SM-2, PD-22

**Acceptance Criteria:**
- **Given** `docker compose down -v` then `./scripts/demo_up.sh`, **Then** the stack is ready in 15 minutes or less and a second run changes no row counts.
- **Given** a person who did not build the product, **Then** they name the facility to visit first, and why, in two minutes.
- **Given** the run order, **Then** one screen video of it is recorded and stored outside the repository.

### Story 7.9: UX audit of all dashboards (owner request 2026-11-05)

As Tony, I want one usability pass over every dashboard after the build, so that the whole product is easy to navigate.

**Unit** U21 · **Model** parent · **Cut** floor · **Deps** 5.11 to 5.18, 3.5, 6.9 · **Status** backlog
**Owns** `_bmad-output/implementation-artifacts/ux-audit-2026-11.md`; fixes land in the owning files with the owner's stories
**Refs** EXPERIENCE.md, DESIGN.md, review-2026-11 copy findings

**Acceptance Criteria:**
- **Given** the Reports tabs, the Hypertension and Diabetes tabs, the Overdue list and the Drug Stock board, **Then** each is walked in the browser at 1366x768 and findings are listed with a screenshot reference, severity and the fix.
- **Given** the Reports navigation, **Then** the audit names what makes it confusing and the fix (tab order, strip, links back and forth) is applied.
- **Given** every finding rated must-fix, **Then** it is fixed and re-checked, and the Overdue list keeps its current behaviour.
