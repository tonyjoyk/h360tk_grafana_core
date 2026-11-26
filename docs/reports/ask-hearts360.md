# Ask HEARTS360

**Ask HEARTS360 answers a few fixed questions about one place and month, from the same numbers as the reports. Every number in an answer links back to a report tab.**

Where it is: the blue **Ask HEARTS360** button at the bottom right of the home dashboard, Reports and the drug stock board. Below 1440 px wide it shows as a round icon so it covers less of the page.

## What it answers

The panel opens on the place and month in the page's address. It offers these questions (chips):

| Chip | At a facility | At a district |
| --- | --- | --- |
| Why is my BP control low? | yes | yes |
| Which facilities should I visit first? | | yes |
| Who should I call this week? | yes | yes |
| Are medicines being adjusted? | yes | yes |
| Are my BP readings reliable? | yes | yes |
| Who needs a statin? | yes | yes |

At "All places" it asks you to pick a district or a facility. You can also type a question. It is matched to the nearest chip; anything else gets "I can only answer the questions above. Pick one."

## How an answer is built

1. h360-api reads the report functions for that place and month: control, overdue calls, stepping up, BP readings, statins, new patients and drug stock.
2. A fixed ranker (`h360_api/ranker.py`) picks up to 3 problems, in a set order. A measure that meets its line is never listed as a cause. When control is 60% or more, the facility's own flags (BP readings, then stepping up) come first, under "Control looks good".
3. Stock is read first. When a medicine group has under 30 days left, the answer says to check stock before stepping up or calling.
4. Each problem gets one next step with a size, for example "One nurse can call about 25 a week, so 100 in 4 weeks".
5. The answer is written from fixed sentences, at most 20 words each and 150 words in all.

## The plan card

"Who should I call this week?" adds a **calling plan**: 25 calls a week per nurse for 4 weeks (one nurse per facility at a district), capped at the overdue patients with a phone. It says how many may come back, using the place's own 30-day return share. **Open the overdue list** goes to that facility's list.

## The evidence hover

Each highlighted number opens a small card on hover or keyboard focus: what the number means, the count behind it, a 6-month or 4-quarter chart, the place and month, and **See this in Reports: <tab>**. That link opens the tab with the same place and month.

## Offline by default

With no `ANTHROPIC_API_KEY` set, the chat runs **offline**: the fixed sentences only. The demo runs this way. The panel header says "Written from your reports".

With a key, Claude may reword the sentences. Claude sees only the sentences, with place names masked. It never sees rows, patient names or ids. The reply must keep every number, and pass the same checks; otherwise the offline answer is shown.

## The honesty line

Every answer ends with: "These actions explain only 2% to 12% of why one facility does better than another. Treat them as the best next steps, not a promise." The server adds it after all checks. It never goes through Claude.

## What it never does

- It never writes or changes data. It only reads report functions.
- It never shows or sends patient names, phone numbers or lists. Patient lists stay in Grafana.
- It never answers about a place the user cannot see. That returns "You do not have access to this place."
- It never changes a number or the order of reasons, with or without Claude.
- It never promises an outcome. The words "will" and "guarantee" are not allowed.

Code: `h360_api/routes/chat.py`, `h360_api/ranker.py`, `h360_api/wording.py`, `docker_build/grafana_public/h360/chat-widget.js`. SQL: `report_flags`, `chat_control_summary`, `chat_drug_stock_gate`, `chat_call_plan`, `chat_facility_rank_district` (`0.6.13_to_0.6.14`).
