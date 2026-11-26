---
story: 7.9
created: 2026-11-05
branch: cursor/hearts360-mvp-7579
method: walked at 1366x768 as admin, district.d and nurse.phc-a; District-D (10), PHC-E (11), PHC-A (3), all locations; month 2026-10-01
screenshots: _bmad-output/implementation-artifacts/ux-audit-2026-11/*.png
status: findings only, no product files changed
---

# UX audit of all HEARTS360 dashboards (story 7.9)

## 1. Summary

The program dashboard and the overdue list are easy to use. The Reports dashboard is not, for four reasons. First, you cannot reach it in one click with your place: the `Reports` button drops the location, and a Viewer who opens Reports without a location gets `Access Denied … Nationwide`. Second, the same words show different numbers. `BP controlled` is 63% for District-D on the Hypertension tab and two Reports tabs, but 80% on `Right medicines`. The return rate is 15 days on one board and 30 days on the other, with different denominators. Third, there are two "look here first" lists (the strip above the tabs and a card in every tab) that disagree, and the strip says `0 patients` at all locations. Fourth, the tabs use new chart types where managers already know a form. The owner wants the established forms back: the Excel step table for adherence, a monthly facility-against-average table or line for titration and statins, and the quarterly BP Fudging report. The chat answers fast and offline, but it can mislead. It lists a non-problem as a reason (`On target: 100% … phone number`), it proposes calling 356 patients a week, and it states causes (`Check every BP cuff`) as if they were proven. BP readings check should follow the established BP Fudging PRD (quarterly, 130–139 / 140–149). On those terms the planted PHC-E pattern falls in the quarter still in progress, so it does not show yet. 39 findings: **14 must-fix, 18 should-fix, 7 nice**. The overdue list keeps its current behaviour in every fix below.

## 2. Navigation proposal

**Principle:** one path, from the Dr Rai flow. Spot a pattern on the Hypertension tab, then go one click to the cause for the same place and month, then act (overdue list, patient list, stock, chat plan).

**Where you start: the program dashboard**
- Top-bar links, all with `includeVars: true` so place and month carry:
  - `Find the cause` (was `Reports`), opening Reports at `Stepping up`;
  - `Medicine stock` (new; today only Reports links to it).
- The `Overdue patients` row is the one HTN row we may edit. Give it two links: `See calls by facility` (Reports, Overdue calls) and `Open the overdue list` (Overdue list tab; at district level, the Reports Overdue calls table instead).
- Row title `Change location · ${place}` on every board, collapsed by default everywhere, so the place is always named.

**Reports dashboard**
- Remove the strip above the tabs. Make it the first tab, **`Start here`**: one small table with a row per facility in view (flagged first) and a column per report, each cell holding the flag word. Clicking a cell opens that tab **for that facility**, in the same month. This replaces the strip and the five `Look at these first` cards (one list, not six).
- Tab order follows the Dr Rai cause map. Low control: `Stepping up` → `Right medicines` → `BP readings check`. Missed visits: `Overdue calls`. Then `Statins`. Final order: `Start here · Stepping up · Right medicines · BP readings check · Overdue calls · Statins`.
- In every facility table, the facility name is a link that narrows the same tab to that facility. `Also flagged on` comes from `report_flags`, not a hard-coded pair.
- Every tab ends with one `Next step` link:
  - Stepping up: `Check medicine stock first` (Drug stock);
  - Overdue calls: `Open the overdue list` (facility) or `Pick a facility` (district);
  - Statins: `Open the patient list`;
  - BP readings check: `See readings by month` (the same tab's table).
- `← Hypertension dashboard` (was `← Program dashboard`) keeps place and month and lands on the Hypertension tab.
- Default location is the user's home unit (the same query `heart360.home.json` uses), never blank for a Viewer.

**Month:** one variable name, `reporting_month`, on all three boards, defaulting to the last full month (Oct-2026). The program board keeps it hidden, but it is passed by its links. The chat reads it on every board.

## 3. Mock usability test

Short think-aloud scenarios, judged by the owner's three questions: is it too confusing, can it be simpler, does it claim too much.

| # | Persona and task | Where they hesitate, misread or give up |
|---|---|---|
| T1 | Vikram, district manager, Hypertension tab at District-D sees 63% control and 20% no visit. "Why?" | He clicks `Reports` and lands on **all locations** (UX-01), so he has to find District-D in a collapsed tree. As a Viewer he would see `Access Denied` (UX-02). **Gives up or calls IT.** |
| T2 | Vikram on Reports, District-D | He reads `80% BP controlled` and says "but the dashboard said 63%". **He trusts neither number** (UX-03). |
| T3 | Vikram reads the strip `PHC-E · 1,358 patients · Right medicines · Stepping up …` | "1,358 what? The table says 1,206." He clicks `Stepping up`. It opens at the district, not at PHC-E, and he looks for PHC-E (UX-04, UX-14). |
| T4 | Vikram on `Right medicines` | "What is `1 medicine, full dose`? Which medicine?" The Excel table he knows said `Step 2`. **He misreads it** (UX-05). |
| T5 | Vikram on `Stepping up`: "Has PHC-E got worse?" | The chart is one bar per facility for 90 days, with no months and no average. **He can't answer** (UX-06). |
| T6 | Vikram on `Overdue calls` | `183 calls` but `69 of 204 called patients`, and `The Overdue tab counts 15 days`. He opens the Overdue tab and sees no 15. **He gives up on the number** (UX-11). He clicks `Open the overdue list to call` and gets a red banner: facility level only (UX-12). |
| T7 | Meera, nurse at PHC-A, chat `Who should I call this week?` | `356 patients each week`. "We are two nurses." **She ignores the plan** (UX-08). `Start with the patients overdue longest`, but the list shows the most recently overdue first (UX-35). |
| T8 | Meera, chat `Why is my BP control low?` | Reason 2: `On target: 100.0% … phone number`. "Then why is it a reason?" **She misreads it** (UX-07). |
| T9 | Vikram, chat `Are my BP readings reliable?` at PHC-E | `Check every BP cuff and retrain staff`. He tells the facility its staff are rounding. That is a **claim the data can't support** (UX-09). The tab's 3-month score of 5.40 also disagrees with the quarterly view Bangladesh managers know (UX-25). |
| T10 | District manager enters stock from District-D | `Enter stock` opens an empty view panel: `Pick one facility…`, with no picker. **He gives up** (UX-13). |

## 4. Findings

Screenshot paths are relative to `_bmad-output/implementation-artifacts/ux-audit-2026-11/`. `P` = `grafana_provisioning/dashboards/HEARTS360 Dashboards/heart360.hypertension-diabetes.program.json`. `S` = `dashboard_src/reports/_shell.json`. A15 guard: `scripts/check_htn_dm_untouched.py` allows changes only to the HTN `Overdue patients` row, dashboard links and other non-HTN/DM parts. Fixes inside other HTN panels need the owner to lift A15.

### Must-fix

| id | Where | What the user sees | Why it is a problem | Fix |
|---|---|---|---|---|
| UX-01 | `P` dashboard link `Reports` (`includeVars:false`); `heart360.home.json` link | Reports opens at all locations, whatever place you were on (`03-htn-d10-fold.png`, link href `/d/heart360_reports`) | Breaks Dr Rai "one click, same place and month"; EXPERIENCE IA | `includeVars:true`, label `Find the cause`, land on `Stepping up`; add `Medicine stock` link (see §2) |
| UX-02 | `S` var `org_unit` / `isAllowed`; `heart360.drug.stock.json` same | Viewer with blank location gets `Access Denied: … Nationwide (All)` on every panel; tree still lists other districts (`51-dd-rep.png`, `54-dd-stock.png`) | Blank must mean "all places I can access" (EXPERIENCE Component Patterns). With UX-01, every Viewer path to Reports ends here | Default `org_unit` to the user's home unit (reuse `UserOrgUnitId` query from home.json); filter the tree to permitted units |
| UX-03 | `1-adherence.json` headline and table, `report_adherence` | District-D `BP controlled` 80% (1,771 of 2,208) on Right medicines; 63% on HTN, Stepping up, BP check and in chat (63.2%). PHC-E 87% vs 75% (`05-rep-d10-fold.png`, `10-rep-ou10-Stepping-up.png`) | Same label, same place and month, two numbers. Managers stop trusting both | Use the HTN definition everywhere. Where a different base is needed, name it: `controlled among patients seen in the last 3 months (n of N)` |
| UX-04 | `S` strip (`report_flags` `patients_n`, `0.6.13_to_0.6.14.sql`) | All locations: `PHC-E 0 patients` (`35-rep-all.png`). District: `1,358 patients` unlabelled, but the table says 1,206. Strip takes 6.7 s at all locations | Wrong number; counts unlabelled (Voice rule 3) | Fix `patients_n` at national scope; label it (`1,358 under care`); fold into `Start here` tab (§2) |
| UX-05 | `1-adherence.json`, `report_adherence_buckets` | Chart rows `1 medicine, starting dose`, `2 medicines, one at full dose` …; one-medicine flag on every facility (6 of 6) | Owner: adherence must follow the tested Excel report; the labels confuse | Replace chart and table with the `write_protocol_report_table` table (§5) |
| UX-06 | `2-titration.json`, `4-statins.json` charts (`by facility` bars) | One bar per facility for one period; at facility level a single bar (`36-rep-phce-statins.png`); no trend, no average | Owner: use the established Metabase forms. Dr Rai rule 1: read 3–6 months | Titration: monthly table, facility rows and an `Average` row (month, high-BP visits, stepped up, rate), last 9 months. Statins: monthly line, facility vs average, plus the same table. Overrides PD-8 (owner's newer instruction) |
| UX-07 | `h360_api/ranker.py` (reason selection), `wording.py` | `Why is my BP control low?` at PHC-A: reason 2 `On target: 100.0% of new patients have a usable phone number` (`21-chat-phca-why.png`) | A met target is shown as a cause. Misleads | Drop reasons that pass their threshold; if fewer than two remain, show one, or `No clear reason in these reports` |
| UX-08 | `wording.py`/`ranker.py` plan card; `5-calling.json` side card | `Calling plan for PHC-A 1421 patients … Week 1 356`; district side card `about 704 a week` (`24-chat-phca-call.png`, `10-rep-ou10-Overdue-calls.png`) | Not doable. Dr Rai good actions are specific and achievable (`25 a week`) | Plan by capacity: `One nurse can call about 25 a week. Start with the first 100 on the list.` Show the total as context, not as the target |
| UX-09 | `wording.py` What-to-do; tab pills in `2-titration.json`, `3-fudging.json` | `Check every BP cuff and retrain staff…`; `Visit this month to check BP cuffs…`; Stepping-up advice with no stock check | Owner: patterns, not proof. Chattogram README: read titration with stock first | Use `may` and `is a reason to look`; put the stock line before any titration advice; readings: `Watch how BP is measured on your next visit` |
| UX-10 | `chat-widget.js` answer card, `h360_api` answer payload (`registry.py`) | Numbers in reasons can't be checked without leaving the chat | Owner trust pattern (hearts360ai `.fig` hover card) | Each reason's figure gets a dashed underline; hover or focus opens a card. The card shows: title, one-line definition, the big figure with `n of N`, a 6-month mini line (facility vs average) or a small table, and a footer band naming the place with `See this in Reports: <tab>` on the right. API returns the series it already computed |
| UX-11 | `5-calling.json` headline, note, chart; `P` `Overdue patients` row | Reports: `183 called`, but `69 of 204 called patients … within 30 days`, and `The Overdue tab counts 15 days`. HTN row: `67 of 183 … within 15 days`. Called `6.5%` vs `7%` | Same measure, two windows, two denominators, and a wrong pointer (the 15-day count is on the Hypertension tab) | One window (owner picks; 30 days suggested) and one denominator (patients called in the month) on both boards; same rounding |
| UX-12 | `5-calling.json` `Open the overdue list to call`; `chat-widget.js` `overdueHref` | From District-D both open the Overdue list tab, which shows a red `available only at the facility … levels` (`30-ovd-d10.png`) | Dead end in the act step | Above facility level, link to the Overdue calls table and say `Pick a facility to open its list`; facility rows link with that facility's id. Overdue list unchanged |
| UX-25 | `3-fudging.json`, `report_fudging` / `report_fudging_histogram` (`0.6.10_to_0.6.11.sql`), `report_flag_thresholds` | The 5-point histogram, 135–139 vs 140–144 bands, last 3 months, a two-level flag (`10-rep-ou10-BP-readings-check.png`) | The established BP Fudging PRD (Simple, Shortcut story 12530) overrides CR-4 and DESIGN tab 3 | Follow that PRD (§5b): quarterly, 130–139 / 140–149, three-colour ratio cells, a facility table, a quarterly trend of % of facilities at 2.0 or more, and a total row |
| UX-13 | `heart360.drug.stock.json` link `Enter stock` (`viewPanel=12`) | At District-D: an empty view panel, `Pick one facility to enter stock.`, no picker, plus a `Back to dashboard` side pane (`34-stock-enter.png`) | Blocks the stock entry flow | Link to the board anchored at the form (no `viewPanel`); show a facility select inside the form when above facility level |

### Should-fix

| id | Where | What the user sees | Why | Fix |
|---|---|---|---|---|
| UX-14 | `S` strip and each tab's `*-look` panel | Two lists, `Needs a look first` (strip) and `Look at these first` (card), in different orders (all locations: strip E, F, B; card C, E, B); strip pills open the district, not the facility | Two names for one idea; EXPERIENCE says `Look at these first` comes from the table's top rows | `Start here` tab replaces both (§2) |
| UX-15 | `_shared/table.js` facility cell | Facility names are plain text | No way down from district to facility except the tree | Name links to the same tab with `var-org_unit=<facility id>` |
| UX-16 | `alsoOn` in `1-…5-*.json`, `table.js` | Right medicines shows no `Also flagged on`, though the strip lists PHC-E on four tabs | Hard-coded pairs (`alsoOn: []` for adherence) | Build `Also flagged on` from `report_flags` rows |
| UX-17 | `S` tab order | `Right medicines · Stepping up · BP readings check · Statins · Overdue calls` | Does not follow the cause order a manager reasons in | Order in §2 |
| UX-18 | `P`, `S`, drug stock: row `Change location` | The HTN tab never names the place; Reports names it only under the tabs | EXPERIENCE: the title strip always names the place | Row title `Change location · ${place_name}` (hidden var) on all three boards |
| UX-19 | drug stock row `Change location` | Expanded by default (300px tree) on Drug stock, collapsed elsewhere; no `All locations` root (`33-stock-d10.png`) | Inconsistent picker | Collapse by default; same tree query as the other boards |
| UX-20 | `P` `reference_month`, drug stock `reporting_month`, `chat-widget.js readScope` | Program: hidden epoch month, sub-level table uses Nov (running). Drug stock defaults to `Nov-2026`. Reports `Oct-2026`. Chat on Drug stock says `Oct-2026` while the board shows Nov | Month does not carry; boards disagree | One name, `reporting_month`, defaulting to the last full month; chat reads it on every board |
| UX-21 | `_shared/states.js`; `4-statins.json` patients banner; drug stock | Red banner with ⚠️ and raw team names; `The patient list is available only at the facility level.` with no next step, over a large empty panel (`10-rep-ou10-Statins.png`). Overlaps R-28 | Voice rule 8 (no warning tone); no next step | Grey banner: `Pick a facility in Change location above to see its patients.` Collapse the empty panel |
| UX-22 | `chat-widget.js` pill and clearance | At 1366x768 the pill covers the third outcome heading (HTN) and the second `Look at these first` card. On BP readings check it fell back to icon only | Covers content; inconsistent | Use the 48px icon pill below 1440px wide; make the scroll-padding clearance reliable on all boards |
| UX-23 | `wording.py` number format | `53.1%`, `29.9%`, `100.0%`, `1421`, `1334` | DESIGN: whole percents (one decimal under 10%), thousands commas | Format as DESIGN; same helper as the tabs |
| UX-24 | `wording.py` new-patient reason | `29.9% … did not come back (258 of 368 came back)` | Counts given for the opposite group | `110 of 368 new patients did not come back` |
| UX-26 | tab JSONs (table panel h 14–18, statins patients h 22), `S` strip h 4 | Large empty space under 2-row tables; strip has an empty band; the Statins list is cut off in its panel | Looks unfinished; pushes the next step down | Size panels to content (fewer rows of height, or auto height) |
| UX-27 | `5-calling.json` row `New patients` | `28% did not come back` sits under the note at the bottom of Overdue calls, yet it is the chat's top reason at PHC-A | Hidden cause | Move to the tab's headline strip (fourth number) or the `Start here` grid |
| UX-28 | `P` dashboard links (`Overdue patients` row allowed) | No link from any HTN indicator to its cause report | Dr Rai quick links | Covered by §2 links; the rest of the HTN tab waits on A15 |
| UX-29 | `chat-widget.js` national state | nurse.phc-a and district.d at blank scope see `Pick a district` (`64-na-chat.png`) | A nurse has no district; wrong next step | Default chat scope to the user's home unit (same as UX-02) |
| UX-30 | `wording.py` plan card | `Start with the patients overdue longest` / `Who is overdue longest?`, but the list shows the most recently overdue first (`31-ovd-phca.png`) | Text and list disagree; list must not change | `Start at the top of the list, with patients not called yet.` |
| UX-31 | `2-titration.json` headline column 3 | `777 visits left out` beside `535 counted` | Bigger than the measure; reads as an error | Move to the note: `750 visits were too recent to check.` |
| UX-32 | `heart360.drug.stock.json` `Stock on hand` | At 1366 the ARB columns are clipped; `199962`; `90.00` (overlaps R-33) | Truncation, format | Fewer columns (patient days only, with a toggle for units), thousands commas, whole days |

### Nice

| id | Where | What the user sees | Fix |
|---|---|---|---|
| UX-33 | `2-titration.json`, `4-statins.json` charts | Bar labels collide with the flag line (`28% · 79 of 283`, `22%`); `2,452 patients · 77% controlled` clipped at right | Goes away with UX-05 and UX-06; else offset labels |
| UX-34 | `P` time picker | Program board shows `Last 2 years`; Reports and Drug stock hide or limit it | Hide the time picker on the program board too, or state its effect in panel descriptions |
| UX-35 | Grafana nav | Left menu docked open takes 320px of 1366 | Ship with `nav docked=false` (Grafana setting) or tell users how to collapse it |
| UX-36 | `P` Overdue list tab | `Last visited on` column clipped at 1366 (`31-ovd-phca.png`) | Leave as is (behaviour freeze); revisit with the owner |
| UX-37 | dates across boards | `13-Oct-2026` (Statins list), `20 Sep, 2026` (overdue list), `31-Oct-2026` (subtitles) | One date format (copy-review term table) |
| UX-38 | `S` `Patients counted` variable | Applies only to Right medicines but sits in the top bar for all tabs | Move into the Right medicines tab, or show it only there |
| UX-39 | load | Headlines appear in about 0.8–1.1 s at facility and district; the strip takes 6.7 s at all locations | Precompute `report_flags` for all locations, or show a `Finding facilities…` line while it loads |

## 5. Right medicines as the established step table (UX-05)

One table, like `protocol_engine.py write_protocol_report_table`. Plain step labels come from the CR-1 ladder.

| Row | Label shown |
|---|---|
| Protocol medicine combinations (total) | `On a protocol step` |
| Step 1 … Step 6 | `Step 1 · Amlodipine 5 mg`, `Step 2 · Amlodipine 10 mg`, `Step 3 · Amlodipine 10 mg + ACE/ARB standard dose`, `Step 4 · Amlodipine 10 mg + ACE/ARB full dose`, `Step 5 · Step 4 + hydrochlorothiazide 12.5 mg`, `Step 6 · Step 4 + hydrochlorothiazide 25 mg` |
| Other protocol only combinations | `Other mix of protocol medicines` |
| Non-protocol combinations | `Medicine outside the protocol` |
| No HTN medicine at last visit | `No BP medicine at last visit` |
| Grand total | `All patients` |

The columns are kept as in the tool: `Patients`; `% of all patients`; `% of patients on a step`; `Came back in last 3 months`; `Controlled`; `% controlled`; `Control so far (steps 1 to n)`. The headers are plain-worded, and each percent shows its `n of N`. The facility comparison stays below the step table and uses the same columns, cut to `Facility · Patients · On step 3 or higher · Outside protocol · % controlled`.

## 5b. BP readings check as the established BP Fudging report (UX-25)

**Purpose, in the PRD's own terms.** The report finds facilities where BP may be marked down to just under 140, so the team knows where to train staff on measuring BP. The PRD itself names the risk that genuine readings of 130–139 are counted. So the tab shows a pattern to check, never proof.

- **Ratio:** visits in the quarter with systolic 130–139, divided by visits with systolic 140–149. It counts all visits, not the latest visit per patient.
- **Colour of the ratio cell only:**
  - green under 1.8;
  - yellow at 1.8 or more (add a 1.8 warning row to `report_flag_thresholds`);
  - orange flag at 2.0 or more. DESIGN bans red for flags; the word `Check readings` goes in the cell too.
- **Main view: facility table.** One row per facility. For each of the **last 4 completed quarters**: `130–139`, `140–149`, `Ratio`. A bold district (or all-places) total row comes first, which is the PRD's program table cut to the place in view.
- **One chart:** a line of the `% of facilities with a ratio of 2.0 or more`, by quarter, over the same 4 quarters. No numerator or denominator lines.
- **Dropped:** the 5-point histogram and the 3-month window. The facility-type filter (UHC / CC) has no equivalent in our data, so it is left out.
- **Wording:** keep `Readings bunch under 140 … Check how BP is measured.` The chat's `readings_reliable` answer becomes, for example, `In Jul–Sep 2026, 2.1 readings of 130–139 for every 1 of 140–149. This may mean readings are rounded down. Watch BP being measured on your next visit.` Drop `retrain staff` and `check every cuff` (UX-09).

**What this changes, and a seed problem.** I checked the demo database (`heart360tk_schema.encounters` and `blood_pressures`, PHC level including SHCs). PHC-E's planted bunching sits almost entirely in **Oct-2026, which is the quarter still in progress**. In Q4 so far it has 385 readings of 130–139 against 29 of 140–149 (13.3).

| Completed quarter | PHC-A | PHC-B | PHC-C | PHC-D | PHC-E | PHC-F |
|---|---|---|---|---|---|---|
| 2025-Q4 | 1.20 | 1.00 | 1.23 | 2.06 | 1.02 | 1.55 |
| 2026-Q1 | 1.33 | 1.66 | 1.50 | 1.43 | 1.23 | 1.29 |
| 2026-Q2 | 1.37 | 1.81 | 1.82 | 1.74 | 1.54 | 1.75 |
| 2026-Q3 | **2.08** | **2.05** | 1.75 | 1.95 | 1.27 | 1.95 |

Under the PRD rule, PHC-A and PHC-B would be flagged in Q3, and **PHC-E would look normal**. The demo story (A32: a facility that looks fine but bunches under 140) needs one of two fixes:
- plant PHC-E's extra 130–139 readings in Jul–Sep 2026, with an insert-only seed and a matching `verify_seed_targets.sh` target; or
- let the report count the quarter in progress, shown dashed and labelled `so far`.

This is a decision for the owner. The insert-only seed is the cleaner one. The background ratios also climb to around 2.0 by Q3 everywhere, so the seed generator's 130–149 spread needs a look before the demo, or every facility drifts towards the flag.

**Changes by file:** new migration (`report_fudging_quarterly`; replaces `report_fudging_histogram`; threshold row 1.8), `3-fudging.json`, `wording.py` / `ranker.py` (`readings_reliable` uses the last completed quarter), seed plus `verify_seed_targets.sh`, `verify_fudging.sh` fixture.

## 6. Fix plan by owning file

No two groups touch the same file. The coordinator regenerates `heart360.reports.json` after merging (EP-7).

| Group | Files | Findings |
|---|---|---|
| A. Program board | `P`. Links, `Overdue patients` row, `Change location` row title, month variable. **A15 applies.** | UX-01, UX-11 (HTN side), UX-18, UX-20, UX-28, UX-34 |
| B. Home | `heart360.home.json` | UX-01 (link), UX-02 (expose home-unit query to reuse) |
| C. Reports shell | `S` | UX-02, UX-04 (panel), UX-14, UX-17, UX-18, UX-20, UX-26 (strip), UX-38, UX-39 (loading line) |
| D. Right medicines | `dashboard_src/reports/1-adherence.json` | UX-03 (panel), UX-05, UX-26 |
| E. Stepping up | `2-titration.json` | UX-06, UX-09 (pill), UX-31, UX-33 |
| F. BP readings check | `3-fudging.json` | UX-09 (pill), UX-25 (§5b) |
| G. Statins | `4-statins.json` | UX-06, UX-21 (banner), UX-26 |
| H. Overdue calls | `5-calling.json` | UX-08 (side card), UX-11, UX-12, UX-27 |
| I. Shared table and states | `dashboard_src/reports/_shared/table.js`, `states.js`, `styles.css` | UX-15, UX-16, UX-21 |
| J. Report SQL | new migration after `0.6.13_to_0.6.14.sql` (`report_flags`, `report_adherence*`, monthly series with average, `report_fudging_quarterly`, threshold row 1.8, calling denominators) plus its `verify_*.sh` | UX-03, UX-04, UX-05, UX-06, UX-11, UX-25 (data side) |
| K. Chat widget | `docker_build/grafana_public/h360/chat-widget.js` | UX-10 (overlay UI), UX-12, UX-20 (month), UX-22, UX-29 |
| L. Chat API | `h360_api/ranker.py`, `wording.py`, `registry.py`, tests | UX-07, UX-08, UX-09, UX-10 (series in payload), UX-23, UX-24, UX-25 (`readings_reliable`), UX-30 |
| M. Drug stock | `heart360.drug.stock.json` | UX-02, UX-13, UX-19, UX-20, UX-32 |
| N. Seeds (after the owner's decision) | a new insert-only seed for PHC-E 130–139 readings in Jul–Sep 2026, `verify_seed_targets.sh` | UX-25 |

**Order:** J and L first; D to H depend on J's columns, and K's overlay depends on L's payload. A, B, C, I and M can start now. UX-35 to UX-37, and the UX-25 seed choice, need an owner decision.
