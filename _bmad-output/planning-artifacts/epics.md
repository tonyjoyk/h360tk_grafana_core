---
stepsCompleted:
  - step-01-validate-prerequisites
  - step-01-confirmed
  - step-02-design-epics
  - step-03-create-stories-draft
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-h360-toolkit-internal-2026-09-22/prd.md
  - _bmad-output/planning-artifacts/prds/prd-h360-toolkit-internal-2026-09-22/addendum.md
  - _bmad-output/planning-artifacts/architecture/architecture-h360-toolkit-internal-2026-09-27/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/ux-designs/ux-h360-toolkit-internal-2026-09-27/DESIGN.md
  - _bmad-output/planning-artifacts/ux-designs/ux-h360-toolkit-internal-2026-09-27/EXPERIENCE.md
  - _bmad-output/planning-artifacts/research/technical-hearts360-drug-stock-2026-09-22/research.md
---

# h360-toolkit-internal - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for h360-toolkit-internal (HEARTS360 leaf Drug Stock MVP), decomposing the requirements from the PRD, UX Design, Architecture, and technical research into implementable stories.

## Requirements Inventory

### Functional Requirements

FR-1: Facility staff can submit In-Stock for one or more Protocol Drugs for their facility and a selected Reporting Month (blank = unknown; `0` = none; no received/consumption fields).
FR-2: Resubmit for same facility + Reporting Month applies Latest Wins per Protocol Drug (newest In-Stock shown; prior values superseded per architecture upsert).
FR-3: Entrant selects (or is limited to) their own facility; Form facility list is prototype cohort only and omits community-size facilities; no district/central bulk entry in v1.
FR-4: Programme managers can open a dedicated Drug Stock dashboard in Leaf Grafana (reachable from leaf nav/home); central/national Grafana does not include this surface in v1.
FR-5: Report shows facilities × Protocol Drugs with Drug Category order CCB → ARB → Diuretic → Other (empty categories hidden); only stock-tracked drugs; Patient-Days per category; colour thresholds &lt;90 / &lt;60 / &lt;30 (plus ≥90 ok).
FR-6: Report distinguishes missing report (`?` / greyed), unknown blank In-Stock (`—`), and explicit zero (`0`).
FR-7: Programme managers can select Reporting Month; changing month updates In-Stock and Patient-Days to that month’s Latest Wins; historical months remain viewable.
FR-8: CSV download of current Drug Stock view — **deferred / not MVP**.
FR-9: Related doses are dose-normalized before category Patient-Days (e.g. Amlo 10 mg = 2× Amlo 5 mg).
FR-10: Patients (N) come from H360 Postgres cumulative registered HTN patients, not from the Stock Submission form.
FR-11: Patient-Days use configurable India/IHCI protocol coefficients; Load Factor defaults to 1.0; switching config changes Patient-Days for same stock and N.
FR-12: Operators can mark Protocol Drugs as stock-tracked and assign Drug Category; non-tracked drugs never appear on Form or report.
FR-13: Accepted Stock Submissions are stored in leaf Toolkit Postgres (Sheet is transport only); Grafana reads Postgres-backed data, not Sheets-as-SoT.
FR-14: Programme managers filter by Org Unit via Change Location tree (Tree Panel V2); empty = nationwide; no cascading `ou_1…ou_7` or Simple district/hospital/UHC chrome in MVP.

### NonFunctional Requirements

NFR-1: Semantic/layout parity with Simple Drug Stock report (grouping, missing/zero/unknown, thresholds) — Grafana-native chrome allowed; not pixel-perfect CSS port (SM-1).
NFR-2: Facility staff complete a Stock Submission in ≤5 minutes in moderated prototype test (SM-2).
NFR-3: Patient-Days for golden fixtures match hand-calculated IHCI/Simple formula within rounding tolerance (SM-3).
NFR-4: Do not add Grafana plugins/custom panels beyond enabling Tree Panel V2 pattern for org pick (SM-C1).
NFR-5: Do not expand Form fields with received/consumption “for completeness” (SM-C2).
NFR-6: Do not add CSV/export affordances in MVP (SM-C3).
NFR-7: Accessibility floor — Patient-Days not colour-only (retain numeric); distinct `?` / `—` / `0`; tree and month keyboard-operable within Grafana; Form labels associated; facility + month required (UX EXPERIENCE).
NFR-8: Grafana dashboard datasource role remains read-only for Drug Stock panels; writes only via ingest (Architecture AD-4; research SELECT-only guidance).
NFR-9: Pull ingest fail-closed — failed pulls must not corrupt existing Latest Wins rows (Architecture deploy envelope).
NFR-10: Secrets (Sheet ID, Google SA) live in leaf deploy secrets — never in knowledge repo or dashboard JSON (Architecture).

### Additional Requirements

- **Repo / branch:** Implement in `h360tk_grafana_core` on `feature/drug-stock-mvp` (from `0.5.1`); demo may supply Sheet ID, SA credentials, active programme env only (AD-2).
- **Paradigm:** Pipes-and-filters — Form→Sheet→leaf pull→Postgres→SQL view→Grafana; no Simple runtime dependency (AD-1, AD-11).
- **Ingest:** Scheduled (or ops-triggered) **leaf pull** via Google Sheets API + service account; physical UPSERT on `(org_unit_id, reporting_month DATE yyyy-mm-01, drug_id)`; persist `submitted_at`; no Apps Script push API; no append+ROW_NUMBER Latest Wins for MVP (AD-4, AD-5).
- **Sheet column contract:** At least `org_unit_id`, `reporting_month`, `drug_code`, `in_stock`, optional `submitted_at` (Architecture conventions).
- **Facility key:** Form submits `org_units.id` (names display-only); ingest rejects unresolvable rows out of reporting view (AD-6).
- **Storage tri-state:** `in_stock` nullable numeric — NULL unknown, `0` zero; ingest must not coerce blank to 0 (AD-12).
- **Config:** Country/programme-keyed `drug_config` + `coeff_config` in Postgres; single deploy setting activates programme for **both** pull and view; India/IHCI seed (AATTCC vs ATTACC pick at seed) (AD-7).
- **Patients N:** Join `heart360tk_reporting.HEART360_PATIENTS_REGISTERED` (or successor) on `org_unit_id`; never under-care; story acceptance verifies exact SQL grain (AD-8; research caveat ~LTFU) (AD-8).
- **Patient-Days view:** One SQL reporting view — Latest Wins ⨝ registered N ⨝ coeffs with dose normalization + Load Factor 1.0; panels read only (AD-9).
- **Schemas:** Prefer `heart360tk_schema` / `heart360tk_reporting`; tables/views `drug_stock_*` (Architecture).
- **Dashboard isolation:** New Drug Stock dashboard JSON (own UID + nav); do not mutate baseline HTN dashboards; enable `equansdatahub-tree-panel` in core image as part of this feature (AD-10; addendum).
- **Reporting Month vs Grafana time picker:** Stock month is dashboard variable `reporting_month`; document so users do not confuse with host time range (UX; Architecture).
- **Ops:** Form/Sheet hosting (RTSL vs ministry) before demo share; Form facility list synced to leaf org tree; community sites excluded via list curation (AD-1/AD-6; research OQ).
- **Form facility list maintenance (MVP ops, not Grafana admin UI):** Export eligible `org_units` (id + name) from leaf Postgres; set Google Form Facility choices so label = name and submitted value = `org_units.id`; refresh manually when the prototype cohort/org tree changes — no continuous Grafana↔Form sync product in MVP.
- **Explicitly rejected / deferred:** Business Forms entry; Sheets datasource as SoT; CSV (FR-8); cascades + tree dual control; central Drug Stock; received/consumption; country self-serve admin UI; full audit history table (Architecture Deferred; research; addendum).
- **Research open for stories:** Exact registered N SQL vs programme; patient–facility assignment for multi-site; protocol seed choice AATTCC vs ATTACC.

### UX Design Requirements

UX-DR1: Ship Drug Stock as a **standalone** leaf Grafana dashboard with vertical stack: title → Reporting Month variable → Change location row → Stock on hand table section (DESIGN layout).
UX-DR2: Enable Change location via `equansdatahub-tree-panel` — sentence-case row title “Change location”, empty panel title, search + tree, single-select → hidden `org_unit`; empty = nationwide; **no** top `ou_*` cascades on this dashboard (DESIGN + EXPERIENCE).
UX-DR3: Reporting Month as Grafana variable with end-of-month style labels (e.g. `Sep-2026`); offer ~6 recent months; changing month reloads table without clearing org selection (DESIGN + EXPERIENCE).
UX-DR4: Drug Stock table — sticky facility column; category groups **CCB → ARB → Diuretic → Other**; hide empty categories; drug name+dose headers; In-Stock numerics; per-category Patient days column; default sort by facility name; optional **All** totals row when nationwide (DESIGN + EXPERIENCE).
UX-DR5: Patient-Days cell backgrounds (not text-only): &lt;30 critical `#E02F44`, ≥30&lt;60 low `#FF9830`, ≥60&lt;90 watch `#F2CC0C`, ≥90 ok `#56A64B` (DESIGN tokens).
UX-DR6: Missing report row — grey background `#EFEFEF` with `?` glyphs; unknown stock cell — muted em dash `—`; explicit zero — `0` (DESIGN + EXPERIENCE state patterns).
UX-DR7: Empty location selection copy: “No facilities for this location.” (EXPERIENCE).
UX-DR8: Microcopy — “Change location”, “Stock on hand”, “Patient days”; Form helper “Leave blank if unknown”; never show `0` for never-submitted facilities (EXPERIENCE voice).
UX-DR9: Google Form UX — linear facility → month → per-drug In-Stock → submit; success confirmation; blanks allowed; required facility + month; native number validation (EXPERIENCE Flow A).
UX-DR10: Panel description (or equivalent) clarifying Reporting Month ≠ Grafana time picker (EXPERIENCE).
UX-DR11: Accessibility — numeric Patient-Days retained with colour; distinct `?`/`—`/`0`; no hover-only filters; keyboard-operable tree/month within Grafana (EXPERIENCE).
UX-DR12: Do not port Simple district/hospital/UHC/Download Report chrome; no Drug consumption tab; no dual tree+cascade controllers (DESIGN don’ts + EXPERIENCE banned).

### FR Coverage Map

FR-1: Epic 1 — Submit In-Stock for facility + Reporting Month
FR-2: Epic 1 — Latest Wins on resubmit / re-pull
FR-3: Epic 1 — Facility scoped to entrant; prototype cohort; omit community-size
FR-4: Epic 2 — Dedicated Drug Stock dashboard in Leaf Grafana
FR-5: Epic 2 — Simple-parity layout semantics (categories, thresholds)
FR-6: Epic 2 — Missing vs zero vs unknown display
FR-7: Epic 2 — Reporting Month control
FR-8: Deferred — CSV download (not MVP)
FR-9: Epic 2 — Dose-normalized stock
FR-10: Epic 2 — Patients N from H360 registered
FR-11: Epic 2 — Configurable protocol coefficients + Load Factor 1.0
FR-12: Epic 1 — Stock-tracked Protocol Drug set + categories
FR-13: Epic 1 — Toolkit Postgres store of record (Sheet = transport)
FR-14: Epic 2 — Change Location tree org-unit filter

## Epic List

### Epic 1: Monthly facility stock entry into the Toolkit
Facility staff can submit In-Stock via Google Form for their site and Reporting Month; submissions land in leaf Postgres with Latest Wins; ops can define stock-tracked Protocol Drugs and keep the Form facility list aligned to `org_units` (manual refresh when cohort changes).
**FRs covered:** FR-1, FR-2, FR-3, FR-12, FR-13

## Epic 1: Monthly facility stock entry into the Toolkit

Facility staff can submit In-Stock via Google Form for their site and Reporting Month; submissions land in leaf Postgres with Latest Wins; ops can define stock-tracked Protocol Drugs and keep the Form facility list aligned to `org_units`.

**repos:** `h360tk_grafana_core` (`feature/drug-stock-mvp`); Form/Sheet hosting is ops (may use demo env for secrets later).

### Story 1.1: Configure stock-tracked Protocol Drugs

As a prototype operator,
I want Protocol Drugs marked stock-tracked with Drug Category (and programme key) in leaf Postgres,
So that the Form and later report only show the India/IHCI drugs we intend to track.

**Acceptance Criteria:**

**Given** a leaf Postgres with existing `heart360tk` schemas
**When** migrations/seeds for drug (and programme) config are applied in `h360tk_grafana_core`
**Then** stock-tracked Protocol Drugs exist keyed by country/programme with Drug Category in {CCB, ARB, Diuretic, Other}
**And** non-tracked drugs are distinguishable so they will not appear on Form or report (FR-12)

**Given** India/IHCI is the active programme seed (AATTCC vs ATTACC chosen and documented in the seed)
**When** the active programme deploy setting is set
**Then** queries for the active set return only that programme’s drugs
**And** pull and future reporting view will use the same activation setting (AD-7)

**Given** an operator needs to change which drugs are tracked
**When** they update config via SQL/seed (no self-serve admin UI in MVP)
**Then** the change is durable in Postgres without editing Grafana panel JSON

### Story 1.2: Google Form and Sheet capture with org_units facility keys

As a facility staff member,
I want to submit monthly In-Stock on a Google Form for my facility without a Grafana account,
So that reporting is fast and familiar (UJ-1).

**Acceptance Criteria:**

**Given** ops has configured a Google Form + response Sheet for the prototype
**When** I open the Form
**Then** I can select facility, Reporting Month, and In-Stock per stock-tracked Protocol Drug from Story 1.1
**And** blank In-Stock is allowed (unknown); explicit `0` means none on shelf; no received/consumption fields (FR-1, NFR-5, UX-DR9)

**Given** the Facility question options
**When** I pick a facility by name
**Then** the submitted/stored value is `org_units.id` (names are display-only) (AD-6)
**And** the option list is the prototype cohort only and omits community-size facilities (FR-3)

**Given** ops needs to refresh facilities after org tree changes
**When** they export eligible `org_units` (id + name) from leaf Postgres and update Form choices
**Then** the Form list matches the leaf hierarchy again
**And** there is no requirement for continuous Grafana↔Form product sync in MVP

**Given** I complete a valid submission
**When** I submit
**Then** I see a success confirmation
**And** a row appears on the Sheet with at least `org_unit_id`, `reporting_month`, `drug_code` (or equivalent per drug), `in_stock`, optional `submitted_at` (Architecture Sheet contract)

### Story 1.3: Leaf pull ingest Sheet into Postgres (Latest Wins)

As a prototype operator,
I want a leaf job to pull the Sheet into Toolkit Postgres with Latest Wins,
So that Grafana can read stock from the Toolkit store of record, not from Sheets-as-SoT (FR-13).

**Acceptance Criteria:**

**Given** Story 1.1 config and Sheet rows from Story 1.2
**When** the scheduled or ops-triggered pull job runs in `h360tk_grafana_core`
**Then** valid rows upsert into `drug_stock_submission` (or equivalent) on natural key `(org_unit_id, reporting_month DATE yyyy-mm-01, drug_id)` (AD-5)
**And** Grafana dashboard DB role is not used for these writes (AD-4)

**Given** a resubmit or Sheet edit for the same facility + month + drug
**When** pull runs again
**Then** the prior In-Stock for that key is replaced (Latest Wins / FR-2)
**And** `submitted_at` (or pull timestamp) is persisted on the row

**Given** `in_stock` blank/unknown vs `0` vs positive
**When** rows are ingested
**Then** storage keeps `NULL` for unknown/blank and `0` for explicit zero — blank is never coerced to `0` (AD-12, FR-6 storage)

**Given** a Sheet row whose `org_unit_id` does not resolve to `org_units`
**When** pull validates the row
**Then** the row is rejected/quarantined and does not appear as stock in the reporting tables (AD-6)

**Given** the pull fails mid-run (API/auth error)
**When** the job exits
**Then** existing Latest Wins rows are left intact (fail-closed) (NFR-9)

**Given** Sheet ID and Google service account credentials
**When** the leaf is deployed
**Then** secrets come from deploy env — not committed to the knowledge repo or dashboard JSON (NFR-10)

### Epic 2: Drug Stock report with Patient-Days in leaf Grafana
Programme managers open a dedicated Drug Stock dashboard, select Reporting Month and Change location (tree), and see Simple-parity In-Stock + Patient-Days (dose-normalized, registered N, coeffs, missing/zero/unknown).
**FRs covered:** FR-4, FR-5, FR-6, FR-7, FR-9, FR-10, FR-11, FR-14

## Epic 2: Drug Stock report with Patient-Days in leaf Grafana

Programme managers open a dedicated Drug Stock dashboard, pick Reporting Month and Change location, and see Simple-parity In-Stock + Patient-Days.

**repos:** `h360tk_grafana_core` (`feature/drug-stock-mvp`)
**Depends on:** Epic 1 store + drug config (stories 1.1–1.3).

### Story 2.1: Patient-Days reporting view (registered N + coeffs)

As a programme manager,
I want Patient-Days computed correctly from stock, H360 registered patients, and IHCI coefficients,
So that availability numbers match the agreed formula (FR-9–FR-11, SM-3).

**Acceptance Criteria:**

**Given** Epic 1 upserted stock and active programme drug config
**When** coeff config is seeded for the same country/programme (Load Factor default 1.0) and the reporting view is created
**Then** Patient-Days = dose-normalized stock ÷ (Patients × Load Factor × category coeff) in **one** SQL view/contract (AD-9, FR-9, FR-11)
**And** panels must read this contract — not reimplement protocol math in Grafana

**Given** patients denominators in H360
**When** the view joins N
**Then** N comes from `heart360tk_reporting.HEART360_PATIENTS_REGISTERED` (or successor of same grain) on `org_unit_id`
**And** under-care is never used; N is never taken from the Form (FR-10, AD-8)

**Given** a golden fixture (e.g. Amlo5=100, Amlo10=50 → normalized 200 for CCB inputs)
**When** Patient-Days is computed
**Then** results match hand-calculated IHCI/Simple formula within rounding tolerance (NFR-3)
**And** story acceptance documents the exact registered SQL grain verified against programme

**Given** the active programme deploy setting from Epic 1
**When** the view resolves coeffs and drugs
**Then** it uses that **same** setting as the pull job (AD-7)

### Story 2.2: Drug Stock dashboard with Reporting Month and Change location

As a programme manager,
I want a dedicated Drug Stock dashboard with Reporting Month and Change location tree,
So that I can open the report from leaf Grafana and scope it like other HEARTS360 surfaces (FR-4, FR-7, FR-14).

**Acceptance Criteria:**

**Given** leaf Grafana from `h360tk_grafana_core`
**When** Drug Stock is provisioned
**Then** a **new** dashboard JSON exists with its own UID and nav/home link
**And** baseline HTN dashboards are not mutated (AD-10, FR-4)

**Given** the dashboard layout
**When** I open Drug Stock
**Then** I see vertical stack: title → Reporting Month variable → Change location row → Stock on hand section (UX-DR1)
**And** Drug Stock is a standalone dashboard (no HTN/DM/Overdue tabs required on this board)

**Given** Reporting Month variable
**When** I change month
**Then** the report targets that month’s Latest Wins stock
**And** labels use end-of-month style (e.g. `Sep-2026`) with ~6 recent months; org selection is not cleared (FR-7, UX-DR3)
**And** a panel description (or equivalent) clarifies Reporting Month ≠ Grafana time picker (UX-DR10)

**Given** `equansdatahub-tree-panel` is enabled in the core Grafana image as part of this feature
**When** I use Change location
**Then** sentence-case “Change location”, search + single-select tree writes hidden `org_unit`; empty = nationwide (descendants / all-org pattern)
**And** no top cascading `ou_1…ou_7` appear on this dashboard (FR-14, UX-DR2, UX-DR12, NFR-4)

### Story 2.3: Stock on hand table with Simple-parity semantics

As a programme manager,
I want the Stock on hand table to show category groups, Patient-Days colours, and missing/zero/unknown clearly,
So that the report feels like Simple’s Drug Stock without Simple chrome (FR-5, FR-6, SM-1).

**Acceptance Criteria:**

**Given** the reporting view from Story 2.1 and dashboard chrome from Story 2.2
**When** I view Stock on hand
**Then** facilities × Protocol Drugs are grouped CCB → ARB → Diuretic → Other; empty categories are hidden; only stock-tracked drugs show (FR-5, UX-DR4)
**And** sticky facility column; default sort by facility name; optional All totals row when nationwide

**Given** Patient-Days values
**When** cells render
**Then** backgrounds use &lt;30 critical, ≥30&lt;60 low, ≥60&lt;90 watch, ≥90 ok per DESIGN tokens (not text-only colour) (UX-DR5)
**And** the numeric Patient-Days value remains visible (UX-DR11, NFR-7)

**Given** missing report vs blank In-Stock vs explicit zero
**When** those states appear
**Then** missing report = greyed row with `?`; unknown = muted `—`; zero = `0` — never show `0` for never-submitted facilities (FR-6, UX-DR6, UX-DR8)

**Given** an org selection with no facilities
**When** the table region renders
**Then** empty copy is “No facilities for this location.” (UX-DR7)

**Given** MVP scope
**When** the dashboard ships
**Then** there is no CSV/Download Report, no Simple district/hospital/UHC chrome, and no Drug consumption tab (FR-8 deferred, UX-DR12, NFR-6)
