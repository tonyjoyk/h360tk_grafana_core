# Clinical rules companion — HEARTS360 MVP

Companion to `ARCHITECTURE-SPINE.md`. The spine's CR-1 to CR-6 and AD-22 to AD-27 are the rules. This file fixes the exact column names, threshold rows, parser cases, medicine seed rows, hand-checked fixtures and the demo seed plan, so independent units build to the same contract. If this file and the spine disagree, the spine wins.

## 1. Report function columns

Every `report_*` row starts with the standard columns `org_unit_id int, org_unit_name text, level int, is_selected boolean, too_few boolean, flag boolean, flag_reason text`. Measures follow in this order. Counts are `bigint`; percents are `numeric` rounded to 1 decimal; the score is rounded to 2 decimals.

| Function | Measure columns |
| --- | --- |
| `report_adherence(month, org, include_new)` | `cohort_n, controlled_n, controlled_pct, off_protocol_pct, one_medicine_pct` |
| `report_adherence_buckets(month, org, include_new)` | selection only: `bucket text, bucket_order int (1-9), label text, patients_n, controlled_n, controlled_pct` |
| `report_titration(month, org)` | `uncontrolled_visits_n, stepped_up_n, titration_pct, excluded_too_recent_n, excluded_no_baseline_n` |
| `report_fudging(month, org)` | `readings_n, band_135_139_n, band_140_144_n, score, control_pct, looks_fine_check boolean` |
| `report_fudging_histogram(month, org)` | selection only: `band_low int, band_high int, readings_n, highlight boolean` (bands 120-124 … 150-154) |
| `report_statins(month, org)` | `eligible_n, on_statin_n, on_statin_pct, not_on_statin_n` |
| `report_statins_patients(month, org)` | no standard columns: `patient_id, patient_name, age, reason_eligible, last_visit_date, org_unit_name` |
| `report_calling(month, org)` | `overdue_n, overdue_with_phone_n, called_n, called_pct, early_n, early_pct, agreed_n, call_again_n, removed_n, return_known_n, returned_n, returned_pct, returned_early_pct, returned_later_pct, return_not_yet_known_n, calls_per_week` |
| `report_new_patients(month, org)` | `new_patients_n, new_returned_n, new_loss_pct, new_usable_phone_n, new_usable_phone_pct` |
| `report_flags(month, org)` | `org_unit_id, org_unit_name, report text, flag_reason text` |
| `chat_control_summary(month, org)` | standard columns without flag, then `under_care_n, controlled_n, controlled_pct, uncontrolled_n, uncontrolled_pct, missed_visit_pct, ltfu_pct` (HTN tab formulas) |
| `chat_drug_stock_gate(month, org)` | `org_unit_id, category text, patient_days numeric, low boolean` |
| `chat_call_plan(month, org)` | `org_unit_id, overdue_with_phone_n, week_1, week_2, week_3, week_4` |
| `chat_facility_rank_district(month, org)` | `org_unit_id, org_unit_name, uncontrolled_n, breaches text[], also_check boolean, rank int` |

Measures are always computed, even when `too_few` is true. `too_few` only tells panels and the chat to print the `Too few …` line instead of the percent, and it forces `flag = false` except for the fudging `No 140-144 readings` case, which needs `a + b ≥ 20`. Percent columns are NULL only when the denominator is 0.

`bucket_order`: Step 1 … Step 6 = 1-6, Other Protocol = 7, Non-Protocol = 8, Unrecognized = 9. Labels follow UX A42 (for example `1 medicine, starting dose`, `2 medicines, one at full dose`).

Flag reason sentences (NFR-8, ≤ 20 words), the number filled in by SQL:

| Report | Reason |
| --- | --- |
| adherence | `Many patients are on medicines outside the protocol: 23.5%.` / `Most patients stay on one medicine: 64.0%.` |
| titration | `Medicine rarely stepped up: 29.5% of 200 high BP visits.` |
| fudging | `Readings may be rounded down: 5.42 just under 140 for every 1 just over.` / `No 140-144 readings. Check how BP is recorded.` |
| statins | `Few eligible patients are on a statin: 21.0%.` |
| calling | `Few overdue patients are called: 4.0%.` / `Most calls are late: 32.0% within 14 days.` |
| new_patients | `Few new patients have a usable phone number: 44.0%.` |

## 2. `report_flag_thresholds` seed

| report | key | value | Source |
| --- | --- | --- | --- |
| common | high_control_pct | 60 | A36 |
| adherence | min_cohort | 20 | A37 |
| adherence | off_protocol_pct | 20 | A38 |
| adherence | one_medicine_pct | 60 | A38 |
| titration | min_visits | 10 | A37 |
| titration | flag_below_pct | 40 | A19, A38 |
| titration | next_visit_days | 30 | A19 |
| titration | too_recent_days | 30 | A19 |
| fudging | min_readings | 20 | A20, A37 |
| fudging | flag_score | 2.0 | A5, A38 |
| statins | min_eligible | 10 | A37 |
| statins | flag_below_pct | 25 | A38 |
| statins | min_age | 40 | A4 |
| calling | min_overdue_phone | 10 | A37 |
| calling | overdue_days | 45 | overdue list |
| calling | called_below_pct | 10 | A38 |
| calling | early_days | 14 | A21 |
| calling | early_below_pct | 50 | A38 |
| calling | return_days | 30 | A21 |
| new_patients | phone_below_pct | 50 | A38 |
| chat | new_loss_above_pct | 25 | A57 |
| chat | usable_phone_below_pct | 90 | A57 |
| chat | called_below_pct | 10 | A57 |
| chat | early_below_pct | 50 | A57 |
| chat | titration_below_pct | 40 | A57 |
| chat | stock_days_below | 30 | A57 |
| chattogram | control_below_pct | 50 | FR-47 |
| chattogram | uncontrolled_above_pct | 20 | FR-47 |
| chattogram | missed_visit_above_pct | 25 | FR-47 |
| chattogram | ltfu_above_pct | 20 | FR-47 |

## 3. `parse_obat` grammar and cases

Split the cell with `regexp_split_to_table(obat_raw, '\s*(;|\||\n)\s*')`, drop empty pieces, and number the rest from 1. Match each piece case-insensitively against:

```text
^\s*([a-z][a-z .-]*?)\s+([0-9]+(?:[.,][0-9]+)?)\s*mg\s*-\s*([0-9]+)\s*x\s*([0-9]+(?:[.,][0-9]+)?|½|1/2)\s*(?:tablet|tab|kaplet|kapsul|capsule)?\s*(?:sehari)?\s*$
```

Comma decimals become dots; `½` and `1/2` become 0.5. The name resolves through `lower(trim(name)) = ANY(medicines.aliases)`. If it matches nothing, the status is `unknown_drug` with the numbers kept. If the regex fails, the status is `unparsed` with all fields NULL except `raw_line`.

| Input | Lines (drug, strength, doses, tablets, daily, status) |
| --- | --- |
| `Lisinopril 10 mg - 1 x 2 Tablet Sehari` | Lisinopril, 10, 1, 2, 20, ok |
| `Amlodipine 5 mg - 1 x 1 Tablet Sehari; Hydrochlorothiazide 12,5 mg - 1 x 1 Tablet Sehari` | Amlodipine 5/1/1/5 ok; Hydrochlorothiazide 12.5/1/1/12.5 ok |
| `amlodipin 10 mg - 1 x 1 tab` | Amlodipine, 10, 1, 1, 10, ok (alias) |
| `Captopril 25 mg - 2 x ½ Tablet Sehari` | Captopril, 25, 2, 0.5, 25, ok |
| `Atorvastatin 20 mg - 1 x 1 Tablet Sehari \| Metformin 500 mg - 2 x 1 Tablet Sehari` | Atorvastatin ok (statin); Metformin ok (not_htn) |
| `Xyzapril 10 mg - 1 x 1 Tablet Sehari` | NULL drug, 10, 1, 1, 10, unknown_drug |
| `Obat herbal 2 x sehari` | unparsed |
| empty string | no lines |

## 4. `medicines` seed

Protocol rows (`htn_role = 'protocol'`):

| drug_name | aliases | drug_class | ladder_class | start | full | stock_category |
| --- | --- | --- | --- | --- | --- | --- |
| Amlodipine | amlodipine, amlodipin | CCB | CCB | 5 | 10 | CCB |
| Lisinopril | lisinopril | ACE inhibitor | RAAS | 10 | 20 | NULL |
| Telmisartan | telmisartan | ARB | RAAS | 40 | 80 | ARB |
| Hydrochlorothiazide | hydrochlorothiazide, hctz, hct, hidroklorotiazid | Thiazide | THIAZIDE | 12.5 | 25 | NULL |
| Chlorthalidone | chlorthalidone, chlortalidone, klortalidon | Thiazide-like | THIAZIDE | 12.5 | 25 | Diuretic |

The `drug_name` values must equal the existing `protocol_drugs.drug_name` strings; the medicine-model unit checks this before adding the FK.

Statins (`htn_role = 'not_htn'`, `is_statin = true`, no mg range): Atorvastatin, Simvastatin, Rosuvastatin.

Non-protocol HTN (`htn_role = 'non_protocol'`, start/full mg a day): Losartan 50/100, Valsartan 80/160, Candesartan 8/16, Irbesartan 150/300, Olmesartan 20/40, Captopril 50/150, Enalapril 5/20, Ramipril 2.5/10, Perindopril 4/8, Imidapril 5/10, Nifedipine 30/60, Felodipine 5/10, Lercanidipine 10/20, Nicardipine 60/120, Diltiazem 180/360, Verapamil 120/240, Bisoprolol 5/10, Atenolol 50/100, Metoprolol 50/100, Propranolol 80/160, Carvedilol 12.5/50, Furosemide 20/80, Spironolactone 25/50, Indapamide 1.5/2.5, Clonidine 0.15/0.6, Methyldopa 500/1500, Hydralazine 50/200, Prazosin 2/10, Doxazosin 1/8.

Non-HTN (`htn_role = 'not_htn'`): Metformin, Glimepiride, Glibenclamide, Gliclazide, Glipizide, Acarbose, Pioglitazone, Insulin, Aspirin (aliases `asam asetilsalisilat`, `asetosal`), Clopidogrel, Paracetamol, Ibuprofen, Asam mefenamat, Amoxicillin, Ciprofloxacin, Omeprazole, Lansoprazole, Ranitidine, Antasida, Allopurinol, Cetirizine, Chlorpheniramine (alias `ctm`), Dexamethasone, Prednisone, Ambroxol, Vitamin B complex, Asam folat, Kalsium laktat.

## 5. Ladder labels (`htn_ladder_steps.label`)

| step | label |
| --- | --- |
| 1 | 1 medicine, starting dose |
| 2 | 1 medicine, full dose |
| 3 | 2 medicines, one at full dose |
| 4 | 2 medicines, both at full dose |
| 5 | 3 medicines, third at starting dose |
| 6 | 3 medicines, all at full dose |

## 6. Hand-checked fixtures (one verify script each)

**Drug stock Latest Wins (AD-19).**
- Same cell `(F1, 2026-10-01, 329528)`. Sheet row 3 has `submitted_at 2026-10-05`, value 50; sheet row 4 has `2026-10-02`, value 90. Stored value: 50, with 2 history rows.
- A re-pull of row 4 alone leaves 50.
- Two rows at the same `submitted_at`, rows 5 (60) and 6 (70): stored value 70.

**Patient-Days (AD-22).** CCB coeff 1.4, load 1.0, dose factor 1 for 5 mg and 2 for 10 mg.

| Facility | N | Amlodipine 5 | Amlodipine 10 | Normalized | Patient-Days |
| --- | --- | --- | --- | --- | --- |
| F1 | 100 | 1400 | 0 | 1400 | 10.00 |
| F2 | 200 | 2800 | 1400 | 5600 | 20.00 |
| F3 | 300 | blank | 700 | — | — |

- All row: 7000 / (300 × 1.4) = 16.67, with coverage 2 of 3.
- The old bug gives 8400 / 840 = 10.00, which must not appear.

**Classifier (CR-1).** One encounter per bucket: Step 1 to Step 6 per the ladder tuples, plus:
- `Lisinopril 10 mg` alone → Other Protocol;
- Amlodipine 10 + Lisinopril 20 + Telmisartan 80 → Other Protocol (two RAAS drugs);
- Losartan 50 → Non-Protocol;
- `Obat herbal` → Unrecognized / unreadable;
- no prescription row → Unrecognized / no_prescription;
- Metformin only → Unrecognized / no_htn_medicine.

**Adherence (CR-2).** Month 2026-09 (window 2026-07-03 to 2026-09-30).
- 9 patients, one per bucket, first visit 2026-01-01; Steps 1-3 controlled, the rest not. Bucket counts sum to 9.
- A 10th patient whose first visit is 2026-08-01 appears only when `include_new` is set.

**Titration (CR-3).** Month 2026-09. A filler patient with one visit on 2026-09-30 sets `data_end` to 2026-09-30.

| Patient | Visits (date: bucket, BP) | Counted |
| --- | --- | --- |
| T1 | 06-20: Step 1 130/80; 07-15: Step 1 150/90; 08-05: Step 2 | stepped up at next visit |
| T2 | 06-20: Step 1; 07-20: Step 2 150/95 | stepped up at same visit |
| T3 | 06-20: Step 2; 07-25: Step 2 160/100; 08-30: Step 2 | not stepped up |
| T4 | 07-10: Step 1 155/95 (first visit) | excluded, no baseline |
| T5 | 08-01: Step 1; 09-10: Step 1 150/90 | excluded, too recent (09-10 > 08-31) |
| T6 | 06-20: Metformin only; 07-12: Amlodipine 5 150/90 | stepped up (no HTN medicine → treatment) |

Result: 3 of 4 = 75.0%, with `too_few` true (4 < 10) and `flag` false. T3's 08-30 visit is 36 days later, so it is outside the next-visit bound. A second fixture with 200 eligible visits and 59 stepped up gives 29.5% and is flagged (Kolfe).

**Fudging (CR-4).** Cases (band 135-139, band 140-144):
- (541, 100) → 5.41, flagged; (542, 100) → 5.42 (Kolfe);
- (200, 100) → 2.00, flagged; (199, 100) → 1.99, not flagged;
- (12, 5) → too few; (25, 0) → `No 140-144 readings`, flagged.

**Statins (CR-5).** `window_end` 2026-09-30.
- Age 39 with E11 → not eligible. Age 40 with E11 → eligible.
- Age 55 with an MI on 2025-03-01 and no E11 → eligible.
- Age 60 with E11, dead → not eligible.
- An eligible patient whose earlier prescription had atorvastatin but whose latest has none → not on a statin.

**Overdue calling (CR-6).** Month 2026-09; the fixture's `data_end` is 2026-10-31.
- C1: last visit 2026-07-10, overdue since 08-24. Called 09-02 (9 days, early), `Agreed to visit`, visit 09-20 → returned early.
- C2: last visit 2026-07-01, overdue since 08-15. Called 09-05 (21 days, late), `Call again later`, no visit → not returned.
- C3: last visit 2026-07-05, `Pending to call` on 09-03 → not called.
- C4: last visit 2026-07-20, which is not before 07-18, so not overdue at the start of September.
- C5: last visit 2026-06-01, removed `Moved out of catchment area` on 08-01 → not overdue.
- All five have 10-digit phones. A filler visit on 2026-10-31 is the newest encounter in the database, so both calls have a known return.
- Result: overdue 3 (C1, C2, C3), called 2, called 66.7%, early 50.0%, returned 1 of 2 known, `too_few` true (3 < 10).

## 7. Demo seed plan (AD-34)

The anchor is the newest source encounter (2026-10-13). The reporting month is 2026-10 (window 2026-08-03 to 2026-10-31). Choices come from `md5(id || ':' || salt)`.

| Seed | Adds |
| --- | --- |
| `10_visits.sql` | (1) PHC-C: about 220 new patients without a phone (ids from 900000001), I10, first visit in the new-patient cohort window, BP, under PHC-C's SHCs. (2) Second visits for new patients until loss hits the targets. (3) PHC-E: one extra 135-139 visit after the latest visit for uncontrolled patients, until HTN-tab control is 72-78%. (4) 140-144 readings as non-latest visits of patients whose latest is already uncontrolled, to hit the fudging targets. (5) `patient_cvd_history` MI or STROKE for about 4% of patients aged 40 or older. |
| `20_prescriptions.sql` | One `prescriptions` row per encounter, from a per-patient regimen walk. Start mix: 70% Step 1-2, 12% Step 3-4, 6% Non-Protocol, 4% Other Protocol, 3% unreadable text, 5% no HTN medicine. At each uncontrolled visit, step up at that visit with the facility titration probability. Statin line for eligible patients at the facility statin rate. |
| `30_calls.sql` | Calls for months 2026-05 to 2026-10, at the facility called share of each month's start-of-month overdue-with-phone list. Early calls are drawn more often from patients who really returned (return about 50% early, about 25% later). Outcomes about 50% Agreed, 30% Call again later, 20% removed (PHC-C mostly `Wrong phone number`). No `Died`, no `Pending to call`. |
| `40_drug_stock.sql` | Cohort = the six PHCs. Months 2026-09, 2026-10 and 2026-11, through `drug_stock_pull_apply` with `submitted_by` emails. PHC-B November has two submissions in reverse time order. PHC-F leaves Chlorthalidone 25 blank in October. |

Targets for October 2026, checked by the seed verify step:

| Facility | Control (HTN tab) | Fudging score | Titration | New-patient loss | Usable phone (new) | Called | Early | On statin | CCB Patient-Days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PHC-A | as source (about 60%) | 0.9-1.5 | 42-50% | 24-30% | ≥ 95% | 10-12% | 55-65% | 28-35% | 60-120 |
| PHC-B | as source | 0.9-1.5 | 42-50% | 24-30% | ≥ 95% | 6-9% | 30-45% | 28-35% | < 30 |
| PHC-C | as source | 0.9-1.5 | 42-50% | 24-30% | 40-48% | 4-8% | 30-45% | 28-35% | 60-120 |
| PHC-D | as source | 0.9-1.5 | 42-50% | 36-40% | ≥ 95% | 4-8% | 30-45% | 28-35% | 60-120 |
| PHC-E (Kolfe-like) | 72-78% | 5.2-5.6 | 26-30% | 24-30% | ≥ 95% | 3-5% | 30-45% | 28-35% | 60-120 |
| PHC-F | as source | 0.9-1.5 | 42-50% | 24-30% | ≥ 95% | 8-10% | 40-50% | 20-23% | 60-120; THIAZIDE unknown |
