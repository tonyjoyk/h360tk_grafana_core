---
status: final
stepsCompleted:
  - step-01-validate-prerequisites
  - step-02-design-epics
  - step-03-create-stories
  - step-04-final-validation
mode: headless
style: ASD-STE100 (about 80%)
created: 2026-11-18
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-htn-cascade-2026-11-18/prd.md
  - _bmad-output/planning-artifacts/ux-designs/ux-htn-cascade-2026-11-18/DESIGN.md
  - _bmad-output/planning-artifacts/ux-designs/ux-htn-cascade-2026-11-18/EXPERIENCE.md
  - _bmad-output/planning-artifacts/architecture/architecture-htn-cascade-2026-11-18/ARCHITECTURE-SPINE.md
---

# Hypertension cascades: epics and stories

One epic. Four stories. Do them in order. All four are front end or demo data. The backend stays with Gyan (see "Not in this epic").

**Epic number:** 14. Numbers 8 to 13 are used in the review plan (`review-2026-11/epics-review-fixes.md`).

**Rules for every story:**
- `scripts/check_htn_dm_untouched.py` exits 0.
- `scripts/verify_seeds_insert_only.sh` exits 0.
- Do not add a migration. Do not change patient rows.

## Requirements map

| Story | FRs | Jira |
|---|---|---|
| 14.1 | FR-94, FR-98 | H360-463, H360-454 (demo data only) |
| 14.2 | FR-90 to FR-93, FR-95 to FR-97, FR-99, FR-100 | H360-463, H360-454 |
| 14.3 | FR-89, FR-101, NFR-16, NFR-18 | H360-458, H360-399 |
| 14.4 | NFR-17, NFR-20, NFR-21 | H360-464, H360-455 (number checks) |

## Not in this epic (Gyan, 0.8.0)

| Jira | What | Replaces |
|---|---|---|
| H360-496, H360-501 | Population file format and load | `demo_cascade_population` |
| H360-504 | Estimate from population and prevalence | `demo_cascade_prevalence` |
| H360-503, H360-505 | Monthly screening file format and load | `demo_cascade_screening` |
| H360-498 | Diagnosed this year, from EHR data | `demo_cascade_screening.diagnosed` |
| H360-499 | Yearly screening target | Targets in `COUNTRIES` |

---

## Epic 14: Hypertension cascades on the Hypertension tab

Reviewers see the new screening and treatment cascades on the Hypertension tab, with Indonesia example data.

### Story 14.1: Load Indonesia example data

As the design owner, I want example Indonesia data in the demo, so that the charts show real-looking numbers.

**Owns:** `test_data/demo/seeds/50_cascade_indonesia.sql`

**Acceptance criteria:**
- **Given** the seed, **When** it runs, **Then** it makes three tables: `demo_cascade_population`, `demo_cascade_prevalence` and `demo_cascade_screening`.
- **Given** the seed, **When** it runs, **Then** the org units with patients get adults aged 15+ for 2026. The total is 2,100,000.
- **Given** the seed, **When** it runs, **Then** prevalence for 2026, 15+, is 11.94%.
- **Given** October 2026 at national level, **When** you add the rows, **Then** the totals are 840,000 screened, 75,600 raised BP, 41,000 given starter medicine and 18,900 diagnosed.
- **Given** the seed runs two times, **When** it ends, **Then** the row counts do not change.
- **Given** the seed file, **When** the insert-only check runs, **Then** it passes.

### Story 14.2: Draw the two cascades

As a country reviewer, I want to see screening and treatment on one card, so that I read them as one story.

**Owns:** `dashboard_src/cascade/cascade.js`, `dashboard_src/cascade/cascade.css`, `dashboard_src/cascade/panel.sql`

**Acceptance criteria:**
- **Given** all locations, **When** the card shows, **Then** the screening bars show 100%, 40%, 3.6% and 0.9% (step 4 hidden). The screened bar has a dashed target line and the status "87% of target".
- **Given** the same view, **When** you read the treatment half, **Then** the estimate is 250,740. Registered, under care and BP controlled match the live reporting tables.
- **Given** `showLinked: true` in `COUNTRIES.idn`, **When** you rebuild, **Then** "Given starter medicine" shows as step 4.
- **Given** the treatment chart, **When** you read it, **Then** every percent is a share of the estimate, and there are no step-rate lines.
- **Given** the screening chart, **When** you read a bar after "Adults screened", **Then** a grey line shows the share of the step before, for example "9% of screened".
- **Given** a new step name in `COUNTRIES.idn`, **When** you rebuild, **Then** the new name shows.
- **Given** a place with no screening rows, **When** the card shows, **Then** the left half says "No screening data for this place and month." It does not show zero.
- **Given** a 375 px wide screen, **When** the card shows, **Then** the treatment half is below the screening half, and the screening chart scrolls sideways.

### Story 14.3: Put the card on the Hypertension tab

As the design owner, I want the new card in place of the old cascade, so that reviewers see it first.

**Owns:** `scripts/build_cascade_panel.py`, `panel-stc` in the program dashboard, `REVIEWED_EDITS` in `scripts/check_htn_dm_untouched.py`

**Acceptance criteria:**
- **Given** the Hypertension tab, **When** it opens, **Then** the cascade card takes two of three columns, with two charts of equal width. "Patients protected from heart attacks and strokes" is in the third column. No count or label overlaps at 1366 px.
- **Given** one location, **When** you select it, **Then** both halves show only that location.
- **Given** `build_cascade_panel.py --check`, **When** it runs, **Then** it exits 0.
- **Given** `check_htn_dm_untouched.py`, **When** it runs, **Then** it exits 0. **When** any other Hypertension panel changes, **Then** it fails.
- **Given** a user without access, **When** they open the tab, **Then** the card shows no numbers.

### Story 14.4: Wire the demo and write the guide

As the design owner, I want one link and one short guide, so that I can show the demo and hand the branch to Gyan.

**Owns:** `scripts/demo_up.sh` (link text only), `docs/cascades.md`

**Acceptance criteria:**
- **Given** `demo_up.sh` finishes, **When** you read the output, **Then** it prints a link to the Hypertension tab and names `docs/cascades.md`.
- **Given** `docs/cascades.md`, **When** you read it, **Then** it says how to open the demo, how to use the card, how to change settings, and which Gyan stories replace the demo tables.
- **Given** the card, **When** you read the footnote, **Then** it says that the population, prevalence and screening numbers are example data.
- **Given** the branch, **When** you run `python3 scripts/verify_banned_words.py`, **Then** it exits 0.

## Sprint status lines

Added to `_bmad-output/implementation-artifacts/sprint-status.yaml`:

```yaml
  epic-14: in-progress
  14-1-load-indonesia-example-data: done
  14-2-draw-the-two-cascades: done
  14-3-put-the-card-on-the-hypertension-tab: done
  14-4-wire-the-demo-and-write-the-guide: done
  epic-14-retrospective: optional
```
