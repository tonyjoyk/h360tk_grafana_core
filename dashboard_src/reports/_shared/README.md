# Shared parts for the Reports tabs

Files here are pasted into panel options by `scripts/build_reports_dashboard.py`, so all tabs
draw the title strip, headline strip, facility table, states and tooltips the same way. Edit a file
here, rebuild, and every tab picks it up.

## Story 7.9 changes for tab authors (UX audit groups C and I)

Tab order is now `Start here · Stepping up · Right medicines · BP readings check · Overdue calls ·
Statins` (builder `TABS`). File names are unchanged. What this means for `1-adherence.json` to
`5-calling.json`:

| Change | What to do in a tab |
| --- | --- |
| `Start here` (`0-start.json`) replaces the strip above the tabs and every `Look at these first` card (UX-14). | Remove the `panel-<slug>-look` panel and widen the chart or table into its space. |
| Facility names in `rptTable` link to the same tab, narrowed to that facility (UX-15). | Nothing. Pass `nameLinks: false` only to turn it off. |
| `Also flagged on` comes from `report_flags` (UX-16): every other report tab that flags the facility, in tab order. Each link opens that tab for that facility. | Delete `alsoOn: [...]`; arrays are now ignored. Pass `alsoOn: false` to hide the line. The query still needs the `flags_json` column. |
| Access banner is a grey note with the next step; team names sit in a closed `Details for your admin` (UX-21). | Nothing; keep `rpt.mount(sel, { banner: true })` on the title strip. |
| A user with no location who cannot see all places is moved to their home unit (UX-02). `rpt.mount` does it. | Nothing. Always mount through `rpt.mount`. |
| New `rpt.info(html)` and `rpt.PICK_FACILITY` (UX-21). | Facility-only views (Statins patient list): `root.innerHTML = rpt.info(rpt.esc(rpt.PICK_FACILITY))` above facility level, and keep the panel short. |
| New `rpt.nextStep(text, href)`. | End the tab with one `Next step` line (§2 of the audit), for example `rpt.nextStep('Check medicine stock first', '/d/heart360_drug_stock?var-org_unit=' + rpt.orgUnit() + '&var-reporting_month=' + rpt.reportingMonth())`. |
| `rpt.link(report, org, mon, extra)` takes URL parameters in `extra`. | Right medicines: the `Patients counted` variable is hidden in the top bar (UX-38). Offer the switch in the tab, for example `rpt.link('adherence', null, null, { 'var-include_new': 'true' })`, and read it with `rpt.v('include_new')`. |
| `rpt.REPORTS` is `rpt.TABS` without `Start here`. | Use it to loop over the five reports. |
| `rpt.mount(sel, { loading: 'Finding facilities…' })` shows a line while the query runs (UX-39). | Optional. |
| The Change location row is titled `Change location · <place>` (UX-18, hidden variable `place_name`). The header strip is gone. | Nothing. |

The `Start here` grid reads, per report, the row's `flag`, `too_few` and `looks_fine_check` (titration
and fudging), and one number: `titration_pct`, `one_medicine_pct`, `score`, `called_pct`,
`on_statin_pct`. A cell is `Flagged` when the row's `flag` is true or `report_flags` lists the facility
for that report. If a report function changes these columns, update the query in `0-start.json`.

## Placeholders

Any JSON string in `_shell.json` or a tab file (`<n>-<slug>.json`) may contain:

| Placeholder | Replaced by |
| --- | --- |
| `{{shared:<file>}}` | the text of `dashboard_src/reports/_shared/<file>`, trailing newlines trimmed |
| `{{tabs}}` | the builder's `TABS` list as JSON, in tab order: `[{"report": "start", "title": "Start here", "slug": "Start-here"}, {"report": "titration", ...}, ...]` |

Rules: one level only (a shared file may not contain `{{shared:...}}`); a missing file, a bad name
or a leftover `{{shared:` fails the build. Handlebars `{{...}}` in Business Text content is left
alone. Keys starting with `_` in `_shell.json` are dropped before expansion. `--check` stays
deterministic because the output depends only on the files.

```
python3 scripts/build_reports_dashboard.py          # writes heart360.reports.json
python3 scripts/build_reports_dashboard.py --check  # exit 1 if it is stale
```

## Files

| File | Use in | Declares |
| --- | --- | --- |
| `styles.css` | Business Text `styles` | classes `rpt-*`; put `class="rpt ..."` on the panel's root div |
| `states.js` | Business Text `afterRender`, first | `rpt` (helpers, states, deep links, `{{tabs}}`) |
| `table.js` | Business Text `afterRender`, after `states.js` | `rptTable(root, cfg)` |
| `tip.js` | ECharts `getOption`, first | `fmt`, `soft`, `dot`, `pctStr`, `shareRows`, `tip`, `chartColors` |
| `user_home_unit.sql` | `_shell.json` variable `home_org_unit` (`definition`, `rawSql`) | the home dashboard's `UserOrgUnitId` query: the user's home unit id, or `''`. Keep the two texts equal (UX-02) |

Snippets are pasted as code into one function body, so do not redeclare the names they declare.

## A Business Text panel

```json
"content": "<div class=\"rpt rpt-sta-head\"></div>",
"defaultContent": "<div class=\"rpt rpt-sta-head\"></div>",
"styles": "{{shared:styles.css}}",
"afterRender": "{{shared:states.js}}\nconst root = rpt.mount('.rpt-sta-head');\nif (!root) { return; }\nconst r = rpt.rows('A')[0];\n..."
```

- Set `defaultContent` equal to `content`: with no rows (no data, or no access) Business Text shows
  `defaultContent` and still runs `afterRender`.
- Use one query per Business Text panel. With two, Business Text shows a frame picker under the
  panel. Join `report_flags` into the main query as `flags_json` instead (see the table query in
  `3-fudging.json`):

  ```sql
  WITH fl AS (
    SELECT org_unit_id, json_agg(json_build_object('report', report, 'flag_reason', flag_reason,
           'patients_n', patients_n) ORDER BY report)::text AS flags_json
    FROM report_flags('${reporting_month}'::date, NULLIF(NULLIF(TRIM('${org_unit}'), ''), '0')::int)
    GROUP BY org_unit_id
  )
  SELECT f.*, fl.flags_json
  FROM report_statins('${reporting_month}'::date, NULLIF(NULLIF(TRIM('${org_unit}'), ''), '0')::int) f
  LEFT JOIN fl ON fl.org_unit_id = f.org_unit_id
  WHERE '$isAllowed' = '1'
  ```
- Every data query ends `WHERE '$isAllowed' = '1'`. Access, location and month are read in the
  browser with `context.grafana.replaceVariables`, so no extra access query is needed.
- Thresholds come from `report_flag_thresholds` (no literals): add them as columns, for example
  `(SELECT value FROM report_flag_thresholds WHERE report = 'statins' AND key = 'min_eligible') AS min_eligible`.

## `rpt` (states.js)

| Name | What it does |
| --- | --- |
| `rpt.mount(selector, { banner, loading })` | Returns the root element, or `null`. First moves a user with no location and no access to all places to their home unit (`home_org_unit`), showing `Opening your area…`. Then, when access is denied, returns `null`: with `{ banner: true }` (title strip only) it draws the grey no-access note; other panels stay empty under it. With `loading: '<text>'` it shows that line and returns `null` while the query runs. |
| `rpt.rows(refId)` | Rows of a query as objects. |
| `rpt.esc`, `rpt.fmt`, `rpt.pct`, `rpt.score`, `rpt.num`, `rpt.yes` | Escape HTML; thousands commas; percent whole (one decimal under 10%); two decimals; number or `null`; Postgres boolean. |
| `rpt.day(d)`, `rpt.month(d)` | `31-Oct-2026`, `Oct-2026` (dates arrive as ms or `YYYY-MM-DD`). |
| `rpt.place(name)` | Subtitle place: the name, or `All locations you can access`. |
| `rpt.needAtLeast(k, n)` | `Need at least 20; this place has 12.` |
| `rpt.noData(text)`, `rpt.NO_DATA`, `rpt.NO_FACILITIES`, `rpt.NO_FLAGS` | The States copy from DESIGN. |
| `rpt.info(html)`, `rpt.banner()`, `rpt.PICK_FACILITY`, `rpt.OPENING_HOME` | Grey note (no warning tone); the no-access note; `Pick a facility in Change location above to see its patients.` |
| `rpt.TABS`, `rpt.REPORTS`, `rpt.tab(report)` | Tabs from the builder in tab order (`TABS[0]` is `Start here`, report `start`); `REPORTS` is the five report tabs. |
| `rpt.link(report, org?, month?, extra?)` | AD-29 deep link keeping the location and month; `extra` is an object of more URL parameters. |
| `rpt.placeLink(report, id, name)` | A facility name linking to `report`'s tab for that facility; plain text when it is the place in view. |
| `rpt.nextStep(text, href)` | The `Next step` line that ends a tab. |
| `rpt.homeUnit()`, `rpt.goHome()`, `rpt.loading()` | Home unit id or `''`; the UX-02 move (called by `mount`); true while the query runs. |
| `rpt.flagsFrom(rows)` | `report_flags` rows from a `flags_json` column. |
| `rpt.thresholds(rows)` | `{ 'fudging.flag_score': 2 }` from `report_flag_thresholds` rows. |

## `rptTable(root, cfg)` (table.js)

Draws DESIGN's shared facility table: `Sort: needs a look first` chip, header sort with
`aria-sort`, 10 rows per page with the overdue list's pager, real `<table>` with `th scope`,
flagged row bar and tint, flag pill, two-sided check pill, guard pill, muted `No flag`, and the bold
`All places in view` first row (the selection row when its level is under 3).

```js
rptTable(root, {
  report: 'statins',                       // this tab's report_flags.report
  rows: rpt.rows('A'),                     // report_<name> rows, selection first
  // flags: rpt.rows('B'),                 // optional; default: each row's flags_json
  columns: [                               // between Facility and Why look here
    { label: 'Eligible', num: true, value: (r) => rpt.num(r.eligible_n), cell: (r) => rpt.fmt(r.eligible_n) },
    { label: '% on a statin', num: true, guard: true, value: (r) => rpt.num(r.on_statin_pct), cell: (r) => rpt.pct(r.on_statin_pct) },
  ],
  flagNames: (r) => ['Few on a statin'],   // at most two pills
  guardName: 'Too few patients',
  guardReason: (r) => rpt.needAtLeast(r.min_eligible, r.eligible_n),
  // check: { text: '◆ Looks fine, check medicines', when: (r) => rpt.yes(r.looks_fine_check) },
  // alsoOn: false,                       // optional: hide `Also flagged on …` (default: from report_flags)
  // nameLinks: false,                    // optional: facility names as plain text (default: links)
  size: (r) => rpt.num(r.eligible_n),      // last sort key when report_flags has no patients_n
  // order: 'size',                       // optional: sort by size (high first) within flagged / too few / clean
  caption: 'Eligible patients on a statin, by facility. Flagged facilities come first.',
});
```

Facility names link to this tab for that facility (UX-15). Under a flagged row, `Also flagged on`
lists every other report tab whose `report_flags` entry names the facility, each link opening that tab
for the facility (UX-16). `guard: true` shows `—` in that column on a `too_few` row. The default sort is flagged, then too
few, then clean; within each, more `report_flags` entries first, then more patients, then name.
With `order: 'size'` the order within each group is `size` (high first), then name; `Stepping up` uses it to sort by
high-BP visits. Header clicks sort names A to Z and numbers high to low first; the chip resets.

## ECharts (tip.js)

```js
{{shared:tip.js}}
// ... read the frame ...
tooltip: tip((k) => [fmt(n[k]) + ' readings'], (k) => labels[k], { axisPointer: { type: 'shadow' } }),
```

`tip(rowsFor, headFor, extra)` is the program dashboard's tooltip: dark card, bold header, then the
lines from `rowsFor(dataIndex, axisIndex)`. `headFor` defaults to the hovered axis label. Colours
are in `chartColors` (DESIGN tokens).
