---
name: HEARTS360 Reports and chat
description: Visual identity for the HEARTS360 Reports dashboard (five tabs) and the floating chat. Extends the hearts360 look and the drug stock board; adds flag, step and chat tokens only.
status: final
sources:
  - {planning_artifacts}/prds/prd-hearts360-mvp-2026-11-04/prd.md
  - {planning_artifacts}/prds/prd-hearts360-mvp-2026-11-04/addendum.md
  - {planning_artifacts}/ux-designs/ux-h360-toolkit-internal-2026-09-27/DESIGN.md
  - docs/demo-screening-cascade.md
  - ASSUMPTIONS.md
created: 2026-11-04
updated: 2026-11-04
colors:
  surface-dashboard: '#F4F5F5'
  surface-panel: '#FFFFFF'
  border-subtle: '#D8D9DA'
  text-primary: '#111217'
  text-muted: '#6E6E6E'
  grafana-accent: '#3D71D9'
  controlled: '#3BB231'
  uncontrolled: '#EEAB00'
  no-visit: '#ED6300'
  ltfu: '#FF3355'
  under-care: '#B51BDC'
  registrations: '#007EE4'
  estimated: '#DAE0E1'
  cell-missing-bg: '#EFEFEF'
  flag-bar: '#ED6300'
  flag-row-bg: '#FDF0E6'
  flag-pill-bg: '#FDE3CF'
  flag-pill-text: '#8A3A00'
  guard-pill-text: '#4E545A'
  step-1: '#E1DEF5'
  step-2: '#C3BDEB'
  step-3: '#A49BE0'
  step-4: '#8578D3'
  step-5: '#6655BF'
  step-6: '#4A3A9E'
  step-other: '#B3BAC1'
  step-off: '#6E7782'
  chat-user-bg: '#3D71D9'
  chat-chip-text: '#2B57B3'
  chat-chip-hover: '#EEF3FD'
  chat-badge-offline-bg: '#ECEEEF'
  chat-badge-claude-bg: '#E8EFFC'
  chat-callout-stock-bg: '#FFF8E1'
typography:
  headline-number: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '32px', fontWeight: '600', lineHeight: '1.1' }
  headline-label: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '14px', fontWeight: '500' }
  card-title: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '16px', fontWeight: '500' }
  table-header: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '12px', fontWeight: '600' }
  table-cell: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '13px', fontWeight: '400' }
  microcopy: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '12px', fontWeight: '400', lineHeight: '1.4' }
  chat-body: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '14px', fontWeight: '400', lineHeight: '1.45' }
  chat-number: { fontFamily: 'Inter, Roboto, Helvetica, Arial, sans-serif', fontSize: '14px', fontWeight: '700' }
rounded: { sm: '2px', md: '4px', lg: '8px', full: '9999px', DEFAULT: '4px' }
spacing: { '1': '4px', '2': '8px', '3': '12px', '4': '16px', panel-gap: '8px', row-pad: '8px', chat-pad: '16px' }
components:
  flag-pill: { background: '{colors.flag-pill-bg}', color: '{colors.flag-pill-text}', border: '1px solid {colors.flag-bar}', rounded: '{rounded.full}', fontSize: '12px', fontWeight: '600' }
  check-pill: { background: '{colors.surface-panel}', color: '{colors.flag-pill-text}', border: '1px solid {colors.flag-bar}', rounded: '{rounded.full}', glyph: '◆' }
  guard-pill: { background: '{colors.cell-missing-bg}', color: '{colors.guard-pill-text}', rounded: '{rounded.full}' }
  flagged-row: { background: '{colors.flag-row-bg}', border-left: '4px solid {colors.flag-bar}' }
  chat-button: { background: '{colors.grafana-accent}', color: '#FFFFFF', rounded: '{rounded.full}', height: '48px' }
  chat-panel: { background: '{colors.surface-panel}', border: '1px solid {colors.border-subtle}', rounded: '{rounded.lg}', width: '380px', height: '560px' }
  chat-chip: { background: '{colors.surface-panel}', color: '{colors.chat-chip-text}', border: '1px solid {colors.grafana-accent}', rounded: '{rounded.full}', height: '36px' }
---

# HEARTS360 Reports and chat — Design Spine

> Extends `ux-h360-toolkit-internal-2026-09-27/DESIGN.md` (drug stock) and the hearts360 look in `docs/demo-screening-cascade.md`. Nothing there is overridden. Spines win on conflict with any mock. UI system: Grafana 13 with ECharts (`volkovlabs-echarts-panel`), Business Text (`marcusolsson-dynamictext-panel`, renderMode `everyRow`), `equansdatahub-tree-panel`. No new plugins. Light theme only [A40].

## Brand & Style

Same posture as the existing boards: calm, flat, dense, sentence case. Colour carries state, never decoration. New for Reports: a report is a **decision card**, not a chart gallery. Each tab opens with the question a manager is asking, gives the answer as one or two big numbers, shows one chart, and ends in a table that says which facilities to look at and why. Plain words everywhere (see `EXPERIENCE.md` Voice).

## Colors

- **Reused as is.** `{colors.controlled}` `{colors.uncontrolled}` `{colors.no-visit}` `{colors.ltfu}` `{colors.under-care}` `{colors.registrations}` `{colors.estimated}` keep their cascade meaning. Large headline numbers may use them as text (as today). **Small text never does**: use `{colors.text-primary}` or `{colors.text-muted}`.
- **Needs a look** = `{colors.no-visit}` family (`flag-bar`, `flag-row-bg`, `flag-pill-*`), per addendum 8. Pill text is dark `{colors.flag-pill-text}` on a light fill because white on `#ED6300` fails AA at 12px. `{colors.ltfu}` is **not** used for flags on these tabs.
- **Guard pill** (`Too few …`) is grey `{colors.cell-missing-bg}`: "we cannot say", not "bad".
- **Adherence steps** (new, `{colors.step-1}` to `{colors.step-6}`): an indigo ramp, light to dark = fewer to more medicine and dose. `{colors.step-other}` (other protocol combination) and `{colors.step-off}` (outside the protocol) are greys. "Could not read the entry" uses `{colors.estimated}` with a dashed outline. Indigo avoids the green/amber/orange/red state colours. Step meaning is always also in the row label.
- **Statin and calling charts** reuse `{colors.controlled}` (on a statin) and the indigo ramp (`step-5` early calls, `step-2` later calls).
- **Chat** uses `{colors.grafana-accent}` as its one action colour, the same blue as the active tab underline. Mode badge: `chat-badge-offline-bg` or `chat-badge-claude-bg`. Stock callout `chat-callout-stock-bg`.
- **Meaning is never colour-only**: every colour has a number, a word or a glyph beside it.

## Typography

Inherit Grafana's Inter stack. Headline number `{typography.headline-number}` (matches the cascade's green "3,026 patients"). Label under it `{typography.headline-label}`, then a muted `{typography.microcopy}` line `N patients with …`. Table `{typography.table-header}` / `{typography.table-cell}` (tabular numerals, right-aligned). Numbers: thousands commas; percents whole, one decimal under 10%; fudging score two decimals (`4.80`); months `Oct-2026`; dates `31-Oct-2026`.

## Layout & Spacing

### Dashboard shell (above the tabs)

Dashboard title `HEARTS360 Reports`, folder `HEARTS360 Dashboards`. Top to bottom: (1) Grafana chrome, with a dashboard link `← Program dashboard`. (2) Variables: `Reporting Month` (same control and label style as Drug Stock; last 12 months; default = latest completed month [A34]) and `Patients counted` (`Established patients only` default, or `Include new patients`; only the Protocol adherence tab reads it [A44]). (3) Row `Change location`, **collapsed by default** (the Drug Stock tree is 300px tall; here it would push every tab down), same tree panel and chrome, no cascade row. (4) Five tabs: `Protocol adherence` · `Titration` · `BP fudging` · `Statins` · `Overdue calling`. The Grafana time picker defaults to `Last 12 months` and only sets how far back the trend charts reach; each tab's subtitle states the exact period it reports.

### Tab skeleton (same on all five)

| y | x · w · h | Panel | Type |
|---|---|---|---|
| Row `Summary` (open) | | | |
| 0 | 0 · 24 · 2 | Title strip: question, then `{place} · {period}` | Business Text |
| 2 | 0 · 24 · 4 | Headline strip: three equal columns, one border, thin dividers (like `panel-outcomes`) | Business Text |
| 6 | 0 · 14 · 9 | The one chart | ECharts |
| 6 | 14 · 10 · 9 | `Look at these first`: up to 3 flagged facilities, most patients first | Business Text |
| Row `Facility comparison` (open) | | | |
| 15 | 0 · 24 · 12 | Facility table with `Flag and reason` | Business Text (HTML table) |
| 27 | 0 · 24 · 2 | `How this is worked out` (1–2 sentences, muted) | Business Text |

Panel titles are empty on Business Text panels (the card draws its own title, as in the overdue list); the ECharts panel keeps a Grafana title and an (i) description. Gap `{spacing.panel-gap}`. Rows are sentence case (`Summary`, `Facility comparison`). Cards: white, 1px `{colors.border-subtle}`, `{rounded.lg}`.

### Headline strip anatomy

Per column: `{typography.headline-number}` in the measure colour; label `{typography.headline-label}`; muted line `N of M patients with …`. Title strip: question in `{typography.card-title}`; subtitle in muted microcopy. `{place}` is the selected location's name, or `All locations you can access`.

### Shared facility table

Business Text HTML table, same style as the overdue list (light header, no vertical lines or stripes, hover highlight, numbers right-aligned), sorted with `afterRender` JS, 10 rows per page with the overdue list's pager. Fallback if this proves hard: `volkovlabs-table-panel` with the same columns and cell-colour overrides [A43].

- **Columns.** `Facility` · `BP controlled` (all tabs except Statins and Overdue calling use it first as context) · tab measures · `Flag and reason` (last, widest).
- **Default sort: `Needs a look first`.** Flagged rows first, then by number of flags, then by patients in scope. Never by control %. A chip `Sort: needs a look first` stays visible; clicking a column header re-sorts and the chip becomes a button to reset [A35].
- **Flagged row** `{components.flagged-row}`: 4px orange left bar, light tint, and a `{components.flag-pill}` with the flag name; under it the reason sentence in `{typography.microcopy}` text-primary.
- **Kolfe pattern (two-sided).** A row with `BP controlled` of 60% or more [A36] and any flag keeps its green control number, still gets the orange bar and tint, and adds a `{components.check-pill}` reading `◆ Looks fine, check readings` (BP fudging, Titration) before the flag pill. Because flagged rows always sort first, a 76%-controlled facility sits above a 40%-controlled facility with no flag. Under the pill: `Also flagged on Titration` (or `BP fudging`) as a link to that tab with the same location. A neutral tone is kept: no red, no warning triangle.
- **Guard row** (`Too few …`): `{components.guard-pill}`, measure cells show `—`, never `0%`. Guard rows sort after flagged rows and before clean rows.
- **Clean row**: no pill; Flag cell reads `No flag`, muted.
- **Totals.** At district or wider scope, a bold first row `All places in view`, computed from summed counts, not an average of rows (FR-23 principle).

## Elevation & Depth

Flat panels as today. One exception: the floating chat button and panel carry `box-shadow: 0 4px 16px rgba(17,18,23,0.16)` so they read as floating over the page. Chat z-index 1000, below Grafana modals and the command palette.

## Shapes

`{rounded.lg}` (8px) for cards and the chat panel; `{rounded.full}` for chips, flag pills and badges; `{rounded.sm}`–`{rounded.md}` for table elements and inputs. Bars in charts have 2px end radius.

## Components — per tab

Period text: monthly measures say `{Mon-YYYY}` (the Reporting Month); Window measures say `90 days to {D-Mon-YYYY}`, `last 3 months to {D-Mon-YYYY}`. Charts show the running month dashed (cascade rule). The shared `tip()` tooltip is used everywhere: bold header, `Label: 61%`, then `3,901 of 6,523 patients` in lighter text.

### Tab 1 · Protocol adherence

- **Title:** `Are patients on the medicines the protocol says?` Subtitle: `{place} · 90 days to {date} · {N} patients counted (registered before {date})`.
- **Headline strip:** (1) green `{p}%` **BP controlled** · `{n} of {N} patients with BP under 140/90 at their latest visit`. (2) `step-4` `{p}%` **On two or more medicines** · `{n} patients on 2 or 3 medicines`. (3) orange `{p}%` **Off protocol** · `{n} patients on medicines outside the protocol, or entries we could not read`.
- **Chart** (`Patients by medicine step, and how many are controlled`): horizontal bars, nine rows top to bottom, step colours, 0 at left. Row labels: `1 medicine, starting dose` · `1 medicine, full dose` · `2 medicines, starting doses` · `2 medicines, one at full dose` · `3 medicines, not all at full dose` · `3 medicines, all at full dose` · `Other protocol combination` · `Medicine outside the protocol` · `Could not read the entry` [A42]. Bar length = patients. End label: `{n} patients · {p}% controlled`. Tooltip: `{label}` / `{n} patients ({s}% of {N})` / `{c} of {n} controlled ({p}%)`.
- **Look at these first:** facility name bold, then `{n} patients · {reason}`.
- **Table:** `Facility` · `Patients` · `On 2 or 3 medicines` · `Off protocol` · `BP controlled` · `Flag and reason`. Flags [A38]: `Many off protocol` — `{p}% of patients are on medicines outside the protocol or unreadable.` (20% or more) · `Mostly one medicine` — `{p}% of patients are on one medicine.` (60% or more) · `Too few patients` — `Only {n} patients in this period. Need at least 20.`
- **Note:** `Each patient's latest prescription is placed on a six-step ladder of medicines and doses. Controlled means BP under 140/90 at the latest visit. 'Patients counted' above changes who is included.`

### Tab 2 · Titration

- **Title:** `Are patients with high BP getting stronger treatment?` Subtitle: `{place} · 90 days to {date}`.
- **Strip:** (1) `{p}%` **Medicine stepped up** · `{n} of {N} visits with BP 140/90 or above were followed by a stronger prescription`; green at 40% or more, orange under. (2) `{N}` **High-BP visits counted** · `BP 140/90 or above, last 90 days` (text-primary). (3) `{x}` **Visits left out** · `{a} too recent to check, {b} with no earlier prescription` (muted).
- **Chart** (`Medicine stepped up when BP was high, by month`): line, 0–100% in 25% steps, running month dashed, dashed horizontal line labelled `Flag line: 40%`. Tooltip: `Mon-YYYY (in progress)` / `Stepped up: 45%` / `{n} of {N} high-BP visits`.
- **Table:** `Facility` · `BP controlled` · `High-BP visits` · `Stepped up` · `Titration rate` · `Flag and reason`. Flags: `Medicine rarely stepped up` — `Only {p}% of {N} high-BP visits led to a stronger prescription. The line is 40%.` · `Too few visits` — `Only {n} high-BP visits. Need at least 10.` Sort ties by `High-BP visits` so large facilities surface first (FR-36).
- **Note:** `Looks at visits with BP 140/90 or above. A visit counts as stepped up if the prescription at that visit, or the next one within 30 days, is stronger. Visits too recent to have a next visit are left out.`

### Tab 3 · BP fudging

- **Title:** `Are BP readings being rounded down?` Subtitle: `{place} · last 3 months to {date}`.
- **Strip:** (1) `{x.xx}` **Fudging score** · `{x.xx} readings just under 140 for every 1 just over. 2.00 or more is flagged.` (orange at 2.00+). (2) `{n}` **Readings of 135 to 139** · `just under the line`. (3) `{n}` **Readings of 140 to 144** · `just over the line`.
- **Chart** (`Top BP number of each reading, last 3 months`): column histogram, 5-point bands 120–124 … 150–154. Bands 135–139 `{colors.uncontrolled}`, 140–144 `{colors.no-visit}`, others `{colors.estimated}`. Count printed above each bar. Vertical dashed line between 139 and 140 labelled `140: high BP starts`. Tooltip: `{band}` / `{n} readings`. Needs band counts from the data [A39]; fallback is two bars (135–139, 140–144).
- **Table:** `Facility` · `BP controlled` · `135–139` · `140–144` · `Score` · `Flag and reason`. Flags: `Readings may be rounded down` — `{x.xx} readings just under 140 for every 1 just over.` · `No readings of 140–144` — `None just over the line. Check the readings.` (flagged) · `Too few readings` — `Only {n} readings of 135–144. Need at least 20.` Score `—` on guard rows. Two-sided pill applies.
- **Note:** `Counts readings of 135–139 and 140–144 in the last 3 months and divides the first by the second. A high score is a reason to look at how BP is measured. It does not prove rounding down.`

### Tab 4 · Statins

- **Title:** `Which eligible patients are not on a statin?` Subtitle: `{place} · {Mon-YYYY} · eligible = aged 40 or older with diabetes, or a heart attack or stroke`.
- **Strip:** (1) `{N}` **Eligible patients** · `alive and under care` (text-primary). (2) green `{p}%` **On a statin** · `{n} of {N} eligible patients`. (3) orange `{n}` **Not on a statin** · `These patients need a review.`
- **Chart** (`Eligible patients on a statin, by month`): green line 0–100%, running month dashed. Tooltip: `On a statin: 27%` / `{n} of {N} eligible patients`.
- **Table:** `Facility` · `Eligible` · `On a statin` · `Not on a statin` · `% on a statin` · `Flag and reason`. Flags: `Few on a statin` — `Only {p}% of {N} eligible patients are on a statin.` (under 25%) · `Too few patients` — `Only {n} eligible patients. Need at least 10.`
- **Extra row `Patients to review` (y 29, w 24, h 14):** list in the overdue-list pattern. Header `{n} eligible patients not on a statin at {place}`; reason chips `All` · `Diabetes` · `Heart attack or stroke` · `Both` (with counts); search (name, Patient ID); columns `Patient` (name, ID grey beneath) · `Age` · `Why eligible` · `Last visit`; 20 rows per page, pager. No download link. Above facility level: banner `The patient list is available only at the facility level.` in the same style as the overdue tab's banner.
- **Note:** `Eligible means alive, under care, aged 40 or older, with diabetes or a recorded heart attack or stroke. On a statin means atorvastatin, simvastatin or rosuvastatin on the latest prescription.`

### Tab 5 · Overdue calling

- **Title:** `Are we calling overdue patients early, and do they come back?` Subtitle: `{place} · {Mon-YYYY} · overdue as on the overdue list`.
- **Strip:** (1) `{p}%` **Called** · `{n} of {N} overdue patients with a phone were called`. (2) `{p}%` **Calls made early** · `{n} of {N} calls were within 14 days of becoming overdue`. (3) green `{p}%` **Came back after a call** · `{n} of {N} called patients visited within 30 days`.
- **Chart** (`Came back within 30 days, by when we called`): two horizontal bars, `Called within 14 days` (`step-5`) and `Called later` (`step-2`), 0–100%. End label `{p}% · {n} of {N}`. Tooltip: `{group}` / `{n} of {N} came back ({p}%)`.
- **Side card** replaces `Look at these first` here: `What happened on the calls` — rows `Agreed to visit {n}` · `Call again later {n}` · `Removed from list {n}`, footer `{N} calls in total`, then a blue link `Open the overdue list to call` (program dashboard, Overdue tab, same location).
- **Table:** `Facility` · `Overdue with a phone` · `Called` · `Calls made early` · `Came back` · `Flag and reason`. Flags: `Few called` — `Only {p}% of {N} overdue patients with a phone were called.` (under 10%) · `Mostly late calls` — `Only {p}% of calls were within 14 days.` (under 50%) · `Few phone numbers` — `Only {p}% of overdue patients have a phone number.` (under 50%) · `Too few patients` — `Only {n} overdue patients with a phone. Need at least 10.` Max two pills per row.
- **Note:** `Overdue patients are those on the overdue list. A call is early if made within 14 days of becoming overdue. Came back means a visit within 30 days of the call.`

### States (all tabs, FR-32)

| State | Treatment |
|---|---|
| No data | Cards show `—` and `No data for this place.`; chart area centred `No data for this place.` (14px muted); table `No facilities for this location.` |
| Too few cases | Number replaced by `Too few readings` / `Too few visits` / `Too few patients` (20px muted) and the line `Need at least {k}; this place has {n}.` Never `0%`. |
| No access | Existing HTN access banner, verbatim. |
| No flags | Side card: `No facility is flagged. Check the table below.` |
| Guard thresholds | 20 patients, 10 high-BP visits, 20 readings, 10 eligible, 10 overdue with phone [A37]. |

## Components — Chat widget

Plain HTML/CSS/JS injected into Grafana pages [A17]. Scope: `var-org_unit` and `var-reference_month` from the URL. All sizes are CSS px; `font-family: Inter, Roboto, Helvetica, Arial, sans-serif` (same as Grafana, so it inherits visually).

- **Button** `{components.chat-button}`: `position: fixed; right: 64px; bottom: 20px` (clears Grafana's right toolbar, which sits about 14–40px from the edge); height 48, padding `0 20px 0 16px`, radius full; speech-bubble icon (20px, white, `aria-hidden`) + label `Ask HEARTS360` 14px/600 white; background `{colors.grafana-accent}`; hover `#2F5FC0`; focus ring `2px solid #111217` + `2px #fff` offset. Hidden while the panel is open (the panel header's close button replaces it). Never moves the dashboard layout.
- **Panel** `{components.chat-panel}`: `position: fixed; right: 64px; bottom: 76px; width: 380px; height: min(560px, calc(100vh - 100px))`; `display:flex; flex-direction:column`. Under 480px viewport width: `left:8px; right:8px; width:auto`.
- **Header** (56px, bottom border `{colors.border-subtle}`, padding 12px 16px): left, scope `PHC-A · Oct-2026` 14px/600 (name truncated with ellipsis, full name in `title`), beneath it `Hypertension only` 12px muted. Right, mode badge then a 32px `×` close button. Badge (pill, 12px/600, 4px 8px): `Offline answers` on `chat-badge-offline-bg` with `{colors.text-primary}`, or `Claude` on `chat-badge-claude-bg` with `{colors.chat-chip-text}`; `title` explains: `Offline answers are written from a template. The numbers are the same.` / `Claude wrote the words. The numbers are the same.`
- **Body**: scrolls, padding `{spacing.chat-pad}`, `{typography.chat-body}`, background `{colors.surface-dashboard}`. First view: line `Pick a question. I answer from your reports.` then the chips stacked in one column, 8px gap, full width, left-aligned text, each 36px+ high, 1px accent border, `{colors.chat-chip-text}` text, radius full, hover `{colors.chat-chip-hover}`. Chips are listed in `EXPERIENCE.md`. Secondary text input pinned under the body: 40px, placeholder `Or type a question`, radius 4, `Ask` button; it is visually quieter than the chips.
- **User bubble**: right-aligned, max 85%, `{colors.chat-user-bg}`, white 14px, radius `8px 8px 2px 8px`, padding 8px 12px.
- **Answer card**: white, 1px `{colors.border-subtle}`, `{rounded.lg}`, padding 16px, gap 12px, top to bottom:
  1. Title `Why is BP control low at PHC-A?` 14px/600; muted line `42% controlled in Oct-2026`.
  2. Per reason (2 or 3): 24px rank circle (`{colors.text-primary}` fill, white `1`) + sentence with the number in `{typography.chat-number}` (`**28%** of new patients did not come back for a second visit.`); under it `What to do` (12px/600 muted) and one sentence of advice; then the **nudge button**: outline, accent border, accent text, full width, 36px, e.g. `How many patients should I call?`; then link `See this in Reports: Overdue calling` (12px, accent). Reasons separated by a 1px rule.
  3. `Also check:` line (only when two-sided applies): `◆` glyph, light grey background `{colors.cell-missing-bg}`, radius 4, padding 8px 12px.
  4. Stock line (only when stock is low): `{colors.chat-callout-stock-bg}`, 4px left bar `{colors.uncontrolled}`, text `Fix drug stock first: CCB has 12 patient-days left.`
  5. Honesty line, after a rule, 12px muted, verbatim: `These actions explain only 2% to 12% of why one facility does better than another. Treat them as the best next steps, not a promise.`
- **Plan card** (nudge result): title `Calling plan for PHC-A`; big number `86 patients` (`{typography.headline-number}` text-primary) with `overdue and have a phone`; four equal week cells `Week 1` … `Week 4`, each with its count (muted label, 16px/600 number, `{colors.estimated}` fill); line `Start with the patients overdue longest.`; link `Open the overdue list`; honesty line again.
- **Loading**: answer-card skeleton (three grey `{colors.estimated}` bars, no shimmer under reduced motion) and `Looking at your reports…`; after 3 s `Still working…`; give up at 10 s.
- **Errors** (card, 4px left bar `{colors.uncontrolled}`): `I couldn't get an answer. Your reports are not affected.` + `Try again` button + `Pick another question`. Claude failure: answer shown in offline wording, badge switches to `Offline answers`, line `Claude was not available, so this is written from a template.` Not signed in: `Your session ended. Reload the page and sign in.` No data: `There is no data for {place} in {Mon-YYYY}, so I can't rank reasons.` Too few: `Too few patients here to rank reasons.`
- **Keyboard and screen reader**: button is a real `<button aria-expanded aria-controls aria-label="Open HEARTS360 assistant">`; panel `role="dialog" aria-label="HEARTS360 assistant"` (non-modal, no focus trap); chips are `<button>`s in `role="group" aria-label="Questions you can ask"`; answers land in a `role="log" aria-live="polite"` region and focus moves to the answer title (`tabindex="-1"`); `Esc` closes and returns focus to the button; focus ring `2px #3D71D9`, offset 2px; no motion beyond a 120ms fade, none under `prefers-reduced-motion`.

## Do's and Don'ts

**Do**

- Put the question, then the number, then the chart, then the table, in that order on every tab.
- Sort every facility table flagged-first and say the reason in a sentence.
- Show the Kolfe pattern: good control plus a flag is orange-barred and labelled.
- Print the period and the counts behind every percent.
- Use tokens above; add a token before using a new hex.

**Don't**

- Sort tables by control % or colour a row green for good control.
- Use red (`{colors.ltfu}`) for flags, or colour as the only signal.
- Show `0%` when there are too few cases.
- Add more than three reasons or three "look first" items anywhere.
- Add a free-text query box that looks like SQL, a download link on Statins, or any new plugin.
