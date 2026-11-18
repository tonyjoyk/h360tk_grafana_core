# Addendum: HEARTS360 MVP (not PRD body)

Technical detail for architecture, UX and epics. Capabilities live in `prd.md`. Everything marked rebuilt comes from the context file, not from the unreachable private repos (A2, A3, A10), and is meant to be swapped for the real files.

## 1. Build order (hard constraints first)

1. Merge: base `demo/cascade-cohort` (0.6.0), merge `feature/drug-stock-mvp`, renumber migrations (FR-15 to FR-18). Stop point for review: the merge is its own commits (A11).
2. Drug stock fixes (FR-19 to FR-23).
3. Security fix (FR-24 to FR-27). Nothing below ships before this passes (NFR-3).
4. Medicine tables, classifier, fake data (FR-28 to FR-30).
5. Reports dashboard, five tabs (FR-31 to FR-42). Order by dependency: adherence, titration, statins, fudging, overdue calling.
6. Chat (FR-43 to FR-49). It reads the report views, so it comes last.

## 2. Protocol ladder (rebuilt, A18)

Daily dose = strength x tablets per dose x doses per day. Starting and full dose per drug:

| Drug | Starting (mg/day) | Full (mg/day) |
|---|---|---|
| Lisinopril | 10 | 20 or more |
| Amlodipine | 5 | 10 or more |
| Hydrochlorothiazide | 12.5 | 25 or more |

| Step | Rule |
|---|---|
| 1 | One protocol drug, below full dose |
| 2 | One protocol drug at full dose |
| 3 | Two protocol drugs, both below full dose |
| 4 | Two protocol drugs, at least one at full dose |
| 5 | Three protocol drugs, not all at full dose |
| 6 | Three protocol drugs, all at full dose |
| Other Protocol | Only protocol drugs, but no step fits (for example a dose off the table, or two lines of the same drug) |
| Non-Protocol | Any whitelisted HTN drug outside the three. The whitelist is about 70 drugs in the Excel tool; MVP seeds a short list (captopril, enalapril, ramipril, losartan, valsartan, telmisartan, candesartan, nifedipine, felodipine, diltiazem, verapamil, furosemide, spironolactone, indapamide, atenolol, bisoprolol, metoprolol, propranolol, carvedilol, clonidine, methyldopa, doxazosin) |
| Unrecognized | An Obat entry that does not parse |

The ladder, the whitelist and the tiers are data tables, not code, so the Excel tool's own file can replace them.

Titration "step up" order: Step 1 < 2 < ... < 6. Other Protocol and Non-Protocol use total daily dose across lines as the tiebreaker. A move from Unrecognized to a classified step is not counted as a step up.

## 3. Medicine tables (sketch, FR-28)

- `medicines(drug_name, class, is_protocol, is_statin, start_mg_day, full_mg_day)`: the catalog and the whitelist.
- `prescriptions(encounter_id, obat_raw)`: the cell as received.
- `prescription_lines(encounter_id, line_no, drug_name, strength_mg, doses_per_day, tablets_per_dose, daily_mg, parse_status)`.
- `patient_cvd_history(patient_id, event_type, event_date)`.
- Obat grammar: `<Drug> <N> mg - <tablets> x <doses> Tablet Sehari`. Split cells on `;`, `|`, newline. Dates in the source tool come as `01/06/2026` or `2026-06-01`; the toolkit already has encounter dates, so only the cell is stored.
- Functions: `parse_obat(text)`, `classify_visit_step(encounter_id)`. Views feed the five tabs and the chat.
- Dashboards read through the read-only role. Loaders run as the owner role from the shell.

## 4. Query library for the chat (FR-44)

Fixed, named, parameterised by `org_unit` and reference month. All read views also used by the report tabs.

| Name | Returns | Used for |
|---|---|---|
| `control_summary` | control %, uncontrolled %, missed visit %, LTFU % | needs-attention thresholds |
| `new_patient_return` | new patients, share with no second visit in 90 days | evidence tier 1 |
| `phone_capture` | share of active patients with a phone | tier 2 |
| `first_appointment_gap` | share with first appointment more than 70 days out | tier 2 |
| `overdue_calling` | overdue with phone, called %, Early Call % | tier 3 |
| `titration_rate` | Titration Rate, uncontrolled visits | tier 4 |
| `fudging_score` | score, both counts | two-sided "Also check" |
| `statin_gap` | eligible, on statin | chip "who needs a statin" |
| `drug_stock_gate` | lowest Patient-Days for the protocol set | stock gating |
| `facility_rank_district` | facilities by uncontrolled patients, with flags | district scope |
| `call_plan` | overdue with phone, 4-week split | plan nudge |

## 5. Chat answer template (Offline Mode, FR-45 to FR-48)

```
Why is BP control low at {place}? ({control}% controlled in {month})

1. {n}% of new patients did not come back for a second visit.
   What to do: Create a plan to call new patients within a week of registration.
   Next: [How many patients should I call?]
2. {n}% of overdue patients with a phone were called.
   What to do: Call patients within 2 weeks of a missed visit.
   Next: [Who should I call this week?]
Also check: {facility} looks fine ({control}% controlled) but its BP reading score is {x}.
{if stock low} Fix drug stock first: {drug group} has {n} patient-days left.

These actions explain only 2% to 12% of why one facility does better than another.
Treat them as the best next steps, not a promise.
```

Reason pick: from the triggered levers, take the first two or three by tier, then by gap. "Triggered" = the facility's number is worse than the needs-attention line, or worse than the evidence range's typical value (for example 31% to 34% of new patients lost).

Claude Mode prompt contract: system text with the answer shape, the banned words, the honesty line verbatim and the reading level; user text is the JSON of numbers. The model may not add numbers. `h360-api` rejects an answer containing a number not in the input.

## 6. h360-api sketch (A16)

- Python, port 8090, same host as Grafana so the Grafana session cookie reaches it.
- `POST /write/call-result`: validates input, calls `GET {grafana}/api/user` with the cookie, then `SELECT heart360tk_schema.save_call_result(...)`, a `SECURITY DEFINER` function that checks the caller's Team-derived locations.
- `POST /chat`: scope from `org_unit`, picks library entries, builds the numbers JSON, returns the answer plus the mode.
- Roles: `heart360tk` (owner, loaders only), a new read-only role for Grafana dashboards, a restricted role for the service that can only execute the named function and read the library views.
- Widget: script added to Grafana's page shell in the image build (A17); button bottom right; reads `var-org_unit` from the URL (A25).

## 7. Fake data spec (A29 to A32)

Seed fixed. Additive. On the existing 8,000-patient, 6-PHC demo cohort through Oct 2026.

- Prescriptions at each encounter. Mix across the 6 steps weighted to Steps 1 to 3, a few Other and Non-Protocol, about 1% unparseable text.
- Titration planted per facility: most near 45%, one near 27%.
- BP readings: facility baseline with a planted facility where 135-139 is about 5 times 140-144. One facility has few readings so the guard shows.
- Planted "looks fine, check" facility: control 70% or more, fudging score 4 or more, Titration Rate under 30%.
- One facility with a 33% to 40% second-visit loss; one with a low share of phone numbers.
- Statin use about 20% to 35% of eligible, varying by facility. `cvd_history` on a few percent of patients over 40.
- Calls: only 3% to 12% of overdue-with-phone patients called, more late than early, with a higher return after Early Calls.
- Drug stock: submissions with one facility low in CCB so the stock-gate line appears.
- Verify script prints the planted numbers so the demo can be rehearsed.

## 8. Report layout (shared)

Order inside each tab: title naming the decision; two or three headline numbers (Business Text, latest completed month); trend or step bars (ECharts, shared `tip()`); facility table with Flag and reason (Business Text or table already provisioned); "How this is worked out" line. Flags use the existing orange `#ed6300` for needs a look and `#ff3355` only for LTFU-style severe states. Two-sided rows read "Looks fine, check readings" in a neutral tone, not an alarm.

## 9. Rejected or deferred alternatives

| Option | Status and reason |
|---|---|
| Five separate dashboards | Rejected: five trees and five months to keep in step |
| Signed Grafana app plugin for the chat | Deferred (A17): needs build toolchain and signing |
| Free SQL generation by Claude | Rejected: unsafe and unverifiable |
| Chat that writes (for example saving a plan) | Rejected for MVP: would add a write path |
| Keeping the browser write for overdue and "fixing" it with access checks only | Rejected: a direct API call skips browser checks |
| Pinning Grafana now | Deferred (A8) |
| Merging PR 7 or PR 5 | Rejected (A12, A13) |
| NHF's fudging formula | Rejected by owner (A5): drops a decimal |
| Mean-of-rows All row for drug stock | Rejected: reads too low (FR-23) |
| Row-level read security via h360-api reads | Deferred (A24) |

## 10. Evidence base

Context file section 7: Jimma size rule (large facilities hold more uncontrolled patients), the two-sided Addis Ketema rule (Kolfe HC: 76% control, 10% uncontrolled, 14% missed visits, fudging 5.42, titration 29.5%), Chattogram thresholds, cross-country lever table with the 2% to 12% ceiling. The source files were not reachable; this is the only copy (recon). Reconcile when Tony pushes them.
