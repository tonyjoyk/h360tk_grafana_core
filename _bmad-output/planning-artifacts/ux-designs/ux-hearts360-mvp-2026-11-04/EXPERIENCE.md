---
name: HEARTS360 Reports and chat
status: final
sources:
  - {planning_artifacts}/prds/prd-hearts360-mvp-2026-11-04/prd.md
  - {planning_artifacts}/prds/prd-hearts360-mvp-2026-11-04/addendum.md
  - {planning_artifacts}/ux-designs/ux-h360-toolkit-internal-2026-09-27/EXPERIENCE.md
  - docs/demo-screening-cascade.md
  - ASSUMPTIONS.md
created: 2026-11-04
updated: 2026-11-04
---

# HEARTS360 Reports and chat — Experience Spine

> Paired with `DESIGN.md` (tokens, panel sizes, exact copy per tab, chat CSS). Extends the drug stock `EXPERIENCE.md`; its Change location, Reporting Month and `?` / `—` / `0` rules still hold. Spines win on conflict with mocks.

## Foundation

**Form-factor:** Grafana web dashboard on a laptop (1280px wide is the design width) plus a floating chat widget injected into every Grafana page [A17]. The widget also works at phone width, but phones are not a design target.

**UI system:** Grafana 13 with ECharts, Business Text, the tree panel and the existing overdue list pattern. The widget is plain HTML/CSS/JS. Visual identity: `DESIGN.md`. This file holds only the behaviour.

**Users:** Vikram, district program manager, and Meera, facility nurse and manager. Both read BP control every month and are not data people. **Test of success:** Vikram names the facility to visit first, and why, in two minutes (SM-2).

**Product stance:** a rough report they understand beats a complete one that confuses them. When a number cannot be trusted, say so in words and show no number.

## Information Architecture

| Surface | Reached from | Purpose |
|---|---|---|
| HEARTS360 Reports dashboard | Grafana Home, HEARTS360 Dashboards folder, `Reports` link on the program dashboard [A22] | Five tabs, one location, one month |
| Variables bar | Top of Reports | `Reporting Month`, `Patients counted` (adherence only) |
| Change location row | Top of Reports, collapsed | Sets `org_unit` for every tab and for the chat |
| Tab: Protocol adherence | Tab bar | Are patients on the protocol's medicines, and are they controlled? |
| Tab: Titration | Tab bar | Is medicine stepped up when BP is high? |
| Tab: BP fudging | Tab bar | Are readings piling up just under 140? |
| Tab: Statins | Tab bar | Which eligible patients are not on a statin? |
| Tab: Overdue calling | Tab bar | Are overdue patients called early, and do they return? |
| Patients to review list | Statins tab, facility level | Names for follow-up |
| Chat button and panel | Every Grafana page | Chips, ranked answer, plan |
| Overdue list | Program dashboard, Overdue tab (unchanged) | Where calling is done |

Every tab has the same order: question, headline numbers, one chart, `Look at these first`, facility table, `How this is worked out`. Closure: each stated need has a surface (find a flagged facility: table + `Look at these first`; understand why: reason sentence + note; commit to action: chat plan card + overdue list).

**Not surfaces:** a per-patient advice screen, a clinician league table, export on Statins, a diabetes version, chat history, any editor for the thresholds.

## Voice and Tone

Brand posture is in `DESIGN.md`. Write for a district manager who is busy and not a statistician.

**Rules**

1. Short sentences. Aim for 12 words, never more than 20 (NFR-8).
2. Plain words. `stepped up`, not `titrated`; `did not come back`, not `lost to follow-up`; `rounded down`, not `digit preference`.
3. Every number says what it counts: `28% of new patients did not come back`, never `28%` alone. Give `n of N` where space allows.
4. Say what to do in a verb: `Call`, `Visit`, `Check`, `Fix`.
5. Never say `will`, `guarantees`, `proves`, `ensures`. Say `may`, `could`, `is a reason to look`.
6. Only BP, and the glossary terms in the PRD, are allowed as abbreviations. No `LTFU`, `HTN`, `DoS`, `CVD`.
7. A flag always carries a reason sentence a manager can repeat to the facility.
8. Sentence case. No exclamation marks, no emoji, no warning words (`alert`, `danger`, `failing`). Two-sided rows are neutral: `Looks fine, check readings`.

| Do | Don't |
|---|---|
| `Medicine rarely stepped up` | `Low titration rate` |
| `Only 27% of 112 high-BP visits led to a stronger prescription.` | `Titration: 27% (n=112)` |
| `Too few readings` | `0.00` or `N/A` |
| `No data for this place.` | blank panel |
| `Looks fine, check readings` | `Suspected manipulation` |
| `Treat them as the best next steps, not a promise.` | `This will improve control.` |

## Component Patterns

| Component | Behaviour |
|---|---|
| Change location tree | As drug stock: single select, search, empty means all locations the user can access. Collapsed by default here; the title strip always names the place. Changing it reloads every tab and updates the chat scope without reload. |
| Reporting Month | Sets headline month for monthly measures; charts show the running month dashed. Does not clear location. Grafana's time picker only changes how far back trends reach (stated in the panel description). |
| Patients counted | Switches adherence between established patients only and including newer ones; the title strip prints the resulting patient count. |
| Headline strip | Read-only. Hover shows `tip()`-style detail where a chart exists; the big numbers never change on hover. |
| Facility table | Default sort `Needs a look first`. Header click sorts and toggles direction; the sort chip resets. 10 rows per page with the overdue list pager. Facility name is plain text. `Also flagged on …` links open that tab keeping the location. |
| Look at these first | At most three facilities, from the table's top rows. Never a list of ten. |
| Patients to review | Overdue list pattern: chips filter by reason, search by name or Patient ID, 20 rows per page, no export. Facility level only. |
| Chat chips | One click sends the question. A chip is a button, not a link. Disabled while an answer is loading. |
| Nudge button | One click shows the plan card under the answer. It can be clicked once per answer; a second click scrolls to the plan. |
| Report link in an answer | `See this in Reports: <tab>` opens the tab with the same location and month, in the same window. |

### Chat chips (4–6, never a blank box) [A41]

| Scope | Chips, in order |
|---|---|
| Facility | `Why is my BP control low?` · `Who should I call this week?` · `Are medicines being adjusted?` · `Are my BP readings reliable?` · `Who needs a statin?` |
| District | `Why is my BP control low?` · `Which facilities should I visit first?` · then the four facility chips after the first. Six in total. |
| National or empty | Line `Pick a district or a facility to ask a question.` and one chip `Pick a district`. It closes the panel, expands Change location and focuses its search. |

Each chip maps to one library answer (FR-44). A typed question is matched to the nearest chip and answers that one; if nothing matches the reply is `I can only answer the questions above. Pick one.`

| Chip | Answer shape | Nudge |
|---|---|---|
| Why is my BP control low? | 2–3 ranked reasons (evidence order, then gap), `Also check`, stock line, honesty line | `How many patients should I call?` |
| Who should I call this week? | One reason (calling) plus the plan card inline | `Who is overdue longest?` opens the overdue list |
| Are medicines being adjusted? | One reason (stepped-up share) | `Which facilities step up least?` (district) or `Open Titration` |
| Are my BP readings reliable? | One reason (fudging score) or `No sign of rounding down` | `Open BP fudging` |
| Who needs a statin? | One reason (eligible, not on a statin) | `Open the patient list` (facility only) |
| Which facilities should I visit first? | Up to 3 facilities by uncontrolled patients, each with a reason | `Why is control low at {first facility}?` |

## State Patterns

Table states, guards and copy are in `DESIGN.md` States. Behavioural additions:

| State | Treatment |
|---|---|
| Location above facility | Tables list the facilities in view with an `All places in view` first row. |
| Single facility | One row; no peers shown. Title strip says `This facility`. |
| Too few cases | The tab still loads. The number is replaced by the `Too few …` line with the minimum. Never a percent. |
| Facility flagged on two tabs | Each tab's row links to the other (`Also flagged on …`). |
| Chat: loading | Skeleton plus `Looking at your reports…`; chips disabled; `Still working…` at 3 s; error at 10 s. |
| Chat: Claude fails | Falls back to offline wording, badge changes, one explaining line. Numbers unchanged. |
| Chat: no key | `Offline answers` badge, every chip works with no network (FR-49). |
| Chat: no data or too few | One plain sentence instead of reasons. No invented ranking. |
| Chat: signed out | `Your session ended. Reload the page and sign in.` |

## Interaction Primitives

- Click: chips, nudge, links, sort headers, pager, tabs. Keyboard: all of the same via Tab, Enter and Space; `Esc` closes the chat.
- Chat opens bottom right and never covers the Grafana right toolbar. It does not shift or resize the dashboard.
- Chat open/closed state is remembered while moving between dashboards in one browser session; answers are not (no chat history, per PRD non-goals).
- Text typed in the chat box is secondary and capped at 200 characters; it is never sent as SQL and never shown to Claude with row data (A26).

**Banned**

- Free-text SQL, or any box that suggests a query language.
- Lists of ten or more reasons, facilities or actions in text (the nine-row adherence chart is a chart, not a list). Three is the cap in chat and in `Look at these first`.
- Colour-only meaning: every colour has a number, a word or a glyph.
- Sorting a facility table by control % by default, or any layout that buries a flagged facility below a clean one.
- `0%` for missing or too-small data.
- Download links on the new tabs (Statins list, charts).
- Per-clinician or per-patient fudging, patient names inside the chat, any claim of gain beyond the 2% to 12% line.
- Any write from a report tab or the chat. Both are read-only; only the overdue list saves.

## Accessibility Floor

Behavioural; contrast is in `DESIGN.md`.

- Every table is a real `<table>` with `<th scope>`; the sort state is `aria-sort`; flag pills are text, not icons.
- Row meaning is available without colour: flag word, reason sentence, `◆` glyph for the two-sided case.
- Charts: panel description gives the one-line takeaway; every plotted value is also in a tooltip and, where bars are few, printed on the bar. Table beneath carries the same numbers by facility.
- Chat: real buttons, dialog label, non-modal, live region for answers, focus to answer title, `Esc` to close and return focus, visible focus ring, minimum 36px targets, respects `prefers-reduced-motion`. Badge text, not colour, tells the mode.
- Text zoom to 200% must not clip chat content; the panel scrolls.
- `[ASSUMPTION]` Grafana's own controls (tabs, tree, pickers) are accepted as they are; no custom a11y work beyond the above.

## Inspiration & Anti-patterns

**Inspiration:** hearts360 cards (big number, one line of meaning); the overdue list (chips, search, pager, banner); the Drug Stock board's `?` honesty; the cross-country finding that managers act on one clear number, not a dashboard.

**Anti-patterns:** league tables sorted by the headline metric (hides Kolfe); a chat that opens on a blank box; answers longer than a short paragraph; confidence words; showing a ratio from 6 readings.

## Key Flows

### Flow A — UJ-3 Vikram finds the clinic that looks fine but is not

1. Vikram opens HEARTS360 Reports and sees `Protocol adherence`, with `Oct-2026` already set.
2. He opens `Change location`, searches his district and selects it. The tree collapses; the title strip reads `Kolfe District · 90 days to 31-Oct-2026`.
3. He opens `BP fudging`. `Look at these first` names one facility; the table's first row is Kolfe HC: 76% controlled in green, an orange bar, `◆ Looks fine, check readings`, `Readings may be rounded down`, `5.42 readings just under 140 for every 1 just over.`
4. Under the pill he reads `Also flagged on Titration` and clicks it. Same facility, first row: `Medicine rarely stepped up. Only 29% of 112 high-BP visits led to a stronger prescription.`
5. **Climax:** he says out loud which facility to visit first and why, in one sentence, without a spreadsheet.
6. Edge: a small facility shows `Too few readings` in grey, not a score. It sorts below flagged rows and is not mistaken for good news.

### Flow B — UJ-4 Vikram asks the chat why control is low

1. On a facility dashboard Vikram clicks `Ask HEARTS360`. The header reads `PHC-A · Oct-2026` with an `Offline answers` badge. Chips show; no blank box.
2. He clicks `Why is my BP control low?`. Skeleton, then the card: `1` `28% of new patients did not come back for a second visit.` `What to do`: one sentence. `2` `Only 6% of overdue patients with a phone were called.` `What to do`: one sentence.
3. `Also check:` names the facility that looks fine but has a reading score of 5.4. The honesty line closes the card.
4. He clicks `How many patients should I call?`. The plan card shows `86 patients` and four weekly counts.
5. **Climax:** he notes `about 22 calls a week` and clicks `Open the overdue list` to start. The number matches the Overdue calling tab.
6. Edge: no key, offline. The same card appears in under 3 s. Claude fails mid-run: offline wording and a one-line reason.

### Flow C — UJ-5 Meera and the overdue list (unchanged look)

1. Meera opens the program dashboard Overdue tab, changes a status to `Agreed to visit`, sees `Saving…` then `Saved ✓`.
2. Later Vikram opens `Overdue calling` and sees her call counted, whether it was early, and whether the patient returned.
3. **Climax:** the early-call bar is taller than the later-call bar, which tells him calling early works here.
4. Edge: a Viewer's direct write is refused server-side; nothing visible changes on the report tabs.

## Open questions / assumptions for Tony

Proposed new ids continue from A33 (full list in the handoff). `[ASSUMPTION]` flag thresholds beyond A19, A20 (adherence 20% / 60%, statins 25%, calling 10% / 50%, 50% phone) are mine and not from evidence; they live in one table and the owner should confirm them. `[ASSUMPTION]` high control means 60% or more. `[ASSUMPTION]` the Reports window end versus the Reporting Month needs an architect decision; the UX only requires that the real dates are printed. `[NOTE FOR UX]` Kolfe HC is a pattern name from the evidence; the demo's planted facility (A32) will carry its own name.
