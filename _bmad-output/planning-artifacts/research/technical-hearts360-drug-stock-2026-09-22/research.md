---
title: 'technical research: HEARTS360 drug stock v1'
type: 'technical'
topic: 'HEARTS360 drug stock v1 (leaf Grafana patient-days + monthly facility entry)'
decision: 'How to implement thin monthly facility drug stock for India/IHCI in leaf H360; which entry path among Grafana/Form/Sheet; whether Patients can be derived from H360'
source: 'run'
status: complete
preset: 'standard'
validation: 'normal'
created: '2026-09-22'
updated: '2026-09-22'
verified_claims: 14
unverified_claims: 3
---

# technical research: HEARTS360 drug stock v1

**Decision this research serves:** How to implement thin monthly facility drug stock for India/IHCI in leaf HEARTS360 — entry path + patient-days on Grafana — without a full Simple port.

## Executive summary

**Do this for v1:** Facility staff enter monthly **`in_stock` via Google Form → Google Sheet**; a small **ingest upserts into leaf Postgres**; leaf Grafana reads a **SQL view** that joins stock to **H360 patient counts** and IHCI coefficients to show **patient-days remaining** with table colour thresholds.

**Why:** Grafana is a weak form app (Business Forms needs custom write APIs and fights read-only Postgres guidance) [1][2]. Form→Sheet is the simplest facility-staff UX and Google is allowed [3][4]. Patient-days math is published by IHCI/WHO (stock ÷ (N × coeff), with dose conversion) [5][6] — not consumption. H360 already has reporting tables for **patients registered** and **under care** [7], so deriving N is feasible **if you lock one definition** (recommend cumulative registered for IHCI parity) [5][8].

**Biggest caveat:** “Registered” vs “under care” diverge (~11% LTFU in early IHCI districts) [8]. Wrong N systematically misstates availability. Sheets-as-Grafana-datasource alone is a fragile long-term SoT when joining clinical Postgres [9][10].

---

## 1. Entry options (select)

### Requirements frame (from forged idea — not web)
Hard gates: programme managers **view** in leaf Grafana; entry may be outside Grafana; entrants = facility staff; Google OK; simplest user-centric wins.

### Candidate screen
| Candidate | Screen |
|-----------|--------|
| Grafana Business Forms | Passes technically; fails “simplest for facility staff” |
| Google Form → Sheet → (Grafana or Postgres) | Passes |
| Direct Sheet → Grafana | Passes |
| Annotations / Infinity write-back | Cut — wrong model / read-only sheets [1][9] |

### Evidence
- Business Forms supports GET/POST to datasource or REST; REST often needs NGINX for CORS; Postgres write via custom SQL is community-fragile [1][11].
- Grafana Postgres guidance prefers **SELECT-only** DB users [2].
- Official **Google Sheets datasource is read-only**; query by spreadsheet+range; JWT service account; cache 5m default [9].
- Google Forms can land responses in a Sheet; Supports required + numeric validation [3][12].

### Verdict (entry)
| Pick | Google Form → Sheet for entry |
|------|-------------------------------|
| Runner-up | Direct Sheet if staff already live in locked templates |
| Avoid for v1 | In-Grafana Business Forms (ops + auth + write-path cost) |

**Display path:** Prefer **Sheet → Postgres ingest → Grafana Postgres** over Sheets datasource as SoT (see §3). Sheets datasource is acceptable only for a throwaway pilot.

---

## 2. Patient-days computation

### Published IHCI pattern
- **patient-days ≈ tablets_in_stock ÷ (N × daily_coeff)** with tablets normalized to base strength (e.g. Amlo 10 mg = 2× Amlo 5 mg) [5][6][13].
- Example published coeffs (AATTCC / ATTACC): Amlo5 **1.4 / 1.12**; Telmi40 **0.37 / 0.65**; Chlor12.5 **0.06 / 0.06** [5].
- Operational N in facility tools: **cumulative patients registered under IHCI** [5][13].
- Simple product docs distinguish **registered** (dashboard) vs **assigned** (stock form); reassignment matters [14].
- Research papers sometimes use **under care** (≥1 visit in 12 months) for availability KPIs — different from ready-reckoner N [8].
- No public source uses the Simple PRD name **LoadFactor**; buffers appear as min stock months / forecasting extras [5][15].

### Import: Simple dashboard PRD
Matches the above pattern (state-specific formulas, dose coefficients, patients in denominator) [20]. Also collected `received` — **out of scope** for H360 v1 per forge. Multiple reports/month → latest wins — retain as reporting rule.

### Import: H360 schema
Leaf DB has `patients`, `org_units` (facility hierarchy), and reporting tables including **`HEART360_PATIENTS_REGISTERED`** and **`HEART360_PATIENTS_UNDER_CARE`** [7]. No drug-stock tables today.

### Implication
Deriving Patients from H360 is **feasible**. Lock **registered** (IHCI parity) unless programme explicitly wants under-care and accepts non-comparability with IHCI ready reckoners [5][8].

---

## 3. Data & Grafana integration

- Colour thresholds on Table panels (colored background / text) support &lt;90 / &lt;60 / &lt;30 style views [16].
- “Latest submission wins” via Grafana **Group by + Last** is order-fragile; **Postgres `DISTINCT ON` / upsert** is the reliable pattern [10][17].
- Joining stock to patient counts and coefficients is far simpler in a **SQL view** than multi-datasource transforms [10].
- Infinity/CSV is for HTTP/inline CSV — not a facility upload UI; older CSV plugin deprecated [18].

### Recommended architecture sketch
```text
Facility staff
  → Google Form (in_stock, facility, month, drug)
  → Sheet (raw responses + optional curated tab)
  → Ingest (Apps Script / cron): validate, upsert drug_stock_submission
  → SQL view: latest in_stock ⨝ H360 Patients(N) ⨝ coeff_config
  → Leaf Grafana Postgres → Table (days remaining + thresholds)
```

---

## 4. Implementation reality

| Concern | Form→Sheet→Postgres→Grafana | Sheets-direct in Grafana | Business Forms in Grafana |
|---------|----------------------------|---------------------------|---------------------------|
| Facility UX | Strong | Medium–strong | Weak |
| Join to H360 N | Native | Brittle | Possible if write API |
| Latest-wins | Upsert | Transform risk | API design |
| Ops | Small ingest job | Sheet schema drift, API cache | Plugin + CORS + write path |
| Reversibility | Edit sheet / resubmit → re-ingest | Cell edit | API update |

Monthly cadence keeps Google Sheets API quotas comfortable [19].

---

## Cross-dimension insights

1. **Entry simplicity and calculation correctness pull opposite directions on Sheets-as-SoT.** Form/Sheet wins entry; Postgres wins patient-days join — use both (entry in Google, truth in Postgres).
2. **H360 already models the registered vs under-care fork** in reporting tables [7] — the open forge crack is a product choice, not a missing schema.
3. **IHCI coefficients are public** [5][6] — H360 needs **config by state/protocol**, not secret programme math.

---

## Recommendations (for PRD / architecture)

1. **Adopt Form → Sheet → Postgres ingest → leaf Grafana view** as the default v1 approach. Confidence: **high** (vendor docs + IHCI primaries + local schema).
2. **Lock N = facility HTN cumulative registered** (map to `HEART360_PATIENTS_REGISTERED` or equivalent), document assignment/org_unit rules; do not silently use under care. Confidence: **high** for IHCI parity; **medium** until exact H360 SQL definition is verified against programme.
3. **Store coefficients + dose conversion rules as deploy config** (start from IHCI AATTCC/ATTACC / Simple PRD state tables). Confidence: **high**.
4. **Keep Sheets datasource as optional pilot only**, not production SoT. Confidence: **high**.
5. **Defer** central dashboard, `received`, consumption, Indonesia coeffs, community-facility policy until after leaf v1. Confidence: **high** (forge locks).

---

## Open questions

| # | Question | How to close |
|---|----------|--------------|
| 1 | Exact SQL for “registered” N per facility/month in current H360 dashboards | Read reporting view defs in `h360tk_grafana_core`; compare to IHCI guide |
| 2 | Org_unit = facility assignment rules for multi-site patients | Product + code review |
| 3 | Which Indian states/protocols in first deploy (AATTCC vs ATTACC) | Programme confirm |
| 4 | Grafana version in deployed leaf images (Sheets plugin needs ≥11.6) | Inspect running image / Dockerfile |
| 5 | Who hosts Google Workspace (RTSL vs ministry) and sheet sharing model | Ops interview |
| 6 | Keep Simple PRD CSV download + community-facility filter? | Product after UX sketch |

---

## Source appendix

| # | Supports | Publisher | Pub date | Accessed | Confidence |
|---|----------|-----------|----------|----------|------------|
| [1] | Business Forms panel capabilities | [Grafana Labs](https://grafana.com/grafana/plugins/volkovlabs-form-panel/) | 2026-06-02 | 2026-09-22 | high |
| [2] | Postgres DS prefer SELECT-only | [Grafana Labs](https://grafana.com/docs/learning-paths/postgresql-data-source/prepare-configuration/) | undated | 2026-09-22 | high |
| [3] | Forms → Sheet destination | [Google](https://support.google.com/docs/answer/2917686) | evergreen | 2026-09-22 | high |
| [4] | Forge lock: Google OK for first programmes | imports/forged-idea.md | 2026-09-22 | 2026-09-22 | high |
| [5] | IHCI patient-days coeffs / N=registered | [WHO India IHCI PDF](https://cdn.who.int/media/docs/default-source/india-news/india-hypertension-control-initiative/cvh-hpertension-india.pdf) | ~2019–21 | 2026-09-22 | high |
| [6] | Ready reckoner / strength conversion | [RTS IHCI job aid](https://resolvetosavelives.org/wp-content/uploads/2023/09/ihci-ready-reckoner-job-aid.pdf) | 2023-09 | 2026-09-22 | high |
| [7] | H360 REGISTERED / UNDER_CARE tables | local `h360tk_grafana_core` SQL | 0.5.0 tree | 2026-09-22 | high |
| [8] | Registered vs under care divergence | [Nature J Hum Hypertens 2022](https://www.nature.com/articles/s41371-022-00742-5) | 2022-08-09 | 2026-09-22 | high |
| [9] | Google Sheets DS read-only + cache | [Grafana Sheets docs](https://grafana.com/docs/plugins/grafana-googlesheets-datasource/latest/) | 2026-08-17 | 2026-09-22 | high |
| [10] | Prefer DB for latest-wins + joins | Grafana transform docs + Postgres DISTINCT ON practice | 2025–26 | 2026-09-22 | medium–high |
| [11] | Business Forms REST/CORS | [Grafana Forms REST docs](https://grafana.com/docs/plugins/volkovlabs-form-panel/latest/rest-api/) | undated | 2026-09-22 | high |
| [12] | Forms response validation | [Google](https://support.google.com/docs/answer/3378864) | evergreen | 2026-09-22 | high |
| [13] | PLOS supply-chain / patient-days field use | [PLOS One 2023](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0295338) | 2023-12-14 | 2026-09-22 | high |
| [14] | Simple registered vs assigned | [docs.simple.org dashboard/app features](https://docs.simple.org/readme/dashboard-features.md) | undated | 2026-09-22 | medium |
| [15] | HEARTS supply module (related, not same coeffs) | WHO HEARTS | 2020 | 2026-09-22 | medium |
| [16] | Table thresholds | [Grafana Table viz](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/table/) | undated | 2026-09-22 | high |
| [17] | Group by Last community caveat | Grafana community | 2025-01 | 2026-09-22 | medium |
| [18] | CSV plugin deprecation → Infinity | [Grafana blog](https://grafana.com/blog/how-to-visualize-csv-data-with-grafana/) | undated | 2026-09-22 | high |
| [19] | Sheets API quotas | [Google](https://developers.google.com/workspace/sheets/api/limits) | 2026-09-03 | 2026-09-22 | high |
| [20] | Simple dashboard drug stock PRD (import) | imports/simple-dashboard-drug-stock-prd.md | v1 historical | 2026-09-22 | high (as import) |

---

## Staleness map

| Claim class | Freshness bar | Earliest re-check |
|-------------|---------------|-------------------|
| Grafana plugin versions / Sheets DS | ≤ 1 month | **2026-10-22** |
| Google Workspace Form/Sheet behaviour | ≤ 6 months | 2027-03-22 |
| IHCI coefficients / ready reckoner | ≤ 12 months (confirm state still uses same protocol) | 2027-09-22 |
| H360 schema (REGISTERED/UNDER_CARE) | on next core version bump | with `h360tk_grafana_core` release |

Earliest refresh trigger: **Grafana plugin/version check ~2026-10-22**.
