---
title: HEARTS360 MVP - merged toolkit, five reports, medicine data, floating chat
status: final
created: 2026-11-04
updated: 2026-11-04
---

# PRD: HEARTS360 MVP

*Working title. Internal prototype for a demo on 2026-11-05. Owner: Tony Joy, Resolve to Save Lives.*

## 0. Document Purpose

This PRD defines one integration branch of the HEARTS360 toolkit (`h360tk_grafana_core`). It joins the cascade, cohort and overdue-list work (on 0.6.0) with the drug stock work, fixes five named drug stock bugs and one security hole, adds five reports and Postgres storage for medicine data, and ends with a small AI chat floating over Grafana. Audience: the owner, then UX, architecture and epics. Vocabulary follows the drug stock PRD (`prd-h360-toolkit-internal-2026-09-22`), whose FR-1 to FR-14 are settled and not re-decided here. Numbering continues from it, so FR ids and UJ ids are unique across both documents [ASSUMPTION A28].

Inputs: the goals and context files, `recon.md` (observed facts; wins over the context file, for example on which repos are unreachable), and `ASSUMPTIONS.md` (A1-A17, settled, cited by id). Items inferred tonight carry `[ASSUMPTION A18+]`; the full list is in section 9. Mechanism (tables, queries, endpoints, fake-data spec) is in `addendum.md`.

Because the private repos and the research files could not be reached (A2, A10), the clinical rules below are rebuilt from the context file and written in plain words. Each is replaceable in one place.

## 1. Vision

A program manager opens HEARTS360 and wants to know three things: which facilities need attention, why, and what to do on Monday. Today the toolkit shows reach, control and an overdue list, but nothing about medicines, nothing that says a facility with good numbers may still be a problem, and nothing that turns a chart into a plan.

This MVP closes that gap in the simplest way that works. The cascade and drug stock work sit on one branch. Five reports read from one medicine record: titration, protocol adherence, BP fudging, statins and overdue calling. A small chat answers "why is my BP control low?" with two or three ranked reasons, each with a number, a what-to-do block and a nudge into a real plan.

The bet: a rough report a program manager understands beats a complete report that confuses them. Every screen is judged by one question: can a district program manager name the facility to visit, and why, within two minutes?

## 2. Target User

### 2.1 Jobs To Be Done

- **Program manager (functional):** See which facilities need attention this month and why, including facilities whose headline numbers look fine.
- **Program manager (functional):** Turn that into a short plan the manager can commit to: who to call, which clinic to visit, which medicine step to push.
- **Facility manager (functional):** Same questions for my own facility only.
- **Owner (contextual):** Put a working, honest prototype in front of people tomorrow and learn from it. Honest means it never claims more than the evidence supports.

### 2.2 Non-Users (v1)

- Clinicians who need patient-level decision support (no per-patient advice, no per-clinician scores).
- National operators. Diabetes users: the chat and new reports are hypertension only (A9).
- Anyone expecting production hardening, real medicine data feeds or a signed Grafana plugin.

### 2.3 Key User Journeys

Single main operator role, so journeys are short.

**UJ-3. Vikram finds the clinic that looks fine but is not.**
Vikram, district program manager, is signed in with district access. He opens the Reports dashboard, picks his district in Change Location, and opens BP fudging. One facility shows a green control rate of 74% but a fudging score of 4.8 and a flag. He opens Titration: same facility, 27% of uncontrolled patients had medicine stepped up. A plain note says why each flag fired. He decides to visit that facility first. **Edge case:** a facility with too few readings shows "Too few readings", not a score.

**UJ-4. Vikram asks the chat why control is low.**
On the facility dashboard, Vikram clicks the floating chat button. He sees chips, not a blank box: "Why is my BP control low?", "Who should I call this week?", and others. He clicks the first. The answer lists two reasons ranked by evidence, for example "28% of new patients did not come back for a second visit", each with a what-to-do block and a nudge: "How many patients should I call?" He clicks the nudge and gets a number and a four-week split. The answer ends with the honesty line. **Edge case:** no API key; the answer still appears, labelled "Offline: written from a template".

**UJ-5. Meera calls patients early.**
Meera, facility nurse, opens the Overdue tab (unchanged look), changes a patient's status to "Agreed to visit", and sees "Saved". Behind the scenes the save now goes through the server, not the browser. Later Vikram opens Overdue calling and sees how many overdue patients with a phone were called, how early, and how many came back. **Edge case:** a Viewer who sends the same write straight to Grafana's query API is refused.

**UJ-6. The owner runs the demo from a clean laptop.**
Tony runs one command, waits, and opens Grafana. HTN and DM tabs look exactly as before. Drug stock, Reports and the chat are there, with realistic fake data. **Edge case:** he runs the command twice; nothing is deleted or duplicated.

## 3. Glossary

Terms from the drug stock PRD (Drug Stock, In-Stock, Patient-Days, Org Unit, Change Location, Leaf Grafana, Latest Wins, Stock Submission, Protocol Drug) keep their meaning. New terms:

- **Integration Branch** — `cursor/hearts360-mvp-7579`: cascade work on 0.6.0 plus drug stock plus BMAD install.
- **Viewer** — Any signed-in Grafana user without edit rights. Can reach every datasource through `/api/ds/query` in open-source Grafana.
- **h360-api** — Small server-side service (A16) that checks the Grafana session, applies location access and performs writes through a `SECURITY DEFINER` function. Also serves the chat.
- **Obat** — The Indonesian-format medicine cell, for example `Lisinopril 10 mg - 1 x 2 Tablet Sehari`, meaning 1 tablet, 2 times a day, 20 mg per day (A2).
- **Prescription Line** — One medicine entry parsed out of an Obat cell.
- **Step** — Position 1-6 on the HTN medication ladder [ASSUMPTION A18]. Also **Other Protocol**, **Non-Protocol** and **Unrecognized**.
- **Controlled** — Systolic under 140 and diastolic under 90 at a visit.
- **Window** — The 90 days before the newest visit in the database.
- **Established Patient** — Registered before the Window started. **Strict** counts only these; **Lenient** adds newer registrations.
- **Report Tab** — One of five tabs on the HEARTS360 Reports dashboard [ASSUMPTION A22].
- **Flag** — A visible "needs a look" marker on a facility row, always with a plain reason.
- **Fudging Score** — Readings with systolic 135-139 divided by readings with systolic 140-144, last 3 months (A5).
- **Titration Rate** — Share of uncontrolled visits whose medicine was stepped up at that or the next visit [ASSUMPTION A19].
- **Statin-Eligible** — Alive, under care, age 40 or older, and diabetes or a recorded heart attack or stroke (A4).
- **Early Call** — First call within 14 days of becoming overdue [ASSUMPTION A21].
- **Evidence Table** — The ranked list of levers in section 4.7 that orders every chat answer.
- **Offline Mode** — Chat answers written by a template from the same numbers, with no API key (A7).

## 4. Features

### 4.1 One integrated branch

**Description:** Everything built so far lives on one branch that starts clean from a fresh install. Realizes UJ-6.

#### FR-15: Merge cascade and drug stock

The Integration Branch holds the cascade, cohort, styling and overdue-list work and the drug stock work, with all dashboards provisioned.

**Consequences (testable):**
- `docker compose up -d --build` on an empty volume starts Postgres and Grafana with no errors.
- The program dashboard (uid `heart360_showcase`) and the drug stock dashboard both open and show data.

#### FR-16: Migrations renumbered onto the 0.6.x line

Drug stock migrations run as `0.6.0_to_0.6.1` through `0.6.4_to_0.6.5` after the 0.6.0 schema, in order (A14). New work continues from `0.6.5`.

**Consequences (testable):**
- Fresh install and an upgrade from a 0.6.0 database both end at the same schema.
- No file name collides with an upstream migration.

#### FR-17: Excluded work stays out

PR 5 (demo seed) and PR 7 (second HTN cohort chart) are not merged (A12, A13). The cascade branch's cohort stays.

**Consequences (testable):**
- No statement on the branch deletes or rewrites existing patient rows.

#### FR-18: One command for the demo

`./scripts/demo_up.sh` starts the stack and loads all fake data (A8, A13).

**Consequences (testable):**
- Running it twice leaves row counts unchanged.
- A script prints the URLs of the program, drug stock and Reports dashboards.

### 4.2 Drug stock bug fixes

**Description:** Five bugs known from the drug stock work are fixed, not carried forward. Behaviour is otherwise as in drug stock FR-1 to FR-14.

#### FR-19: Latest Wins by `submitted_at`

For one facility, month and Protocol Drug, the value with the newest `submitted_at` wins. Sheet row order never decides. Ties go to the later ingested row.

**Consequences (testable):** A fixture with rows in reverse time order shows the newest value.

#### FR-20: Wide Form sheet feeds the puller

A real Google Form response sheet (one row per response, one column per drug and dose) is converted to long rows using the existing field spec and loaded without manual editing.

**Consequences (testable):**
- A wide-format fixture goes end to end into Postgres and shows on the board.
- Blank stays unknown; `0` stays zero.

#### FR-21: Submitter and history

Every Stock Submission stores who submitted it [ASSUMPTION A33]. History is kept; the board shows Latest Wins.

**Consequences (testable):** Two submissions for the same cell yield two stored rows with submitter and time, and one displayed value.

#### FR-22: Per-user location scoping on the drug stock board

A user sees drug stock only for locations their Grafana Team gives them, with the same access banner as the HTN dashboards ([ASSUMPTION A31, A24]).

**Consequences (testable):** A district user sees only facilities in that district. A user with no team sees the access message and no rows.

#### FR-23: Patient-Days with blank strength, and a correct All row

A blank strength no longer corrupts Patient-Days. The All row is computed from summed stock and summed patients, not an average of facility rows.

**Consequences (testable):** Golden fixture with one blank-strength entry matches the hand calculation. The All row equals the sum-based value.

### 4.3 Security fix (before any new write)

**Description:** Today any Viewer can run any SQL, including writes, through `/api/ds/query` against a datasource that connects as the owner role. The overdue list auto-save uses that path. The fix ships before any new report or write path (NFR-3). Realizes UJ-5.

#### FR-24: Dashboards read through a read-only role

All provisioned datasources used by dashboards connect as a role that can only `SELECT`.

**Consequences (testable):** An `INSERT`, `UPDATE` or `DELETE` posted to `/api/ds/query` by a Viewer fails with a permission error.

#### FR-25: Writes go through h360-api

Writes go to `h360-api`, which reads the caller's Grafana session cookie, asks Grafana who the user is, and calls a `SECURITY DEFINER` function that checks the location (A16).

**Consequences (testable):**
- A request with no session returns 401. A request for a location the user cannot access returns 403 and writes nothing.
- Values are validated server-side (digits for patient id, reason from the allowed list).

#### FR-26: Overdue list saves through h360-api

The Overdue tab's auto-save and the table's Update path use FR-25. Look and behaviour for the user do not change: Saving, Saved, remove-with-reason, error toast on failure (A15).

**Consequences (testable):** Existing overdue list checks (auto-save, cancel, confirmed removal, simulated failure) pass.

#### FR-27: Negative test is part of the build

A script proves a Viewer cannot write directly and cannot write for another location.

**Consequences (testable):** The script runs in the demo verify step and fails the build if a direct write succeeds.

[NOTE FOR PM] This fix closes writes only. Reads are still open: a Viewer calling the query API directly can read data for other locations (A24). Acceptable on fake data; close it before any real-data pilot.

### 4.4 Medicine data in Postgres

**Description:** Postgres stores what each patient was prescribed at each visit, in Indonesia format (A2), so adherence, titration, statins and the chat read one source. Realizes UJ-3.

#### FR-28: Store the Obat cell and its parsed lines

Each encounter can carry an Obat cell, stored as received, plus one Prescription Line per medicine with drug, strength, doses per day, tablets per dose and daily total.

**Consequences (testable):**
- `Lisinopril 10 mg - 1 x 2 Tablet Sehari` parses to 20 mg a day.
- Cells split on `;`, `|` or new line. An unparseable entry is kept and marked Unrecognized, never dropped.

#### FR-29: One classifier assigns the Step

A shared database function assigns each visit's prescription to Step 1-6, Other Protocol, Non-Protocol or Unrecognized, using the ladder and the whitelist in the addendum [ASSUMPTION A18]. All reports and the chat call it.

**Consequences (testable):** A fixture of one visit per class returns the expected class. Changing the ladder table changes every report, with no code edit.

#### FR-30: Realistic fake data, additive only

The loader adds seeded fake prescriptions, statin use, `cvd_history` and overdue calls to the existing demo cohort ([ASSUMPTION A29, A30, A32]; A13).

**Consequences (testable):**
- Facilities differ on purpose: one looks fine but fudges and under-titrates; one loses new patients; one lacks phone numbers.
- Re-running with the same seed gives identical numbers.
- Patient rows are never deleted or replaced.

### 4.5 Reports dashboard

**Description:** One new dashboard with five tabs [ASSUMPTION A22], built in the existing visual language. Each tab shows: a plain title that names the decision, two or three headline numbers for the latest completed month, a facility table with a Flag column and a plain reason, and a "How this is worked out" note in one or two sentences. Realizes UJ-3.

#### FR-31: Reports dashboard shell

**Consequences (testable):**
- New dashboard file with tabs: Protocol adherence, Titration, BP fudging, Statins, Overdue calling. A link back to the program dashboard.
- One Change Location tree and one reference month apply to all tabs. Empty means all locations the user can access.
- Colours and tooltips reuse the cascade design tokens and shared `tip()` (NFR-4).

#### FR-32: Plain states, never silent blanks

**Consequences (testable):**
- No data shows "No data for this place" in words. Too few cases shows "Too few readings" (or the tab's equivalent), never a misleading 0%.
- Every Flag has a reason in a sentence a program manager can repeat.

### 4.6 Report: Protocol adherence

**Decision supported:** "Are patients on the medicines the protocol says, and are the ones on each step controlled?" **Clinical rule in plain words:** Each patient's latest prescription in the Window is placed on a six-step ladder: one medicine at starting dose, one at full dose, two at starting doses, two with at least one at full dose, three not all at full dose, three at full doses. Other protocol combinations, medicines outside the protocol, and unreadable entries get their own rows. A patient counts as controlled if the latest BP is under 140/90.

#### FR-33: Patients by Step with BP control

The program manager sees, for the place selected, how many patients sit on each Step, Other Protocol, Non-Protocol and Unrecognized, and how many of each are controlled.

**Consequences (testable):** Counts per row sum to the Window cohort. Percent controlled per row is computed from the same patients.

#### FR-34: Window and Strict/Lenient

The Window is the 90 days before the newest visit in the database [ASSUMPTION A18]. Strict is the default; a toggle adds patients registered inside the Window.

**Consequences (testable):** Same data gives the same report. Toggling changes only the cohort, and the cohort size is shown.

### 4.7 Report: Titration

**Decision supported:** "At which facilities are patients with high BP being left on the same medicine?" **Clinical rule in plain words:** Look at visits in the Window where BP was uncontrolled. For each, take the medicine the patient was on before. If the prescription written at that visit or the next one is a higher step, or a higher daily dose, the medicine was stepped up. Titration Rate is stepped-up visits divided by uncontrolled visits. Visits too recent to have a next visit are left out [ASSUMPTION A19].

#### FR-35: Titration Rate per place

**Consequences (testable):** Fixture patients with step-up at the same visit, at the next visit, and never are counted correctly. Uncontrolled visits with no earlier prescription are left out. The counts of both exclusions (too recent, no earlier prescription) are shown.

#### FR-36: Low-titration Flag

A facility with Titration Rate under 40% is flagged "Medicine rarely stepped up" with its number and uncontrolled-visit count [ASSUMPTION A19]. A facility with very few uncontrolled visits shows "Too few visits", not a flag.

**Consequences (testable):** The planted facility from A32 is flagged; the table sorts by uncontrolled visits so large facilities surface first.

### 4.8 Report: BP fudging

**Decision supported:** "Where might readings be rounded down to look controlled?" **Clinical rule in plain words:** Count readings just under the line (systolic 135-139) and just over it (140-144) in the last 3 months. If there are twice as many just under as just over, rounding down is likely. This uses the corrected formula, with decimals kept (A5).

#### FR-37: Fudging Score per facility

**Consequences (testable):** Score is numeric with two decimals (for example 135-139: 541, 140-144: 100 gives 5.41, not 5). The counts behind it are visible on hover.

#### FR-38: Fudging Flag and guards

Facilities at 2.0 or above are flagged. Fewer than 20 readings in 135-144 shows "Too few readings"; zero readings in 140-144 shows "No 140-144 readings" and is flagged for review [ASSUMPTION A20].

**Consequences (testable):** Fixtures for 2.0 exactly, 1.99, zero denominator and small numbers behave as stated. A facility with high control and a flag is visibly marked "Looks fine, check readings" (two-sided rule).

### 4.9 Report: Statins

**Decision supported:** "Which eligible patients are not on a statin, and where?" **Clinical rule in plain words:** Eligible means alive, under care, 40 or older, and has diabetes or a recorded heart attack or stroke (A4). On a statin means the latest prescription includes atorvastatin, simvastatin or rosuvastatin [ASSUMPTION A29].

#### FR-39: Eligible and on-statin counts

**Consequences (testable):** Per place: eligible patients, on a statin, percent on a statin, and not on a statin. Fixtures for age 39 and 40, diabetes without CVD, CVD without diabetes, and dead patients are classified correctly.

#### FR-40: Eligible-not-on-statin list

A user with access sees the list for their facility (name, age, reason eligible), using the overdue list pattern (search, paging). No new export.

**Consequences (testable):** List size equals the "not on a statin" count for the same place. A user without access sees the access message.

### 4.10 Report: Overdue calling

**Decision supported:** "Are we calling overdue patients, early enough, and does it bring them back?" **Rule in plain words:** An overdue patient is one on the existing overdue list. A patient is called if a call result exists after they became overdue. An Early Call is within 14 days. Returned means a visit within 30 days of the call (A6, A21). The overdue list remains the place you call from.

#### FR-41: Calling coverage and timeliness

**Consequences (testable):** Per place: overdue patients with a phone, number and percent called, percent of calls that were Early Calls. Matches the existing `call_results` data.

#### FR-42: Outcomes and return to care

**Consequences (testable):** Shows call results (agreed to visit, call again later, removed) and the share returned to care, split Early Call versus later. Numbers reconcile with `HEART360_OVERDUE_PATIENTS_CALLED` and `HEART360_OVERDUE_RETURNED_TO_CARE`.

### 4.11 AI chat floating over Grafana

**Description:** A small widget on every dashboard page (A17). It opens a panel with clickable chips, answers from stored queries, and ends in a plan. Scope is facility and district, hypertension only (A9). Realizes UJ-4.

#### FR-43: Floating button and chips

A floating button opens a panel on any dashboard. The panel opens on chips, not an empty box. Chips depend on scope: facility chips (why control is low, who to call, are medicines being adjusted, are readings reliable, who needs a statin) and district chips (which facilities to visit first, plus the same questions). A text box is available but secondary.

**Consequences (testable):** Opening the chat shows 4-6 chips [ASSUMPTION: count chosen to fit the panel without scrolling]. At national or empty scope the chips offer "Pick a district" [ASSUMPTION A25]. The widget does not change the dashboard layout.

#### FR-44: Stored queries only

Every answer comes from a fixed, named query library that reads the same views as the reports. The chat cannot run free SQL.

**Consequences (testable):** The chat's database role is read-only and limited to the library's views. Free-text input maps to a library entry or to a "pick a chip" reply.

#### FR-45: Answer shape

An answer has two or three ranked reasons, never more. Each reason names a number. Under each: a "What to do" block. Under that: a plan nudge, a clickable follow-up such as "How many patients should I call?". Writing is short sentences and plain words: no sentence over 20 words, no jargon beyond BP and the glossary terms.

**Consequences (testable):**
- No answer has more than three reasons or about 150 words before the honesty line [ASSUMPTION: word cap chosen for readability, not from a source].
- Every number in the text appears in a report for the same place and month.

#### FR-46: Plan nudge

Clicking the nudge returns a concrete plan from a stored query: for calling, the number of overdue patients with a phone, split into a four-week schedule [ASSUMPTION A27].

**Consequences (testable):** The plan's numbers match the Overdue calling tab.

#### FR-47: Ranked by evidence, two-sided

Reasons are ordered by the Evidence Table, then by the facility's own gap [ASSUMPTION A27]:

| Lever | Effect in the evidence |
|---|---|
| New patients returning for a second visit | Biggest lever. 31% to 34% of new patients do not return within 90 days |
| Capturing a phone number | +5 to 12 points of return |
| First appointment within about 35 days | Over 70 days out costs 15 to 24 points |
| Calling overdue patients early | Works, but only 1% to 15% of overdue patients with a phone are called |
| Stepping up treatment | +3.8 to 6.3 points of control |
| Drug stock | Weak alone, but gates calling and titration |

**Consequences (testable):**
- Flags from needs-attention thresholds (control under 50%, uncontrolled over 20%, missed visits over 25%, LTFU over 20%) are used, and larger facilities weigh more [ASSUMPTION A27].
- A facility with good control but a fudging flag or low Titration Rate is still named in a short "Also check" line (two-sided rule).
- If protocol drug stock is low, the calling and titration reasons carry "fix stock first".
- At district scope the answer ranks facilities by uncontrolled patients, not by percent.

#### FR-48: Honesty ceiling

Every answer ends with: "These actions explain only 2% to 12% of why one facility does better than another. Treat them as the best next steps, not a promise." The text does not say "will", "guarantees" or imply a size of gain beyond the Evidence Table.

**Consequences (testable):** A test over all library answers finds the line present and none of the banned words.

#### FR-49: Offline Mode and Claude Mode

Without an API key the chat uses a template over the same numbers and says so (A7). With `ANTHROPIC_API_KEY` set (model from `ANTHROPIC_MODEL`), Claude writes the prose from the same numbers; the numbers do not change.

**Consequences (testable):**
- No key: every chip works with no network.
- With key: only aggregated numbers are sent [ASSUMPTION A26]. If the call fails, the answer falls back to Offline Mode with the badge changed.
- The key is never present in browser code, logs or the repo.

## 5. Cross-cutting requirements (NFRs)

- **NFR-1 (A15):** The Hypertension and Diabetes tabs of the program dashboard stay byte-identical to the cascade branch. The Overdue tab changes only its save path. Checked by diff of those tab elements.
- **NFR-2:** PR 5 and PR 7 are not merged (FR-17).
- **NFR-3:** FR-24 to FR-27 land and pass before any new write path, any new report, or the chat.
- **NFR-4:** Design system reuse: hearts360 tokens (controlled `#3bb231`, uncontrolled `#eeab00`, no visit `#ed6300`, 12-month LTFU `#ff3355`, under care `#b51bdc`, registrations `#007ee4`, estimated `#dae0e1`), drug stock thresholds, ECharts with shared `tip()`, Business Text for cards and lists, latest completed month for headlines with the running month dashed. No new plugins beyond those already provisioned.
- **NFR-5:** Fresh-install safe: all new SQL is additive and idempotent.
- **NFR-6 [ASSUMPTION A30]:** Report panels load within 5 s and an Offline Mode answer within 3 s on the demo dataset.
- **NFR-7 [ASSUMPTION A26]:** No patient names, phones or ids leave the machine; the chat is read-only; API key server-side only.
- **NFR-8:** Plain language: every flag reason is one sentence of 20 words or fewer and uses no abbreviation other than BP; the same limit applies to chat sentences.
- **NFR-9:** Every rule has a verify script with a hand-checked fixture, following the existing `verify_*` pattern.

## 6. Non-Goals and Scope

**Not building:** a signed Grafana app plugin (A17); an xlsx upload for medicine data from real sites [ASSUMPTION A23]; the Excel tool's file picker; per-clinician or per-patient fudging; CVD risk scoring for statins; diabetes versions of the new reports or chat; free SQL in the chat; chat history or memory; row-level read security [ASSUMPTION A24]; central or national rollups; changes to the HTN or DM tabs.

**In scope:** FR-15 to FR-49.

**Deferred, marked for the owner:** patient pop-up and call log (cascade notes); [NOTE FOR PM] swapping the rebuilt ladder and medicine list for the Excel tool's own files is the first thing to do once access exists (A2, A3).

## 7. Deliberate tradeoffs

| We cut or chose | Why | Cost, and when to revisit |
|---|---|---|
| Rebuilt clinical rules instead of the Excel tool's files | Private repo unreachable (A2) | Numbers may differ from the tool. Replace the ladder table first |
| One dashboard, five tabs | One tree and month for all; fastest | Big JSON. Split later if it gets slow |
| Injected widget, not a signed plugin | No build toolchain or signing (A17) | Fragile across Grafana upgrades; port to a plugin later |
| Read scoping at dashboard level only | OSS Grafana has no per-user row security [ASSUMPTION A24] | A Viewer using the API can read across locations. Add reads through h360-api before real data |
| Writes via a small Python service | Closes the hole with the least new moving parts (A16) | One more container to run |
| Fixed query library, no free SQL | Safe and fast to verify | Chat cannot answer unplanned questions |
| Offline template answers | Demo works with no key or network (A7) | Template prose is stiffer than Claude's |
| Facility-level fudging only | No clinician identity in the data | Cannot point to a person |
| Medicine data from fake loader only | Prove the reports before building intake [ASSUMPTION A23] | Real sites cannot load medicines yet |
| Statin rule from age, diabetes, CVD | No risk-score inputs (A4) | May miss eligible patients |
| Grafana image stays unpinned (A8) | Do not change the image choice | Upgrade surprises; pin after the demo |
| No nav edits in the program dashboard [ASSUMPTION A22] | Keeps HTN/DM byte-identical | New dashboards are one click further away |

## 8. Success Metrics

For tomorrow's demo and the first learning round.

**Primary**
- **SM-1:** Clean laptop to all three dashboards and the chat with one command in 15 minutes or less, run twice with no data loss. Validates FR-15 to FR-18, FR-30.
- **SM-2:** Three people who did not build it (or the owner standing in for them) name the facility to visit first, and why, within 2 minutes. Validates FR-31 to FR-38, FR-47.
- **SM-3:** The chat answers all chips in under 3 s offline, and every number in the demo answers matches a report. Validates FR-43 to FR-49.
- **SM-4:** The security script passes: a Viewer's direct write fails, and the overdue list still saves. Validates FR-24 to FR-27.

**Secondary**
- **SM-5:** Each report matches its hand-calculated fixture. Validates FR-29, FR-33 to FR-42.
- **SM-6:** The HTN and DM tab diff is empty. Validates NFR-1.
- **SM-7:** Learning goal: the number of reasons or labels people ask us to explain, collected as notes.

**Counter-metrics (do not optimize)**
- **SM-C1:** Number of chips, queries, panels and flags. More is not better; keep the chat to two or three reasons. Counterbalances SM-2, SM-3.
- **SM-C2:** Confidence of the chat's wording. Never raise it above the 2% to 12% ceiling. Counterbalances SM-3.
- **SM-C3:** Flag count per facility. Do not tune thresholds to make the demo look dramatic. Counterbalances SM-2.

## 9. Open Questions and Assumptions

**Open questions** (non-blocking; owner Tony; revisit when access exists)
1. Real step ladder, dose tiers and medicine list from the Excel tool. **Revisit:** when the private repo is readable.
2. Statin eligibility source beyond A4. **Revisit:** before a real-data pilot.
3. Does the Indonesia program want a 40% titration line and a 14-day Early Call line? **Revisit:** after the first demo.
4. Real source for `cvd_history`. **Revisit:** before a real-data pilot.
5. Is an external Claude call acceptable on real data? A7 covers fake data only.

**Assumptions index.** Settled: A1-A17 in `ASSUMPTIONS.md`. New in this PRD, to copy into `ASSUMPTIONS.md`: A18 ladder, window and default view; A19 titration details and 40% flag; A20 fudging guards; A21 overdue calling definitions; A22 one dashboard, five tabs, no nav edits; A23 fake-loader-only medicine data; A24 read scoping at dashboard level; A25 chat scope from `var-org_unit`; A26 aggregates only to Claude, mode badge; A27 evidence-tier ranking and size weighting; A28 FR and UJ numbering continues; A29 statin definition and `cvd_history`; A30 demo volume and performance targets; A31 drug stock uses Team access; A32 planted demo facilities; A33 Form collects email. Each is tagged `[ASSUMPTION Axx]` where used and logged in `.memlog.md`.
