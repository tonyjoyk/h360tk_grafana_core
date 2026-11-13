# Context pack: every link and file you need

Owner: Tony Joy, Resolve to Save Lives
Date: Nov. 4, 2026
Read with: `01-GOALS-hearts360-build.md`

This file is a map, not instructions. It tells you where everything lives. The goals file tells you what to do with it.

---

## Repo index

| Repo | What it holds | Access |
| --- | --- | --- |
| `simpledotorg/h360tk_grafana_core` | Grafana core. Cascade and cohort work. | public |
| `tonyjoyk/h360tk_grafana_core` | Fork. Drug stock work and BMAD planning artifacts. | public |
| `tonyjoyk/rea` | Reverse engineering helper code. | check |
| `tonyjoyk/protocol_adherance_report_tool` | Protocol adherence Excel tool, clinical rules, medicine list. | private |
| `tonyjoyk/hearts360ai` | AI prototype and the full research archive. | check |

---

## 1. Cascade, cohort, styling and overdue list

On `simpledotorg`. Built on 0.6.0.

- Branch `demo/cascade-cohort`, tip `08a2894`, 15 commits on top of 0.6.0
- PR: https://github.com/simpledotorg/h360tk_grafana_core/pull/81
- Branch: https://github.com/simpledotorg/h360tk_grafana_core/tree/demo/cascade-cohort
- Full diff against 0.6.0: https://github.com/simpledotorg/h360tk_grafana_core/compare/0.6.0...demo/cascade-cohort

**Read the design doc first**
https://github.com/simpledotorg/h360tk_grafana_core/blob/demo/cascade-cohort/docs/demo-screening-cascade.md

**Dashboard with every panel**
https://github.com/simpledotorg/h360tk_grafana_core/blob/demo/cascade-cohort/grafana_provisioning/dashboards/HEARTS360%20Dashboards/heart360.hypertension-diabetes.program.json

**Sample data**
- https://github.com/simpledotorg/h360tk_grafana_core/blob/demo/cascade-cohort/test_data/demo/README.md
- https://github.com/simpledotorg/h360tk_grafana_core/blob/demo/cascade-cohort/test_data/demo/build_demo_data.py
- https://github.com/simpledotorg/h360tk_grafana_core/blob/demo/cascade-cohort/test_data/demo/seed_screening_cascade.sql
- https://github.com/simpledotorg/h360tk_grafana_core/blob/demo/cascade-cohort/test_data/demo/verify_demo.sql

**Earlier vertical cascade**, already folded into the branch above
https://github.com/simpledotorg/h360tk_grafana_core/tree/demo/screening-cascade-vertical

**Commits by theme**

| Theme | Commits |
| --- | --- |
| Treatment cascade and quarterly cohort panels | `43d62be` |
| Screening cascade | `ca7c024`, `8c4f5ef`, `4fa33b7`, `65ba9de` |
| Cohort report, headlines, latest completed month | `85e2664` |
| hearts360 look and CSS, HTN tab | `80e00b8` |
| hearts360 look and CSS, DM tab | `34d6fcc` |
| Treatment outcomes card | `dbf7984` |
| Tooltips, colors, layout | `874672d` |
| Target line | `5664631` |
| Overdue list, auto-save, XLSX download | `c540dd7`, `08a2894` |
| Sample data | `6d73971`, `6324567` |

**Overlapping work.** https://github.com/tonyjoyk/h360tk_grafana_core/pull/7 is a second take on the HTN quarterly cohort chart, based on 0.5.0. It overlaps `43d62be` and `85e2664`. Pick one, do not merge both.

---

## 2. Drug stock

On the `tonyjoyk` fork only. **Ignore `simpledotorg`'s `feature/drug-stock-mvp`. It is out of date.**

- Feature branch, tip `4a3f900`: https://github.com/tonyjoyk/h360tk_grafana_core/tree/feature/drug-stock-mvp

**Merged story PRs**

| PR | Story |
| --- | --- |
| https://github.com/tonyjoyk/h360tk_grafana_core/pull/1 | 1.2 form and sheet contract |
| https://github.com/tonyjoyk/h360tk_grafana_core/pull/2 | 1.3 sheet pull into Postgres |
| https://github.com/tonyjoyk/h360tk_grafana_core/pull/3 | 2.1 patient-days view |
| https://github.com/tonyjoyk/h360tk_grafana_core/pull/4 | 2.2 dashboard chrome |
| https://github.com/tonyjoyk/h360tk_grafana_core/pull/6 | 2.3 stock-on-hand table |

**Open. Do not merge as is.**
https://github.com/tonyjoyk/h360tk_grafana_core/pull/5 (demo seed). It deletes and inserts patient rows on any fresh install.

**Planning docs.** These record what was already decided for drug stock: the PRD, the architecture, the UX and the epics. Read them so you do not re-decide things that are settled, and so the new reports stay consistent with them.

- Idea: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/forge/hearts360-drug-stock/forged-idea.md
- Research: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/research/technical-hearts360-drug-stock-2026-09-22/research.md
- Source PRD: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/research/technical-hearts360-drug-stock-2026-09-22/imports/simple-dashboard-drug-stock-prd.md
- PRD: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/prds/prd-h360-toolkit-internal-2026-09-22/prd.md
- PRD addendum: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/prds/prd-h360-toolkit-internal-2026-09-22/addendum.md
- Architecture: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/architecture/architecture-h360-toolkit-internal-2026-09-27/ARCHITECTURE-SPINE.md
- Epics: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/epics.md
- UX design: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/ux-designs/ux-h360-toolkit-internal-2026-09-27/DESIGN.md
- UX experience: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/ux-designs/ux-h360-toolkit-internal-2026-09-27/EXPERIENCE.md
- Tree panel handoff: https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/_bmad-output/planning-artifacts/ux-designs/ux-h360-toolkit-internal-2026-09-27/imports/tree-panel-v2-handoff.md

**Capture contract**
- https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/drug_stock/form/form_field_spec.json
- https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/drug_stock/form/wide_to_long.json
- https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/drug_stock/pull/env.contract.json

**Screenshots**
- https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/.cursor/skills/verify-h360tk-grafana-core/evidence/20260927T115741Z/drug-stock-table.png
- https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/.cursor/skills/verify-h360tk-grafana-core/evidence/20260927T115741Z/drug-stock-month-keeps-location.png
- https://github.com/tonyjoyk/h360tk_grafana_core/blob/feature/drug-stock-mvp/.cursor/skills/verify-h360tk-grafana-core/evidence/20260927T115741Z/drug-stock-empty-location.png

---

## 3. Integration notes

### Different bases

Cascade is built on 0.6.0. Drug stock migrations are numbered `0.5.1_to_0.5.2` through `0.5.5_to_0.5.6`. Those clash with upstream's `0.5.1_to_0.6.0`. Renumber them onto the 0.6.x line.

### Expect conflicts in two places

- `heart360.hypertension-diabetes.program.json`
- The `\ir` block in `pg_init_scripts/01_heart360_tables.sql`

### Security issue, fix before any report writes data

The `postgres-hypertension` datasource connects as `heart360tk`, the role that owns all the data. Open-source Grafana lets any signed-in user query any datasource, so any Viewer can run any SQL, including writes, through `/api/ds/query`. Access checks of the form `WHERE '${isAllowed}' = '1'` are filled in by the browser, so a direct API call skips them. The overdue-list auto-save already uses this path.

Fix: point dashboards at a read-only role, and send writes through a server-side endpoint that checks the Grafana session and calls a `SECURITY DEFINER` function.

### Drug stock bugs to fix, not carry forward

1. Latest wins is decided by sheet row order, not `submitted_at`.
2. A real Google Form response sheet is wide, but `pull.py` expects long rows. The Form has never fed the puller end to end.
3. Submitter identity is not recorded and history is not kept.
4. The drug stock board has no per-user location scoping.
5. Patient-days goes wrong when a strength is left blank, and the All row reads too low.

---

## 4. Reverse engineering helper

https://github.com/tonyjoyk/rea

Useful code for reverse-engineering the titration and protocol adherence reports. Use this rather than reading the Excel tool by hand.

---

## 5. Protocol adherence report tool

https://github.com/tonyjoyk/protocol_adherance_report_tool (private)

**The medicine format for this whole project comes from here.** It follows the Indonesia format. We can change it later. The medicines file lives in this repo.

### What the tool is

A small Excel tool that turns a spreadsheet of hypertension patient visits into a protocol adherence report. It shows how many patients sit on each step of the 6-step HTN medication ladder, and how many of those have blood pressure under control. It runs entirely inside Excel on Mac or Windows. No uploads, no server.

### Feature map

| Piece | What it does |
| --- | --- |
| File picker | Click a button, pick one or more visit files. |
| Column finder | Finds `Tanggal`, `NIK`, `Tekanan Darah`, `Obat` by name. Any column order works. |
| Date parser | Reads both `01/06/2026` and `2026-06-01`. |
| Medicine reader | Splits the `Obat` cell on `;`, `\|` or new lines, reads each prescription. |
| Dose calculator | Turns "Lisinopril 10 mg - 1 x 2 Tablet Sehari" into 20 mg/day. N doses times M tablets times strength. |
| Step classifier | Puts each visit into Step 1 to 6, Other Protocol, Non-Protocol or Unrecognized, based on drug plus dose. |
| HTN whitelist | About 70 other hypertension drugs. If any appear, the patient is Non-Protocol. |
| Patient rollup | Dedupes by `NIK`. Keeps earliest visit as registration date, plus latest visit and latest step. |
| BP check | A visit is controlled if systolic is under 140 and diastolic is under 90. |
| 90-day cohort | Window is the last 90 days before the newest visit in the file. Same file gives the same report. |
| Two variants | Strict counts only established patients. Lenient counts new registrations too. |
| Report writer | Writes a new xlsx with Report, Patients and Raw Data sheets into `generated_reports/`. |

**Flow:** visits file, split by `Obat` entry, score each entry, roll up per patient, filter to the 90-day cohort, count by step with BP control, write the report.

---

## 6. AI prototype and research archive

https://github.com/tonyjoyk/hearts360ai

`hearts360ai` is the AI for Quality Improvement prototype for HEARTS360. A React and Vite app built in Lovable. It shows district managers which facilities need attention each month and why. It turns hypertension indicators into short plain-language insights: BP control, missed visits, titration, statins, BP fudging and drug stock. It can embed into the HEARTS360 dashboard as a side panel.

- Feature map: https://github.com/tonyjoyk/hearts360ai/blob/research/ai-work-history/README.md#feature-map
- Research index: https://github.com/tonyjoyk/hearts360ai/blob/research/ai-work-history/research/README.md

The `research/` folder holds all the AI work so far: the April 2026 design sprint prototype, field reviews from Ethiopia and Bangladesh, Metabase titration and statin reports, the Sylhet AI supervision report, and cross-country facility performance findings.

---

## 7. Source material for the report rules

These are local files, not yet in a repo. Tony will attach or push them.

| File | What it gives you |
| --- | --- |
| `Data review Jimma Zone.docx` | How an Ethiopian zone officer picks facilities. Adds the size rule: weight large facilities higher, because they hold more uncontrolled patients. |
| `Design sprint _AI integration simple and metabase report_Addis ketema HC.docx` | The full prioritization algorithm, written step by step. Includes the two-sided rule. |
| `District Observations- Chattogram District.docx` | Hard thresholds from Bangladesh. Control under 50%, uncontrolled over 20%, missed visits over 25%, LTFU over 20%. |
| `What drives facility performance: findings from Bangladesh, Sri Lanka and Ethiopia.md` | The weighting evidence. Tells you which actions actually move the number. |
| `SQL queries for the facility performance analysis, by country.md` | About 70 named queries across Bangladesh, Sri Lanka and Ethiopia. Your stored-query library. |
| `sylhet-2026-08-v7-supervision.html` | The working prototype of the answer shape. Computed gain per action, drug-stock gating, fixed slots per facility. |

### Two rules from these files that must shape the reports

**1. Prioritization is two-sided.** Do not just sort facilities worst to best. Addis Ketema flags Kolfe HC, which has 76% BP control, 10% uncontrolled and 14% missed visits. It looks excellent on any ranking. It gets flagged because its BP fudging score is 5.42 and its titration rate is 29.5%. A low-to-high sort would never surface it.

**2. Weight recommendations by evidence, not by what is easy to compute.** From the cross-country analysis:

| Lever | Effect |
| --- | --- |
| Getting new patients back for a second visit | Biggest lever. 31% to 34% of new patients never return within 90 days. Attendance explains 57% to 74% of why facilities differ in control among new patients. |
| Capturing an active phone number | Plus 5 to 12 points of return |
| First appointment inside about 35 days | More than 70 days out costs 15 to 24 points of return |
| Calling overdue patients early | Works, but only 1% to 15% of overdue patients with a phone get called. Late calls work much less. |
| Stepping up treatment | Plus 3.8 to 6.3 points of control. Real but modest. |
| Fixing drug stock | Weak in the data, but it gates calling and titration in practice. |

**Honesty constraint.** The levers we can act on explain only 2% to 12% of why one facility beats another. Any recommendation the chat makes has to carry that ceiling, not imply certainty.

---

## 8. The chat prototype, for phase 4

### What it is

A chat plugin that floats over Grafana. A program manager or facility manager looking at a dashboard uses it to understand what they are seeing.

### How it behaves

- Guided prompt chips they click, not a blank box
- Claude API behind it for now, swappable later
- Stored, curated queries from the SQL library rather than free SQL
- Answers in the clear-writing style: short sentences, plain words, no jargon

### The answer shape

Someone asks "why is my BP control low?" and gets back:

1. A short ranked list of likely reasons. Each names a number. For example: "28% of new patients did not come back for a second visit."
2. Under each reason, a "what to do" block. For example: "Create a plan to call new patients."
3. Under that, a nudge that turns it into a real plan. For example: "How many patients should I call?"

Two or three reasons. Not ten. Ranked by the evidence table above, not by what is easiest to query.

### Constraints

- Prototype. Simplest thing that works.
- Usability matters more than completeness.
- Charts follow the design system already used by the existing graphs.
- Write the tradeoffs down, in the PRD or a separate document.

---

## 9. Things Tony still needs to confirm

Ask about these in your first reply rather than guessing.

1. Which repo has BMAD installed and should hold these two files.
2. Whether `protocol_adherance_report_tool` has been pushed yet, and the exact path of the medicines file inside it.
3. Where the protocol adherence rules Tony wrote live now.
4. The statin eligibility rules, and their source.
5. Which BP fudging formula ships. NHF's query, or the corrected version in the cross-country analysis. NHF's drops a decimal and understates the bias.
6. Whether the overdue calling report is a separate older branch, or the overdue list already in `demo/cascade-cohort`.
7. The env var name for the Claude API key, and whether an external API call is acceptable on local fake data.
8. Grafana version and how to run the toolkit locally.
9. Chat scope for v1. District, facility or both. Hypertension only, or diabetes too.
10. GitHub access, including the private repos.
