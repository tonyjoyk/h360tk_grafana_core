# Screening and treatment cascades

The Hypertension tab now opens with two cascade charts on one card. They replace the old "Screening-to-treatment cascade" card.

**The numbers for population, prevalence and screening are example data for Indonesia. They are not program data.**

## Open the demo

1. Start the demo: `./scripts/demo_up.sh`
2. Open the Hypertension tab: <http://localhost:3100/d/heart360_showcase?var-org_unit=&-dtab=Hypertension>
3. Sign in as `admin` / `admin`.

If your stack uses port 3000, change `3100` to `3000` in the link.

## What you see

| Chart | What it shows | Where the numbers come from |
|---|---|---|
| **Screening cascade** (left) | Adults screened this year: eligible, screened, raised BP, given starter medicine, diagnosed with hypertension | Example data (seed 50) |
| **Treatment cascade** (right) | Estimated adults with hypertension, then registered, under care and BP controlled | Estimate: example population × example prevalence (11.94%). The other three numbers are live patient data. |

- Each bar is a share of the first bar in its chart.
- The grey line under each count is the step rate, or the progress against the target.
- Dashed lines are targets: "Year target 46%" on screened and "Year goal 11%" on diagnosed.
- The diagnosed bar has a dashed divider and a hatched fill because it comes from a different system (EHR, not CKG).
- The month is the latest completed month (October 2026 in the demo). Screening counts are year to date.

## How to use it

- **Pick a location.** Open **Change location** and pick a region, district, PHC or SHC. Both charts change to that location.
- **Read the info icons.** The (i) next to each chart title gives the data source and the definitions.
- **On a phone.** The two charts go one above the other. Swipe the screening chart left to see all five steps.

## Change names, targets or step 4

The chart settings are in one place: `COUNTRIES` at the top of `dashboard_src/cascade/cascade.js`.

1. Edit the `idn` entry. For example:
   - Rename a step: `linked: 'Referred to puskesmas'`
   - Hide step 4: `showLinked: false`
   - Change a target: `screenedTargetPct: 50`
2. Run `python3 scripts/build_cascade_panel.py`.
3. Run `python3 scripts/check_htn_dm_untouched.py --print-hashes`. Copy the new `panel-stc` hash into `REVIEWED_EDITS` in that script.
4. Refresh Grafana. It reloads the dashboard in about 10 seconds.

### Other countries

The design uses one five-step standard for every country. Only the names, base, year start and targets change. `COUNTRIES` already has entries for India (`ind`) and Ethiopia (`eth`), taken from the design. To show a different country, set `ACTIVE` to its code and load that country's data.

## Files

| File | What it is |
|---|---|
| `dashboard_src/cascade/cascade.js` | Drawing code and the country settings |
| `dashboard_src/cascade/cascade.css` | Styles |
| `dashboard_src/cascade/panel.sql` | The query: one row of numbers |
| `scripts/build_cascade_panel.py` | Writes the three files into the Hypertension tab (`--check` to test) |
| `test_data/demo/seeds/50_cascade_indonesia.sql` | Temporary example data |

## Hand-over to backend work (0.8.0)

This build is the front end only. The data tables are temporary demo tables. The real data work is in these stories, assigned to Gyan:

| Temporary demo table | Replaced by |
|---|---|
| `demo_cascade_population` | H360-496 and H360-501 (population file and load) |
| `demo_cascade_prevalence` | H360-504 (estimate from population and prevalence) |
| `demo_cascade_screening` | H360-503 and H360-505 (monthly screening file and load), H360-498 (diagnosed from EHR) |
| Targets in `COUNTRIES` | H360-499 (yearly screening target) |

When a real table is ready, change only `dashboard_src/cascade/panel.sql`. Keep the same output columns: `reporting_month`, `adults`, `prevalence_pct`, `estimated`, `screening_rows`, `screened`, `raised`, `linked`, `diagnosed`, `registered`, `under_care`, `controlled`. Then retire seed 50.

**Note:** the demo tables exist only after `demo_up.sh` runs the seeds. On an install without the demo seed, the panel shows a query error until the real tables exist.

## Design sources

- `_bmad-output/planning-artifacts/research/htn-cascade-2026-11-18/imports/` (the approved HTML design, the design decisions and the example data)
- BMAD plan: `prds/prd-htn-cascade-2026-11-18/`, `ux-designs/ux-htn-cascade-2026-11-18/`, `architecture/architecture-htn-cascade-2026-11-18/` and `epics-htn-cascade.md`, all under `_bmad-output/planning-artifacts/`
