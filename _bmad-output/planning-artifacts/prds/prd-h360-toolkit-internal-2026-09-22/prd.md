---
title: HEARTS360 leaf drug stock tracking (India/IHCI prototype)
status: final
created: 2026-09-22
updated: 2026-09-27
---

# PRD: HEARTS360 leaf drug stock tracking

*Working title — India/IHCI internal prototype.*

## 0. Document Purpose

This PRD defines the **v1 internal prototype** for monthly hypertension protocol **Drug Stock** reporting and **Patient-Days** availability on the **leaf** HEARTS360 Toolkit. Audience: product/engineering reviewing before UX (Figma) and architecture. Vocabulary is Glossary-anchored; capabilities use stable **FR-*** IDs; inferred items use `[ASSUMPTION]`.

**Builds on (does not duplicate):**

- Forge: `_bmad-output/forge/hearts360-drug-stock/forged-idea.md`
- Approved research: `_bmad-output/planning-artifacts/research/technical-hearts360-drug-stock-2026-09-22/research.md`
- UX parity reference: Simple **dashboard** Drug Stock PRD (not Simple app Progress tab)

Mechanism/transport (Form→Sheet→Postgres, SQL views) lives in `addendum.md` — this PRD states **what** users can do and see.

## 1. Vision

Programme managers using leaf HEARTS360 Grafana today see hypertension reach and control — but not whether facilities have enough protocol drugs on the shelf. Facility staff still report stock through ad-hoc spreadsheets, and Simple’s dashboard already showed what “good” looks like: a **Drug Stock** report with category grouping, patient-days, colour thresholds, and clear missing vs zero semantics.

This prototype brings that **reporting experience** into HEARTS360’s leaf Grafana, while letting facility staff enter **stock on hand** once a month through the simplest Google-friendly path. Patient-days use **H360 patient counts** and published IHCI-style coefficients — not typed consumption. The goal is an **internal shareable prototype**, not a ministry-wide rollout.

## 2. Target User

### 2.1 Jobs To Be Done

- **Facility staff (functional):** Once a month, quickly report how many tablets of each tracked HTN protocol drug/dose are on the shelf for my facility — without learning Grafana.
- **Programme manager (functional):** See, by facility and drug category, how many **Patient-Days** of stock remain, with the same visual language as Simple’s dashboard, inside leaf Grafana.
- **Programme manager (social/contextual):** Share a credible internal prototype with RTSL/IHCI colleagues that feels familiar if they know Simple.
- **Builder (contextual):** Prove BMAD→design→build path on a real Toolkit feature without expanding scope to a full Simple port.

### 2.2 Non-Users (v1)

- National/central dashboard operators (no central Drug Stock surface in v1).
- Community-level facility staff `[ASSUMPTION: exclude community-size facilities like Simple PRD]`.
- Patients / public.
- Ministry production operators expecting LMIS replacement.

### 2.3 Key User Journeys

**UJ-1. Ananya submits her facility’s month-end stock.**
- **Persona + context:** Ananya, nurse at a PHC in an IHCI district, owns the medicine cupboard count.
- **Entry state:** She has a phone/browser and the shared Google Form link; she knows her facility name.
- **Path:** Opens Form → picks facility + reporting month → enters **In-Stock** for each tracked drug/dose (blank = unknown; `0` = none) → submits.
- **Climax:** Confirmation that the report was received.
- **Resolution:** She can correct later by submitting again for the same month (latest wins) or via the ops correction path documented for the prototype.
- **Edge case:** She only knows some drugs — blanks allowed; those show as unknown on the report, not as zero.

**UJ-2. Vikram reviews Drug Stock on leaf Grafana.**
- **Persona + context:** Vikram, district programme manager, already uses HEARTS360 leaf Grafana for HTN dashboards.
- **Entry state:** Logged into leaf Grafana; Drug Stock dashboard available.
- **Path:** Opens Drug Stock → sets **Reporting Month** → uses **Change location** tree to pick an org unit (or leaves nationwide) → scans category blocks (CCB → ARB → Diuretic → Other) → reads Patient-Days and colour cues, including missing/zero/unknown cells.
- **Climax:** He can answer “which facilities are &lt;30 Patient-Days for CCB?” without opening a spreadsheet.
- **Resolution:** Returns next month; historical months remain selectable.
- **Edge case:** Facility never submitted — row shows “?” / missing report styling, not zero.

## 3. Glossary

- **Drug Stock** — Monthly facility report of tablet counts for tracked protocol drugs; the Grafana report surface that displays them.
- **In-Stock** — Count of tablets on hand at the facility for a **Protocol Drug** at the end of the **Reporting Month** (`in_stock` only; no received/consumption fields in v1).
- **Protocol Drug** — A hypertension protocol drug/dose combination configured as stock-tracked (e.g. Amlodipine 5 mg).
- **Drug Category** — Grouping of Protocol Drugs for reporting: CCB, ARB, Diuretic, Other (display order fixed).
- **Reporting Month** — Calendar month the stock snapshot is for (may be backdated relative to submission time).
- **Patient-Days** — Days of medicine remaining for a Drug Category at a facility: tablets (dose-normalized) ÷ (**Patients** × category coefficient × **Load Factor**), using IHCI/Simple-style formulas.
- **Patients** — Facility hypertension patient denominator used in Patient-Days; v1 uses **cumulative registered** HTN patients from H360 `[ASSUMPTION: map to HEART360_PATIENTS_REGISTERED / equivalent org_unit grain]`.
- **Load Factor** — Patient load correction factor applied in Patient-Days; v1 defaults to **1.0 (100%)** `[ASSUMPTION: bake in like Simple PRD states]`.
- **Stock Submission** — One user submission of In-Stock values for a facility + Reporting Month (may cover a subset of Protocol Drugs).
- **Latest Wins** — If multiple Stock Submissions exist for the same facility + Reporting Month + Protocol Drug, the most recently submitted value is used on the report.
- **Leaf Grafana** — HEARTS360 Toolkit Grafana at a leaf deploy (`h360tk_grafana_core` / demo), not the central/national dashboard.
- **Org Unit** — A node in the leaf facility hierarchy (`org_units`); Drug Stock charts/tables filter to that node and its descendants (or nationwide when none selected).
- **Change Location** — The Tree Panel V2 org-unit picker row in Leaf Grafana (single-select tree writing hidden `org_unit`). MVP uses this **only** — not Simple district/hospital/UHC chrome and not top cascading `ou_*` dropdowns.

## 4. Features

### 4.1 Monthly Stock Entry (facility staff)

**Description:** Facility staff submit In-Stock counts via a Google Form (or equivalent Google Sheet path if Form is unavailable) without needing Grafana accounts. Realizes UJ-1. Entry UX prioritizes speed and familiarity over Grafana-native forms. `[ASSUMPTION: Research selected Form→Sheet as simplest among Grafana/Form/Sheet; forge left that choice open — this PRD locks the research pick for the prototype.]`

**Functional Requirements:**

#### FR-1: Submit In-Stock for Reporting Month

Facility staff can submit In-Stock for one or more Protocol Drugs for their facility and a selected Reporting Month. Realizes UJ-1.

**Consequences (testable):**
- Submission records facility, Reporting Month, Protocol Drug, In-Stock value (or blank), and submission timestamp.
- Blank In-Stock means **unknown**; explicit `0` means **none on shelf**.
- `received` / consumption fields are not collected.

#### FR-2: Latest Wins on resubmit

Facility staff can submit again for the same facility + Reporting Month; Latest Wins applies per Protocol Drug.

**Consequences (testable):**
- Report shows the newest submission’s In-Stock for that Protocol Drug.
- Prior submissions remain stored for audit in the prototype `[ASSUMPTION: retain history rows even if UI only shows latest]`.

#### FR-3: Facility scoped to entrant’s site

Entrant selects (or is limited to) their own facility; district/central bulk entry is not a v1 job.

**Consequences (testable):**
- Form facility list includes only eligible facilities for the prototype cohort.
- Community-size facilities are omitted `[ASSUMPTION: Simple parity filter]`.

#### FR-13: Toolkit store of record for submissions

Accepted Stock Submissions are stored in the leaf Toolkit database (not only in Google Sheet). Google Sheet is an entry/transport surface for the prototype.

**Consequences (testable):**
- Leaf Grafana Drug Stock reads In-Stock and Patient-Days from Toolkit/Postgres-backed data (or a view over it), not by treating the Sheet as the dashboard system of record.
- Re-ingest or correction that updates the Toolkit store changes the report without requiring a Grafana Sheets datasource.

### 4.2 Drug Stock report (Leaf Grafana)

**Description:** Programme managers see a Drug Stock report in Leaf Grafana whose **report semantics closely match Simple’s dashboard Drug Stock report** (categories, Patient-Days, missing/zero/unknown, thresholds), adapted to Grafana panels. **Navigation is HEARTS360-native:** Change Location tree + Reporting Month — not Simple’s district/hospital/UHC chrome. Realizes UJ-2.

**Functional Requirements:**

#### FR-4: Drug Stock dashboard surface

Programme managers can open a dedicated Drug Stock dashboard (or clearly named section) in Leaf Grafana. Realizes UJ-2.

**Consequences (testable):**
- Dashboard is reachable from the leaf Grafana navigation/home alongside existing HTN surfaces.
- Central/national Grafana does not include this surface in v1.

#### FR-5: Simple-parity layout semantics

The report displays facilities × Protocol Drugs with:

- Grouping by Drug Category in fixed order: **CCB → ARB → Diuretic → Other**; empty categories hidden.
- Only stock-tracked Protocol Drugs shown.
- Patient-Days shown per Drug Category (and/or per Simple-equivalent summary cells).
- Colour thresholds on Patient-Days: **&lt;90**, **&lt;60**, **&lt;30** days `[ASSUMPTION: include &lt;90 even if some Simple mocks omitted it]`.

**Consequences (testable):**
- Visual QA checklist against Simple dashboard Drug Stock screenshots/PRD passes for grouping, missing/zero/unknown, and thresholds (Grafana-native chrome allowed).

#### FR-6: Missing vs zero vs unknown

Report distinguishes:

| Situation | Display |
|-----------|---------|
| No Stock Submission for facility/month | Missing report (“?” / greyed) |
| Blank In-Stock for a Protocol Drug | Unknown (“-”) |
| Explicit `0` | Zero (“0”) |

**Consequences (testable):**
- Automated or manual fixture tests cover all three states.

#### FR-7: Reporting Month control

Programme managers can select Reporting Month on the Drug Stock dashboard. Realizes UJ-2.

**Consequences (testable):**
- Changing month updates In-Stock and Patient-Days to that month’s Latest Wins values.
- Historical months with prior submissions remain viewable.

#### FR-14: Change Location org-unit filter

Programme managers filter Drug Stock by Org Unit using the Change Location tree (Tree Panel V2 pattern). Empty / unselected = nationwide. Realizes UJ-2.

**Consequences (testable):**
- Selecting a place scopes tables/charts to that Org Unit and descendants.
- Clearing selection (nationwide) shows all in-scope facilities for the prototype.
- MVP does **not** include top cascading `ou_1…ou_7` dropdowns or dual-control with the tree.
- Simple district/hospital/UHC selectors are **not** used for navigation.

#### FR-8: CSV download of current view — **deferred (not MVP)**

Programme managers can download a CSV of the current Drug Stock view.

**Status:** Out of MVP per 2026-09-27 scope cut. Do not implement in the prototype. Revisit if programme asks for Delhi-style export.

### 4.3 Patient-Days calculation

**Description:** System computes Patient-Days from In-Stock, Patients, dose-normalization coefficients, category coefficients, and Load Factor — IHCI/Simple-style — without requiring staff to enter consumption.

**Functional Requirements:**

#### FR-9: Dose-normalized stock

In-Stock counts for related doses are combined with published dose coefficients before category Patient-Days (e.g. Amlo 10 mg counts as 2× Amlo 5 mg).

**Consequences (testable):**
- Fixture with Amlo5=100, Amlo10=50 yields normalized stock 200 for CCB numerator inputs.

#### FR-10: Patients from H360

Patients for a facility come from H360 Postgres (registered HTN patients), not from the Stock Submission form.

**Consequences (testable):**
- Changing underlying registered patient counts changes Patient-Days without a new stock entry.
- Definition is documented as cumulative registered `[ASSUMPTION: org_unit = facility grain matches stock facility]`.

#### FR-11: Configurable protocol coefficients

Patient-Days use deploy/config coefficients for the prototype’s India/IHCI protocol set (e.g. AATTCC vs ATTACC style tables from Simple/IHCI).

**Consequences (testable):**
- Switching config changes Patient-Days for the same In-Stock and Patients.
- Load Factor defaults to 1.0.

### 4.4 Protocol Drug configuration (prototype ops)

**Description:** Prototype operators can define which Protocol Drugs are stock-tracked and their Drug Category — analogous to Simple’s protocol drug settings, even if the admin UX is config/file-based for the prototype.

#### FR-12: Stock-tracked Protocol Drug set

Operators can mark Protocol Drugs as stock-tracked and assign Drug Category.

**Consequences (testable):**
- Non-tracked drugs never appear on Form or report.
- Category drives grouping and Patient-Days formula selection.

## 5. Non-Goals (Explicit)

- Full port of Simple drug-stock workflows, app Progress tab, or Simple auth.
- Simple dashboard **district / hospital / UHC** navigation chrome (reference for report semantics only).
- Top cascading org-unit dropdowns (`ou_1…ou_7`) dual-controlling with the tree (deferred; tree-only in MVP).
- Collecting **received** or **consumption/dispensed**.
- Central/national Drug Stock dashboard.
- Predicting future stock / indenting orders.
- Offline-first entry.
- Indonesia (or non-IHCI) coefficient sets as primary v1 config.
- Replacing state LMIS systems.
- Patient-level stock or dispensing records.

## 6. MVP Scope

### 6.1 In Scope

- Google Form (or Sheet) monthly In-Stock entry for facility staff → Toolkit store of record (FR-1–FR-3, FR-13).
- Leaf Grafana Drug Stock with Simple **report** semantics: categories, Patient-Days, colour thresholds, missing/zero/unknown (FR-4–FR-6).
- Reporting Month switch (FR-7).
- Change Location tree org-unit filter; empty = nationwide (FR-14).
- Patient-Days from H360 Patients + configurable IHCI/Simple coefficients (FR-9–FR-12).
- Latest Wins.
- Internal prototype packaging (compose/demo path for shareable demos).

### 6.2 Out of Scope for MVP

- CSV download (FR-8 deferred).
- Cascading `ou_*` dropdowns alongside the tree.
- Simple district/hospital/UHC chrome as navigation.
- Production ministry hardening, SSO to Google for all states, multi-tenant Google Workspace governance.
- Business Forms / in-Grafana entry as primary path.
- Google Sheets as Grafana **system of record** (Sheets may feed ingest only).
- Central rollup.
- Perfect pixel match to Simple CSS — **semantic/layout parity** only.

## 7. Success Metrics

**Primary**

- **SM-1**: Internal reviewers who know Simple’s Drug Stock report rate the Grafana view as “recognizably the same report” on a 1–5 scale (target ≥4 median) after a guided walkthrough. Validates FR-5, FR-6.
- **SM-2**: Facility staff complete a Stock Submission in ≤5 minutes in a moderated prototype test (n≥3). Validates FR-1, UJ-1.

**Secondary**

- **SM-3**: Patient-Days for a golden fixture match hand-calculated IHCI/Simple formula within rounding tolerance. Validates FR-9–FR-11.

**Counter-metrics (do not optimize)**

- **SM-C1**: Number of Grafana plugins / custom panels — do not add complexity to chase pixel parity (reuse Tree Panel V2 pattern; do not invent a second org picker).
- **SM-C2**: Fields on the entry form — do not add `received`/consumption “for completeness.”
- **SM-C3**: Export affordances — do not add CSV “for completeness” in MVP.

## 8. Open Questions

*Deferred at finalize — not phase-blockers for UX/architecture start. Owner = Tony unless noted; revisit before implementation stories.*

1. Exact H360 SQL definition for Patients (registered) per facility/month — confirm against reporting views. **Revisit:** architecture / first spike.
2. First prototype state/protocol (AATTCC vs ATTACC / which drug list). **Revisit:** before coeff config.
3. Who hosts the Google Form/Sheet for the internal prototype (RTSL vs other). **Revisit:** before prototype demo share.
4. Figma: new frames vs annotated Simple screenshots as interim UX source of truth. **Revisit:** `bmad-ux` kickoff.
5. CSV export (deferred FR-8) — revive only if programme explicitly needs Delhi-style download. **Revisit:** post-MVP.
6. Whether cascading `ou_*` returns later as optional secondary control. **Revisit:** after tree-only prototype proves out.

## 9. Assumptions Index

- Exclude community-size facilities (Simple parity) — still provisional; not re-litigated in 2026-09-27 cut.
- Patients = cumulative registered HTN mapped to H360 registered reporting tables.
- Load Factor = 1.0.
- Include &lt;90 day colour threshold.
- Retain submission history; UI shows Latest Wins.
- Report **semantics** match Simple; navigation is Change Location tree + month (not Simple chrome).
- Form→Sheet locked as entry path (research pick over forge’s open trio).
- Toolkit/Postgres is store of record; Sheet is not Grafana SoT.
- Org filter = tree-only in MVP; empty `org_unit` = nationwide.

## 10. Sources / inputs

- Forge hardened idea (2026-09-22)
- Technical research (2026-09-22) — Form→Sheet→Postgres→Grafana recommendation
- Simple dashboard Drug Stock PRD v1 (dashboard only)
- Party-mode MVP scope cut (2026-09-27) — tree-only nav; no CSV; keep missing/zero/unknown
- Tree Panel V2 handoff + screenshot (UX imports, 2026-09-27)
