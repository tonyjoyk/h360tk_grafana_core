# HEARTS360 drug stock (v1) — forged idea

## Build
- Thin monthly facility snapshot: enter HTN protocol drug **stock on hand** (`in_stock` only).
- Show **patient-days of stock remaining** (availability) to programme managers on **leaf Grafana**.
- Patient-days: PRD-style stock ÷ (Patients × coefficients × LoadFactor); **Patients from H360 Postgres** (not typed).
- Entrants: **facility staff** for their own facility.
- First geography: **India / IHCI**; formulas start from Simple **dashboard** PRD.
- Entry path: choose simplest user-centric among Grafana / Google Form / Google Sheet (Google OK for first programmes). View in Grafana is mandatory; entry need not be.

## Rejected for v1
- Faithful port of full Simple drug-stock workflows/UI.
- Collecting `received` or consumption/dispensed.
- Central/national drug-stock dashboard.
- Indonesia as primary v1 target.

## Reference
- `/Users/tony/Downloads/PRD_ Drug Stock Tracking.md` (dashboard only; ignore Simple app Progress tab).

## Open for Phase 1 (`bmad-deep-recon`)
- Exact H360 patient-count definition vs Simple “assigned/registered”.
- Which entry path wins on simplicity/UX.
- Drug list + per-state coefficients from PRD → H360 config shape.
- Facility-type filters, color thresholds, CSV download — keep/drop vs Simple PRD.
