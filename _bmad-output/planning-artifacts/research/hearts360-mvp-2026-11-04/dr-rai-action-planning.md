---
source: Miro board "Dr Rai Training video" (https://miro.com/app/board/uXjVG5aJetA=/), read 2026-11-05
use: context only (owner: "purely for context"); informs chat wording (6.4, 6.5), report tabs and the UX audit (7.9)
---

# How a program manager turns dashboard data into actions (Dr Rai / Simple action plans)

The board is Simple's training deck for **Action Plans** on the Simple dashboard: 34 slides plus speaker notes. It shows the path a district or facility manager follows from data to action.

## The flow

1. **Review the dashboard.** Its job is to answer three questions:
   - Are patients doing well? (BP control, missed visits, medicines)
   - Where are the problems? (compare facilities, spot patterns)
   - What should improve next? (goals and actions)
2. **Read trends with five rules** (from the speaker notes):
   1. Look at 3 to 6 months, not one month.
   2. Classify each trend as improving, stable or worsening.
   3. Always read percentages with patient counts.
   4. Combine outcome trends with process indicators. Are doses being adjusted (titration)? Are statins prescribed when needed? Are patients who missed visits being called (overdue calling)? Is medicine in stock?
   5. Decide (the fifth rule's text was cut off on the board).
3. **Find the likely cause** for each outcome indicator:
   - **BP control falling** has three common causes: medicines not increased for uncontrolled patients (low titration), many new registrations, and medicine stock problems. Check the titration rate, new registrations and stock-outs.
   - **BP uncontrolled, gradual rise:** low titration, rising missed visits, or many new registrations.
   - **BP uncontrolled, sudden sharp fall:** BP fudging or data entry problems.
   - **Missed visits:** low follow-up, or new patients not returning after their first visit. First checks:
     - What % of overdue patients were called?
     - How do missed visits in the quarterly cohort chart compare with the main graph? Higher in the cohort chart suggests poor retention of new patients.
4. **Use the quick links** for the deeper reports: titration ("check if medicines are being adjusted"), BP fudging ("review unusual BP patterns"), statins ("check if eligible patients are receiving statins") and drug stock ("review medicine availability"). These are the same five areas as our Reports tabs.
5. **Prioritise.** Pick one or two priority indicators and discuss root causes with the facility team. "If we try to do everything, we miss important goals."
6. **Set a quarterly goal.** A goal is an outcome with a number, an indicator and a deadline, and it must be:
   - an improvement on last quarter (review last quarter's result first);
   - realistic within one quarter;
   - collaborative.

   Examples:

   | Good | Bad |
   | --- | --- |
   | `Increase BP control from 56% to 62% by the end of Q2` | `Improve BP control` |
   | `Reduce missed visits from 58% to 50% by March 31` | `Call more patients` |
   | `Increase diabetes patients prescribed statins by 5% in Q2` | `Achieve 90% BP control` |
   | `Titrate 25% of eligible uncontrolled patients this quarter` | |
7. **Add 2 to 5 specific actions.** An action is a focused task, specific and measurable. Examples by area:
   - **Calling:**
     - Assign one nurse to call 25 overdue patients each week and record calls in Simple.
     - Call 5 patients in the last 30 minutes of every workday.
     - Use a call script: confirm medicine is available, set a return date, record the reason if the patient will not come.
     - Extend a landline to the clinic, or buy SIM cards for calling.
     - Review progress every week in the team meeting.
   - **Titration:**
     - Counsel every uncontrolled patient to take medicines in the morning before visiting.
     - Run one case-based titration review session a month for medical officers.
     - Review the titration rate in the monthly facility meeting and discuss patients who were not titrated.
   - **Stock:**
     - Check medicine stock weekly and order when less than two weeks of stock is left.
   - **Bad actions** are vague: "Motivate staff", "Tell doctors to titrate more", "Do more follow-ups".
8. **Create the action plan in the product.**
   - Click `Add an action` on the facility dashboard.
   - Step 1: choose the indicator to improve (`Contact overdue patients`, `Statins`, `BP Fudging`).
   - Step 2: set the quarterly goal. The form shows last quarter as a baseline, for example `32% overdue patients called (36 of 114) in Q4 2025`, and the user enters, say, `50% by Mar 31`.
   - Step 3: type the actions.
   - The plan then shows on the dashboard as a card: the goal title, a numbered action list, and a progress bar (`11 of 36 overdue patients called`, 32%) that updates automatically.
9. **During the quarter,** review progress regularly, check actions are done, and adjust if progress is slow. At quarter end, review the results and set the next goal.

**Summary slide:** spot patterns, understand the root cause, set a realistic target, add specific actions, track progress.

## What this means for this build

- **Chat `What to do` sentences** should read like the deck's good actions: specific, with a number and a cadence, and recorded in the system. For example: `Assign one nurse to call 22 overdue patients each week.` Avoid vague advice.
- **Every percentage should carry its counts** (rule 3). This matches DESIGN's `n of N` rule. Check it in the UX audit.
- **The ranker's causes match the deck's diagnosis map:**
  - low control → titration, new patients, stock;
  - missed visits → calling, new-patient return.

  The stock gate ("Fix stock first") is in the deck too.
- **The Reports tabs are the deck's "quick links" reports** (titration, BP fudging, statins, drug stock, overdue calling). The UX audit should check they are reachable from the HTN dashboard as easily as Dr Rai's quick links: one click, the same place and month.
- **The plan card** (calls per week) is the deck's calling action with numbers filled in. The deck's quarterly goal with baseline (`last quarter: 32%, 36 of 114`) is a natural next step. It is not in the current stories; record it as a follow-up candidate, not in scope.
- **The overdue section on the Hypertension tab** (5.18) gives the baseline the deck uses for calling goals: % of overdue patients called, with counts.
