# What I am trying to achieve

Owner: Tony Joy, Resolve to Save Lives
Date: Nov. 4, 2026
Read with: `02-CONTEXT-hearts360-build.md`

---

## The goal in one paragraph

I want one HEARTS360 toolkit branch that holds everything we have built so far, plus five new reports, plus a small AI chat that helps a program manager make sense of the dashboard. Work already exists in two places and does not yet sit together. Some of it has known bugs. I want it merged and fixed first, then the new reports built on top, then the chat last. Treat the whole thing as an MVP prototype. The simplest version that is genuinely usable beats a complete version that is not.

---

## Five aims, in this order

### 1. Review everything first

Read the repos, branches, planning docs and research listed in the context file before writing code. Several of these reports already exist in some form. Some exist as Excel tools, some as SQL, some as a React prototype. Do not rebuild what is already written down.

### 2. Integrate what is already done into one repo

Two bodies of work need to become one branch:

- Screening cascade, treatment cascade, cohort charts, hearts360 styling and the overdue list
- Drug stock

They sit on different base versions, the migrations clash and the dashboard JSON will conflict. Fix the bugs that are already known rather than carrying them forward. One of them is a security hole that has to close before any new report writes data.

### 3. Build the new reports using reverse-engineered logic

Five reports:

- Titration
- Protocol adherence
- BP fudging
- Statins
- Overdue calling

The protocol adherence logic already exists as a working Excel tool. Reverse-engineer it rather than guessing the clinical rules. The medicine format comes from that tool and follows the Indonesia format. We can change the format later.

This also means Postgres has to store medicine data, which it does not today. It means generating fake but realistic medicine data and overdue calling data, so the reports have something to show.

The existing hypertension and diabetes tabs must not change at all.

### 4. Keep it an MVP

This is a prototype we want to put in front of people and learn from. Not a production release.

- Pick the simplest approach that works.
- Write down the tradeoffs we are making on purpose, in the PRD or a separate document.
- Follow the design system already used by the existing charts.
- Usability is the thing I care about most. A rough report that a program manager understands beats a complete report that confuses them.

### 5. Build the AI tool

A small chat that floats over Grafana as a plugin. A program manager looking at a facility dashboard should be able to ask "why is my BP control low?" and get a short, plain answer they can act on.

Guided prompt chips they click, rather than a blank box. Claude API behind it for now. Stored, curated queries rather than free SQL. Answers written in the clear-writing style, ranked by what the evidence says will actually move the number, ending in a concrete plan the manager can commit to.

The chat comes last. The reports have to work first, because the chat reads from them.

---

## What done looks like

I open the toolkit on my machine and see:

- One branch with the cascade work and drug stock merged, bugs fixed
- Titration, protocol adherence, BP fudging, statins and overdue calling reports, working with realistic data
- Postgres holding medicine data
- The existing hypertension and diabetes tabs untouched
- A chat panel I can open over the dashboard and use

---

## How I want you to work

Use the BMAD skills. Run the UX, product and architecture agents to produce epics and stories before building. There is a worked example of the output shape in the drug stock branch under `_bmad-output/`, so match that structure.

Stop and report after the merge is clean, before starting the new reports. I want to see a working merged branch before new work lands on top of it.

---

## What must not break

- The current hypertension and diabetes tabs and dashboards in Grafana
- Existing data on a fresh install. One open PR deletes and inserts patient rows. Do not merge it as is.
