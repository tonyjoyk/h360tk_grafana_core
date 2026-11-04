---
title: Party mode keepsake - HEARTS360 MVP usability and prototype readiness
date: 2026-11-04
mode: session (one mind voicing every persona), headless
inputs: PRD + addendum, UX DESIGN + EXPERIENCE, ARCHITECTURE-SPINE + CLINICAL-RULES, ASSUMPTIONS.md (A1-A68)
---

# Party: HEARTS360 MVP, two questions before tomorrow's demo

Headless run: no human in the room. Tony's turns are his stated goals, played by the orchestrator. Other files were not edited. Per-party memory and the HTML keepsake were skipped on purpose (they write outside this file). Nothing here is committed.

**Tony's two questions:** (1) How do we make it easier to use? (2) Is this the right approach for a prototype shown tomorrow morning?
**Hard rules (not up for debate):** no change to the Hypertension/Diabetes tabs; no destructive seeds; security fix before any new write.

**In the room**
- 📊 Mary, analyst. Evidence first.
- 📋 John, PM. Asks "why?" until something gives.
- 🎨 Sally, UX. Pitches the scene before the code.
- 🏗️ Winston, architect. Trade-offs, boring tech.
- 💻 Amelia, dev. File paths, AC ids, no fluff.
- 🌍 Tigist, district hypertension program manager, Ethiopia (custom). Opens HEARTS360 once a month on a slow laptop and is not a data person. She has 14 facilities, a Monday, and unreliable wifi. Blunt, polite, short sentences.

---

## Round 1 - Right approach for tomorrow?

- 🎯 **Tony:** Tell me if this is the right prototype. Demo is tomorrow morning.
- 📋 **John:** Straight question. What is the demo trying to prove?
- 🎯 **Tony:** A manager can name the facility to visit, and why, in two minutes.
- 📋 **John:** Then why is there a 14-migration chain, three roles, a new container and an injected widget?
- 🏗️ **Winston:** Because each piece answers a real hole. Read-only roles close the write hole. `h360-api` is the one write path and the chat host. Fixed query library keeps the chat honest. The shape is right. The *size* is the problem: 23 new ADs, 18 build units, six waves.
- 💻 **Amelia:** Number that worries me: three of five reports hang on one thing. Titration, adherence and statins all read `visit_step` and `prescription_lines` (AD-24, AD-25). If `0.6.7_to_0.6.8` is late, three tabs die together. Only fudging and calling stand on their own tables.
- 🌍 **Tigist:** Please tell me what I look at first on Monday. I do not want to learn five reports. I want one name.
- 📊 **Mary:** That is SM-2, and the evidence agrees. Jimma, Addis Ketema: managers act on one clear number. Our own Kolfe numbers are the story: 76% controlled, fudging 5.42, titration 29.5%. One facility, three screens.
- 📋 **John:** So the demo is one story, not five features. Which screens carry it?
- 💻 **Amelia:** Fudging, titration, overdue calling, then the chat. That is the floor. Adherence and statins are extra.
- 🏗️ **Winston:** Agreed. Keep the architecture. Change the build order: classifier first after the security gate, because it is the single point of failure. Fudging and calling can start in parallel, they need no medicine data.
- 🌍 **Tigist:** And if the medicine part fails?
- 💻 **Amelia:** Then we show two reports and the chat, and say so. We do not hand-fake prescriptions.

**Verdict for question 2:** right approach and right shape, too big to promise whole. Promise the floor, build the rest in cut order (see below).

---

## Round 2 - Five tabs on one dashboard

- 🎨 **Sally:** Picture Tigist opening Reports. First thing she sees is a tab called "Protocol adherence". Nine horizontal bars of indigo steps.
- 🌍 **Tigist:** I close it. Nobody on my team says "step 4". I do not know what to do with it.
- 📋 **John:** Why is it first?
- 📊 **Mary:** FR-31 lists it first and the build order follows. No usability reason.
- 🎨 **Sally:** I do not want to fight over tab order. Put the answer above the tabs. A thin "Needs a look" strip: up to three facilities, each with chips naming the reports that flagged it. Same data as "Also flagged on", no new rule.
- 🏗️ **Winston:** `report_flags` already has to exist for the links. The strip is one Business Text panel in `_shell.json`, in its own row above the tabs.
- 💻 **Amelia:** Risk: `report_flags` is in the *last* migration (`0.6.13_to_0.6.14`). If a report is cut it must not break. Cut reports stay as stub functions that return zero rows.
- 🌍 **Tigist:** Tab names. "Titration". "Fudging". These are not my words. And "fudging" in front of my facility staff, no.
- 🎨 **Sally:** The Voice rules already say "stepped up" and "rounded down". The tab bar broke our own rules. Rename visible tabs, keep internal names. `Right medicines`, `Stepping up`, `BP readings check`, `Statins`, `Overdue calls`.
- 🏗️ **Winston:** AD-29 slugs follow the tab titles, so they change too. Deep links get built from one table in the builder, nothing else moves.
- 🌍 **Tigist:** Two date things on top: Reporting Month and the Grafana time picker. Which one is real?
- 🎨 **Sally:** Reporting Month. The time picker only sets trend reach.
- 💻 **Amelia:** And there is no trend function. Titration and Statins draw "by month" lines (DESIGN tabs 2 and 4), but `report_titration(month, org)` returns one month. The architecture has nothing behind those charts.
- 📋 **John:** Cut the lines. What does the manager need?
- 🎨 **Sally:** Which facility is under 40%. Bars by facility with a dashed line at 40% (statins: 25%). Better chart for her question anyway.
- 🌍 **Tigist:** Then hide the time picker. One less thing to explain.
- 📋 **John:** And the table column "Flag and reason"? Flag is our word.
- 🌍 **Tigist:** "Why look here."

---

## Round 3 - The Kolfe pattern

- 📊 **Mary:** Treasure found. Kolfe-like PHC-E: control 72-78%, fudging 5.2-5.6, titration 26-30% (seed plan). The two-sided rule exists so a green facility is not waved through.
- 🎨 **Sally:** The design does it well: flagged rows sort first, the green number stays green, orange bar, a `◆ Looks fine, check readings` pill. Neutral, no red.
- 💻 **Amelia:** Two gaps. First: DESIGN says the pill appears on BP fudging *and* Titration, with the same text. On Titration "check readings" is wrong: the thing to check is medicines. Second: `report_titration` has no `control_pct` and no `looks_fine_check` column (CLINICAL-RULES §1). Only `report_fudging` has them. The Titration table has nowhere to get the green number.
- 🏗️ **Winston:** Add both columns to `report_titration`, reuse `chat_control_summary` for the formula so tabs and chat agree (AD-31).
- 📋 **John:** Should every flag get the pill? A36 says "any flag".
- 📊 **Mary:** No. The evidence rule is about fudging and titration. AD-31's Also-check uses only those two. Pill only there.
- 🌍 **Tigist:** Now the words. "Readings may be rounded down." If I read this to a nurse she hears "you cheated". The note underneath says it does not prove it. She will not read the note.
- 🎨 **Sally:** Describe what we see, not what someone did. `Readings bunch under 140`. Reason: `5.42 readings just under 140 for every 1 just over. Check how BP is measured.` The note can say cuff, habit, training or rounding.
- 🌍 **Tigist:** Yes. "Check how BP is measured" I can say in a clinic. And "score" is a number I will not understand. "Bunching score."
- 📊 **Mary:** Titration too: "Medicine rarely stepped up" is about prescribers, but it is facility level and the reason carries the number. Keep it. One more evidence point: low titration may be low stock. PHC-B has low CCB stock on purpose. The chat already adds "Fix stock first." Good.
- 💻 **Amelia:** Safety net: extend the banned-word test (FR-48) to every user-visible string in the dashboards and `h360_api`: no "fudg", no "will", "guarantee".
- 🏗️ **Winston:** Tripwire for the demo: seed verify prints which facilities carry the pill. Exactly one, PHC-E. Others sit near 60% control and must not flip.

---

## Round 4 - The chat widget

- 🎨 **Sally:** Pill bottom right, chips, never a blank box. I love it. Now the Kolfe moment: Vikram opens chat at PHC-E and taps "Why is my BP control low?"
- 🏗️ **Winston:** The ranker triggers on loss, phone, calling, titration. PHC-E has 76% control. The title reads "Why is BP control low at PHC-E? (76% controlled)".
- 🌍 **Tigist:** That is silly. Control is not low. I stop trusting it.
- 📊 **Mary:** And the real finding sits in "Also check", at the bottom. For a facility, "Also check" names *some other place* in scope. At facility scope there is none.
- 📋 **John:** So fix the answer. Control 60% or more: title becomes "What to check at PHC-E? 76% controlled, looks fine." Flagged two-sided reports come first as reasons, max two, then one triggered lever. At facility scope the "Also check" is about the facility itself.
- 💻 **Amelia:** Implementable in `ranker.py`: `if control >= common.high_control_pct`, take `report_flags` rows for the place of type fudging/titration first. Same facts JSON, same numbers.
- 🌍 **Tigist:** The last line. "These actions explain only 2% to 12% of why one facility does better than another." My reaction: so the chat is almost useless?
- 📊 **Mary:** It is the evidence ceiling and it is the owner's wording. The second sentence says use them as next steps.
- 🎨 **Sally:** Do not reword the owner's line in the dark. Two cheaper fixes: show it once per thread (answer plus plan card is currently twice), keep it small and last. The API still returns it every time, the test stays.
- 📋 **John:** Park a question for Tony: reword for non-data readers? Not tonight.
- 🌍 **Tigist:** Offline badge. "Offline answers" sounds like broken. My wifi is offline half the day. For me offline is the good news.
- 🎨 **Sally:** Offline is the product, Claude is the extra. Badge `Written from your reports`; the other `Claude wording`. Demo with no key (venue wifi).
- 💻 **Amelia:** Chips: only show those whose registry entry is live. Floor of three at facility scope. If statins is cut, `statin_gap` vanishes, no dead chip.
- 🎨 **Sally:** One more scene. Pill sits where the pager is. If it covers the last row of the Overdue list, Meera cannot page.
- 🏗️ **Winston:** Widget adds 72px of bottom scroll padding to the page container so the end of any page clears the pill. If the selector breaks on Grafana 13, fall back to a 48px icon-only pill.
- 🌍 **Tigist:** I also open it at national level. First chat shows one chip, "Pick a district". Boring.
- 📋 **John:** That is by design (A25). For the demo, `demo_up.sh` prints links that already carry the district or facility.

---

## Round 5 - Does the security fix complicate the demo?

- 🏗️ **Winston:** Not the story, the plumbing. Extra container on :8090, a one-shot `db-grants` that must finish before `postgres-grafana` works, CORS allowing only `localhost:3000`.
- 💻 **Amelia:** Failure modes I can name. (1) `db-grants` not done: every dashboard that gates on `isAllowed` shows the no-access banner or errors, HTN/DM tabs included. (2) Demo opened via a LAN IP or `127.0.0.1`: Origin not allowed, chat and Overdue save fail. (3) Read-only role breaks one HTN/DM panel query nobody tested.
- 📋 **John:** What is the minimum that closes the hole?
- 🏗️ **Winston:** Read-only datasources. That alone stops Viewer writes (FR-24). `h360-api` only restores saving. Split the gate: **G1a** roles plus datasource flip plus `verify_dashboard_queries.py` green on every provisioned panel. **G1b** `h360-api` write path plus `verify_security.sh`.
- 💻 **Amelia:** If G1b slips, the Overdue quick panel goes read-only with one line "Saving is switched off in this build." Hole closed, no new write. Overdue tab changes only its save path, so A15 holds.
- 📋 **John:** Does the owner's rule "security before any new write" still hold?
- 🏗️ **Winston:** Yes: no write endpoint exists until G1b passes. NFR-3's stricter "nothing merges before G1" stays as the merge gate.
- 🌍 **Tigist:** In the demo I only care that I click "Agreed to visit" and see "Saved".
- 🎨 **Sally:** So do not show security live. Show it as a pasted `verify_security.sh` PASS in the backup deck. Live: one save.

---

## Round 6 - If time runs short

- 📋 **John:** Tony's rule: three working reports plus a usable chat beat five broken ones. What goes first?
- 💻 **Amelia:** Anything that is not on the Kolfe path and not shared plumbing. Claude mode, then the statins patient list, statins tab, adherence toggle, extra chips, histogram.
- 📊 **Mary:** Adherence is the owner's namesake tool. Do not cut it early out of habit.
- 📋 **John:** Does it carry the demo story?
- 📊 **Mary:** No.
- 🏗️ **Winston:** And a cut costs little by design: one source file per tab (AD-28) and a stub function. Cutting is deleting a line from the builder's tab list.
- 🌍 **Tigist:** If the strip fails to build?
- 🎨 **Sally:** Start on `BP readings check`, the Kolfe tab.
- 💻 **Amelia:** Never cut: G1a, HTN/DM diff empty, `demo_up.sh` twice with equal row counts, fudging, titration, calling, chat with three chips, the honesty line.

---

## Round 7 - Demo morning

- 💻 **Amelia:** Grafana is `latest` and unpinned (A8). Rebuild on venue wifi and the injection check (AD-33) may fail, or the page may differ. After the last green `verify_all.sh`: no pull, no build. Demo from the local images.
- 🏗️ **Winston:** The default month: "latest completed" is October only while the clock says November. Data ends 2026-10-13. Pin the default to `2026-10-01` in the committed JSON, revert after.
- 📊 **Mary:** Honesty cost. The seeds add 220 new PHC-C patients and extra visits at PHC-E. The HTN/DM tab definitions stay byte-identical but their numbers move. Tell Tony before he compares screenshots.
- 🎨 **Sally:** And a line on the Reports page: "Demo data. Facility names and numbers are made up." Tigist will otherwise believe PHC-E.
- 🌍 **Tigist:** One more. Your "Came back" on Overdue calling shows one number. The Overdue tab shows a smaller one for the same patients. I will ask which is true.
- 📊 **Mary:** 30 days versus 15 days (CR-6). Label it: `Came back within 30 days`, muted line `The Overdue tab counts 15 days.`
- 📋 **John:** Run order for the demo: Needs a look strip, BP readings check row, Stepping up, chat at PHC-E, plan card, open the overdue list, save one status. Six minutes.
- 💻 **Amelia:** Record that run as a backup video. Rehearse once with someone who did not build it, ideally Tigist's role.
- 🌍 **Tigist:** Make the slow laptop test real. 1366x768, 125% zoom. And please check hidden tabs do not run queries.

---

## Deferred, not decided tonight

- Month-over-month change (Tigist's monthly question "what moved since last time?"). Needs a trend function.
- Print or screenshot-friendly layout for plan card and tables.
- Reword honesty line for non-data readers (owner question).
- Row-level read security and `first_appointment_gap` lever (already deferred in the spine).

---

## Decisions for the build

Tags name the doc, AD or FR the change amends.

1. **Split gate G1** [AD-18, AD-14, FR-24..27, NFR-3]. G1a: read-only roles, datasource flip, `db-grants`, `verify_dashboard_queries.py` green on every provisioned panel including HTN/DM. G1b: `h360-api` `/write/call-result`, Overdue quick-panel save, `verify_security.sh`. No report or chat unit merges before G1a. If G1b is not green at its gate, ship `panel-ov-quick` read-only with the note `Saving is switched off in this build.`
2. **Stub rule for cut reports** [AD-27, AD-28, AD-13]. A cut `report_*` keeps its signature and returns zero rows. `report_flags` and the chat registry tolerate it. `build_reports_dashboard.py` reads a `TABS` list, so cutting a tab is one line.
3. **Build order** [Addendum §1, AD-13 wave table]. After G1a: medicine model and classifier (`0.6.7_to_0.6.8`) first. Fudging and calling start in parallel (no medicine data needed). Then titration, adherence, statins last. If the medicine model is not green at its gate, ship fudging, calling and the chat only, and say so. No hand-faked prescriptions.
4. **Visible tab names and links** [FR-31, AD-29, EXPERIENCE IA]. Tabs: `Right medicines`, `Stepping up`, `BP readings check`, `Statins`, `Overdue calls`. Slugs: `Right-medicines`, `Stepping-up`, `BP-readings-check`, `Statins`, `Overdue-calls`. Internal names (`report_fudging`, FR-37/38, `panel-fudging-*`) stay. Table column `Flag and reason` becomes `Why look here`.
5. **Neutral BP wording** [FR-37, FR-38, DESIGN tab 3, CLINICAL-RULES §1 reasons, EXPERIENCE Voice]. Metric `Bunching score`. Flag `Readings bunch under 140`. Reason `{x.xx} readings just under 140 for every 1 just over. Check how BP is measured.` Zero case `No 140-144 readings. Check how BP is measured.` Note lists cuff, habit, training or rounding as possible causes. The FR-48 banned-word test runs over all user-visible dashboard and `h360_api` strings and adds `fudg`.
6. **Two-sided pill only on two tabs** [A36, FR-36, FR-38, DESIGN Kolfe pattern]. Pill on `BP readings check` reads `◆ Looks fine, check readings`; on `Stepping up` reads `◆ Looks fine, check medicines`. `report_titration` gains `control_pct` and `looks_fine_check` (CLINICAL-RULES §1; formula from `chat_control_summary`). Each pill links `Also flagged on …` to the other tab with the same location.
7. **Needs-a-look strip** [FR-31, AD-28 `_shell.json`, DESIGN shell, A35]. A row above the tabs: up to three facilities from `report_flags`, facilities flagged on two or more reports first, then by patients; each with report chips linking to the tab. Empty state `No facility is flagged.`
8. **No trend lines, no time picker** [A34, DESIGN shell and tabs 2 and 4, AD-28]. Hide the Grafana time picker on Reports. Titration chart: bars by facility with a dashed 40% line. Statins chart: bars by facility with a dashed 25% line. Month-over-month deferred.
9. **Pin the demo month** [A34, AD-28 variables, Spine Deferred "Report window drift"]. Default `reporting_month` = `2026-10-01` in the committed JSON. `demo_up.sh` prints the month it expects.
10. **Return wording** [FR-42, CR-6, DESIGN tab 5]. Strip label `Came back within 30 days`, muted line `The Overdue tab counts 15 days.` Same text in the tab note.
11. **Chat answer for a high-control place** [FR-47, AD-31, EXPERIENCE chip table]. If `control_pct >= common.high_control_pct` (60), the title is `What to check at {place}? {x}% controlled, looks fine.` Reasons: flagged fudging or titration rows for the place first (max two), then triggered levers up to three in total. At facility scope `Also check` describes this facility. Same facts JSON; numbers unchanged.
12. **Registry-driven chips** [FR-43, AD-30 `/chat/chips`, A41]. `GET /chat/chips` returns only chips whose registry function is live (not a stub). Facility floor of three: `why_control_low`, `who_to_call`, plus `readings_reliable` or `medicines_adjusted`.
13. **Honesty line shown once** [FR-48, A47, AD-30 widget contract]. Text stays verbatim and is always returned by the API. The widget draws it once at the foot of a thread, after the plan card.
14. **Offline is the default product** [FR-49, A7, DESIGN chat header]. Badges `Written from your reports` and `Claude wording`. `.env.example` ships `ANTHROPIC_API_KEY` blank. The demo machine sets none.
15. **Widget clearance** [FR-43, AD-33, DESIGN chat]. Add 72px bottom scroll padding to the page container. If the selector fails, fall back to a 48px icon-only pill. Check the Overdue pager and a Reports table pager at 1366x768 and 125% zoom.
16. **`demo_up.sh` hardening** [FR-18, AD-34, AD-14 `db-grants`, AD-16 CORS]. Wait for `db-grants` exit 0 and `h360-api` `/healthz` before printing URLs. Default `H360_ALLOWED_ORIGINS` includes `http://localhost:3000` and `http://127.0.0.1:3000`. Print three deep links: Reports at the district with month pinned; PHC-E with chat; the Overdue tab as `nurse.phc-a`.
17. **Insert-only seed guard** [AD-34, A13, A55, NFR-2]. `scripts/verify_seeds_insert_only.sh` fails if any seed contains `UPDATE`, `DELETE` or `TRUNCATE`. `verify_all.sh` runs it and runs `demo_up.sh` twice comparing row counts of `patients`, `encounters`, `prescriptions`, `call_results`. The seed verify prints which facilities carry the `Looks fine` pill: exactly PHC-E.
18. **Performance on a slow machine** [NFR-6, AD-35]. `verify_dashboard_queries.py` prints per-panel timing and fails over 2 s on demo data. Confirm hidden tabs fire no queries. If a tab runs the same `report_*` call in four or more panels and is slow, share one query with the Dashboard datasource. Manual check at 1366x768, 4x CPU throttle.
19. **Demo-data notice** [FR-31, DESIGN shell]. Reports subtitle: `Demo data. Facility names and numbers are made up.`
20. **Image freeze** [A8, SM-1]. After the final green `verify_all.sh`: no `docker pull`, no build. Save `docker images --digests` to `docs/reports/demo-runbook.md` with the run order (strip, BP readings check, Stepping up, chat at PHC-E, plan card, Overdue save) and the rule to open only `http://localhost:3000`.
21. **HTN/DM guard stated precisely** [NFR-1, A15, FR-17]. `check_htn_dm_untouched.py` compares tab definitions only. Seed-driven number changes (new PHC-C patients, extra PHC-E visits) are expected; the runbook tells the owner.
22. **Rehearsal and backup** [SM-1, SM-2, UJ-3..5]. One clean-volume run (`down -v`, `demo_up.sh`), one pass by someone who did not build it, one recorded screen video of the run order. Verify scripts exist only for shipped reports; a cut report's verify leaves `verify_all.sh` with it [NFR-9].

## Cut order if short on time

Cut from the top. Stop cutting when the floor is safe.

1. Claude mode (`wording.py` HTTP call). Offline only.
2. Statins patient list (`report_statins_patients`, `Patients to review` row).
3. Statins tab (stub; drop `statin_gap` chip).
4. Adherence `Patients counted` toggle (strict only).
5. Chips beyond the floor of three (`medicines_adjusted`, then `readings_reliable` if fudging verified separately).
6. Fudging histogram becomes two bars (A39 fallback).
7. Needs-a-look strip. Start on `BP readings check` instead.
8. Adherence tab (stub; classifier stays, titration needs it).
9. District chip `visit_first` and `facility_rank_district` (district falls back to facility chips).
10. `h360-api` write path (G1b): Overdue quick panel read-only with the note (decision 1). G1a never moves.

**Floor (do not cut):** G1a; HTN/DM diff empty; `demo_up.sh` idempotent; `BP readings check`, `Stepping up`, `Overdue calls`; chat with three chips, plan card, honesty line. If the medicine model fails, the floor is `BP readings check`, `Overdue calls` and a chat with `why_control_low` and `who_to_call`, announced as such.

## New assumptions

| id | topic | decision | why | revert |
| --- | --- | --- | --- | --- |
| A69 | Demo floor and stubs | Floor is BP readings check, Stepping up, Overdue calls, chat. Cut reports stay as zero-row stub functions and leave the builder's `TABS` list. | Three working reports plus a usable chat beat five broken ones. Stubs keep `report_flags` and the chat from failing. | Restore the tab file and function body. |
| A70 | Security gate split | G1a (read-only roles and datasources) then G1b (`h360-api` write). If G1b slips, the Overdue quick panel is read-only with a note. | G1a alone closes the hole. Disabling save adds no write. | Remove the note and enable the save once `verify_security.sh` passes. |
| A71 | Visible tab names | `Right medicines`, `Stepping up`, `BP readings check`, `Statins`, `Overdue calls`; slugs follow (AD-29). Internal names unchanged. | The Voice rules ban jargon and the tab bar broke them. | Edit the title table in `build_reports_dashboard.py`. |
| A72 | Neutral BP wording | `Bunching score`; flag `Readings bunch under 140`; no user-visible "fudg" anywhere. | Describes what is seen, not what staff did. | Edit the reason strings and the banned-word list. |
| A73 | Two-sided pill scope | Only BP readings check and Stepping up, with tab-specific text. Replaces A36's "any flag". | Matches AD-31 Also-check and the evidence rule. | Widen the pill to all flags in the table JS. |
| A74 | Needs-a-look strip | Row above the tabs, max three facilities, from `report_flags`. | Landing tab should not decide whether the manager finds the answer. | Remove the row from `_shell.json`. |
| A75 | No trend lines | Time picker hidden on Reports. Titration and Statins charts are facility bars with a flag line. | No trend function exists. A bar by facility answers "which facility". | Add `report_*_trend` functions and the line charts. |
| A76 | Pinned month | Default `reporting_month` is `2026-10-01` for the demo. | Data ends 2026-10-13. A late clock would move the default past it. | Set default to the latest completed month. |
| A77 | Return label | `Came back within 30 days`, with a line that the Overdue tab counts 15 days. | Two "returned" numbers on two tabs confuse non-data readers. | Edit the strip text. |
| A78 | Chat for high control | At 60% control or more, flagged fudging and titration rows lead the answer; the title reads "What to check". | "Why is control low" at 76% loses trust and hides the Kolfe finding. | Remove the branch in `ranker.py`. |
| A79 | Honesty line display | Verbatim and returned every time. The widget shows it once per thread. Whether to reword for non-data readers is an owner question. | The wording is the owner's. A double print adds noise. | Draw it on every card. |
| A80 | Badge names | `Written from your reports` for offline, `Claude wording` for Claude. The demo runs with no key. | Offline is the normal case for a slow or absent connection, not a fault. | Rename the badges in the widget. |
| A81 | Registry-driven chips | Only chips whose function is live are shown; floor of three at facility scope. | No dead chips after a cut. | Hard-code the chip list again. |
| A82 | Widget clearance | 72px bottom scroll padding, or a 48px icon-only pill if the selector fails. | The pill may cover pagers. | Remove the padding rule. |
| A83 | Frozen images and origins | No pull or build after the last green `verify_all.sh`. Open only via `localhost:3000`. CORS allows `localhost` and `127.0.0.1`. | Unpinned Grafana and venue wifi are the main demo risks. | Pin the Grafana image after the demo (A8). |
| A84 | Seeds move HTN/DM numbers | Tab definitions stay identical. Fake patients and visits added by seeds change the numbers shown. | The owner's rule is about the tabs, not about data. | Remove seeds `10_visits.sql` (rare). |
| A85 | Demo-data notice | Reports shows `Demo data. Facility names and numbers are made up.` | Fake names like PHC-E can be read as real. | Remove the line before a pilot. |
