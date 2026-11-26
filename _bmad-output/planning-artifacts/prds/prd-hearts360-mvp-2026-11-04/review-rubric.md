# PRD Quality Review - HEARTS360 MVP

Walked sequentially by the author-run rubric pass (no subagent tool was available in this headless session). Stakes: internal tool, demo prototype.

## Overall verdict
The PRD is decision-ready for an internal prototype. It states the thesis (name the facility to visit and why within two minutes), ties each report to a decision and a plain-words rule, and records tradeoffs with their cost. The main risk is that most clinical numbers (ladder, 40%, 14 days, 20 readings) are rebuilt assumptions, which the PRD flags openly and isolates in data tables.

## Decision-readiness - strong
Tradeoffs are a table with cost and revisit trigger (section 7). The read-versus-write security tension is called out with a `[NOTE FOR PM]` (after FR-27) instead of being smoothed over. Open questions are real (ladder source, statin source, external Claude call on real data).

### Findings
- **low** Open question 3 asks whether program wants the 40% and 14-day lines, but SM-2 does not test thresholds (section 9, SM-2) - *Fix:* none for the demo; collect reactions as notes (SM-7 already does).

## Substance over theater - strong
One role, four short journeys, no persona furniture. NFRs carry numbers (5 s, 3 s, 20 words, 2.0, 40%). Vision names a concrete test. No innovation theater.

### Findings
- **low** UJ-6 is an owner journey, closer to a test scenario than a user story (section 2.3) - *Fix:* keep; it carries the idempotency and unchanged-tabs checks.

## Strategic coherence - strong
Order follows the owner's goals: merge, fix, secure, data, reports, chat last because it reads the reports. The two-sided prioritization rule threads through FR-38, FR-47 and the planted demo facility. Counter-metrics are named for chips, wording confidence and flag tuning.

### Findings
- **medium** SM-2 uses three people "or the owner standing in", which weakens the claim (section 8) - *Fix:* record in the demo notes whether real people took part.

## Done-ness clarity - adequate
Every FR has a testable consequence. Rules with edge cases (fudging guards, titration exclusions, statin age boundary) name fixtures.

### Findings
- **medium** FR-47 ranking is testable only by example; the PRD lacks a worked case with numbers (FR-47) - *Fix:* architecture should add one golden district and one golden facility fixture, using the addendum template.
- **medium** FR-30 "realistic" is defined by planted traits and ranges (addendum section 7), not a measurable realism test - *Fix:* accept; the verify script prints the planted numbers.
- **low** FR-43 chip counts and FR-45 word cap are untested taste choices; both are tagged `[ASSUMPTION]`.

## Scope honesty - strong
Non-goals are specific. Every inference carries an `[ASSUMPTION Axx]` tag and the index lists A18 to A33. Deferred items are named. Open-items density (5 questions, 16 new assumptions) is high but the stakes are a demo, and the PRD says which assumptions to replace first.

### Findings
- **low** The 16 new assumptions all need owner review at once (section 9) - *Fix:* none; the order to review is ladder (A18), titration (A19), read scoping (A24).

## Downstream usability - strong
Glossary is used consistently. FR ids run FR-15 to FR-49 with no gaps and continue the drug stock PRD, so they do not clash. Each UJ has a named protagonist. The addendum gives query library, tables and fake-data spec for architecture.

## Shape fit - adequate
Capability-spec shape suits an internal tool, but four UJs for one operator role is slightly over-formal; justified by the chat and security stories.

## Mechanical notes
- IDs: FR-15 to FR-49 contiguous; UJ-3 to UJ-6; SM-1 to SM-7 and SM-C1 to SM-C3; NFR-1 to NFR-9. No dangling references found.
- Assumptions index round-trip: A18 to A33 each appear inline at least once and in section 9.
- Glossary: "Controlled", "Window", "Early Call", "Report Tab" used verbatim. "Viewer" is capitalised as a Glossary term in security text.
- The addendum references FR ids that exist. The whitelist in addendum section 2 had a duplicate (captopril); fixed.
