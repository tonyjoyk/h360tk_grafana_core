// --- Reports shared facility table (dashboard_src/reports/_shared/table.js) ---
// Declares one name: rptTable. Needs states.js (rpt) included first. DESIGN "Shared facility table".
//
// rptTable(root, {
//   report: 'fudging',                  // this tab's report key (report_flags.report)
//   rows: [...],                        // report_<name> rows; the selection row comes first
//   flags: [...],                       // optional report_flags rows; default: each row's flags_json column
//                                       // (one result set: a panel with two queries gets Business Text's frame picker)
//   columns: [{ label, value: (r) => sortable, cell: (r) => html, num: true, guard: true, title: (r) => text }],
//   flagNames: (r) => ['Pill text'],    // flag pill(s) of a flagged row, at most two shown
//   reason: (r) => r.flag_reason,       // optional; sentence under the pills
//   guardName: 'Too few readings',      // grey pill of a too_few row
//   guardReason: (r) => 'Need at least 20; this place has 12.',
//   check: { text: '◆ Looks fine, check readings', when: (r) => rpt.yes(r.looks_fine_check) },  // optional two-sided pill
//   alsoOn: false,                      // optional; false hides `Also flagged on …`. Default: every other report
//                                       // that flags this facility in report_flags (UX-16). An array is ignored.
//   nameLinks: false,                   // optional; false keeps facility names as plain text. Default: each name
//                                       // links to this tab narrowed to that facility (UX-15).
//   size: (r) => r.readings_n,          // patients or cases in scope, the last sort key
//   order: 'size',                      // optional; within flagged / too few / clean, sort by size (high first)
//                                       // instead of number of report_flags entries, then patients
//   caption: 'Facilities in view, flagged first',
// })
// 10 rows per page with the overdue list's pager (shown whenever there are rows, as on the overdue list).
// Facility is the first column and `Why look here` the last; columns sit between them.
// A row whose level is under 3 and is_selected is drawn as the bold `All places in view` row and stays on top.
const rptTable = (root, cfg) => {
  const { esc, fmt, num, yes } = rpt;
  const PAGE = 10;
  const all = (cfg.rows || []).filter((r) => r && r.org_unit_id != null);
  const isTotal = (r) => yes(r.is_selected) && (num(r.level) || 0) < 3;
  const total = all.find(isTotal) || null;
  const rows = all.filter((r) => r !== total);
  if (!all.length) { root.innerHTML = rpt.noData(rpt.NO_FACILITIES); return; }

  // report_flags per facility: { id: [{report, flag_reason, patients_n}] }
  const flagsOf = {};
  (cfg.flags || rpt.flagsFrom(all)).forEach((f) => { (flagsOf[f.org_unit_id] = flagsOf[f.org_unit_id] || []).push(f); });
  const nFlags = (r) => (flagsOf[r.org_unit_id] || []).length;
  const patients = (r) => { const f = (flagsOf[r.org_unit_id] || [])[0]; return f && num(f.patients_n) !== null ? num(f.patients_n) : (cfg.size ? num(cfg.size(r)) || 0 : 0); };
  // 0 flagged, 1 too few, 2 clean.
  const rank = (r) => (yes(r.flag) ? 0 : yes(r.too_few) ? 1 : 2);
  const sizeOf = (r) => (cfg.size ? num(cfg.size(r)) || 0 : 0);
  const needsALook = (a, b) => rank(a) - rank(b)
    || (cfg.order === 'size' ? sizeOf(b) - sizeOf(a) : nFlags(b) - nFlags(a) || patients(b) - patients(a))
    || String(a.org_unit_name).localeCompare(String(b.org_unit_name));

  const FACILITY = { label: 'Facility', value: (r) => String(r.org_unit_name || '') };
  const WHY = { label: 'Why look here', value: (r) => rank(r) };
  const cols = [FACILITY].concat(cfg.columns || [], [WHY]);
  const state = { sort: -1, dir: 1, page: 0 };   // sort -1 = needs a look first

  const pill = (cls, text) => '<span class="rpt-pill ' + cls + '">' + esc(text) + '</span>';
  // `Also flagged on`: every other report tab that flags this facility in report_flags, in tab order.
  // Each link opens that tab for this facility.
  const also = (r) => {
    if (cfg.alsoOn === false) { return ''; }
    const mine = flagsOf[r.org_unit_id] || [];
    const links = rpt.REPORTS.filter((t) => t.report !== cfg.report && mine.some((f) => f.report === t.report))
      .map((t) => '<a class="rpt-link" href="' + esc(rpt.link(t.report, r.org_unit_id)) + '">' + esc(t.title) + '</a>');
    return links.length ? '<div class="rpt-also">Also flagged on ' + links.join(', ') + '</div>' : '';
  };
  const name = (r) => (cfg.nameLinks === false ? esc(r.org_unit_name) : rpt.placeLink(cfg.report, r.org_unit_id, r.org_unit_name));
  const why = (r, totalRow) => {
    if (yes(r.flag)) {
      const names = [].concat(cfg.flagNames ? cfg.flagNames(r) : []).filter(Boolean).slice(0, 2);
      const check = !totalRow && cfg.check && cfg.check.when(r) ? pill('rpt-pill-check', cfg.check.text) : '';
      const reason = cfg.reason ? cfg.reason(r) : r.flag_reason;
      return '<div class="rpt-pills">' + check + names.map((n) => pill('rpt-pill-flag', n)).join('') + '</div>'
        + (reason ? '<div class="rpt-reason">' + esc(reason) + '</div>' : '') + (totalRow ? '' : also(r));
    }
    if (yes(r.too_few)) {
      return '<div class="rpt-pills">' + pill('rpt-pill-guard', cfg.guardName || 'Too few') + '</div>'
        + (cfg.guardReason ? '<div class="rpt-reason">' + esc(cfg.guardReason(r)) + '</div>' : '');
    }
    return '<span class="rpt-clean">No flag</span>';
  };
  const cell = (c, r) => (c.guard && yes(r.too_few) ? '—' : c.cell ? c.cell(r) : esc(c.value(r)));
  const tr = (r, totalRow) => '<tr class="' + (totalRow ? 'rpt-total' : rank(r) === 0 ? 'rpt-flagged' : '') + '">'
    + '<th scope="row">' + (totalRow ? 'All places in view' : name(r)) + '</th>'
    + (cfg.columns || []).map((c) => '<td class="' + (c.num ? 'num' : '') + '"' + (c.title && c.title(r) ? ' title="' + esc(c.title(r)) + '"' : '') + '>' + cell(c, r) + '</td>').join('')
    + '<td class="rpt-why">' + why(r, totalRow) + '</td></tr>';

  const sorted = () => {
    if (state.sort < 0) { return rows.slice().sort(needsALook); }
    const c = cols[state.sort];
    const key = (r) => (c.guard && yes(r.too_few) ? null : c.value(r));
    return rows.slice().sort((a, b) => {
      const x = key(a), y = key(b);
      if (x === null || x === undefined) { return y === null || y === undefined ? needsALook(a, b) : 1; }   // blanks last
      if (y === null || y === undefined) { return -1; }
      const d = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), 'en', { numeric: true });
      return state.dir * d || needsALook(a, b);
    });
  };

  const render = () => {
    const list = sorted();
    const pages = Math.max(1, Math.ceil(list.length / PAGE));
    state.page = Math.min(Math.max(state.page, 0), pages - 1);
    const shown = list.slice(state.page * PAGE, (state.page + 1) * PAGE);
    const head = cols.map((c, i) => {
      const on = state.sort === i;
      const aria = on ? (state.dir > 0 ? 'ascending' : 'descending') : 'none';
      return '<th scope="col" aria-sort="' + aria + '" class="' + (c.num ? 'num' : '') + '">'
        + '<button type="button" class="rpt-sortbtn" data-col="' + i + '">' + esc(c.label)
        + '<span class="rpt-sort" aria-hidden="true">' + (on ? (state.dir > 0 ? ' ↑' : ' ↓') : '') + '</span></button></th>';
    }).join('');
    const byNeed = state.sort < 0;
    root.innerHTML = '<div class="rpt-chips">'
      + '<button type="button" class="rpt-chip' + (byNeed ? ' on' : '') + '" data-reset="1" aria-pressed="' + byNeed + '">Sort: needs a look first</button></div>'
      + '<div class="rpt-wrap"><table class="rpt-table">'
      + '<caption class="rpt-sr">' + esc(cfg.caption || 'Facilities in view. Flagged facilities come first.') + '</caption>'
      + '<thead><tr>' + head + '</tr></thead><tbody>'
      + (total && rows.length ? tr(total, true) : '')
      + (shown.length ? shown.map((r) => tr(r, false)).join('') : total ? tr(total, false) : '')
      + '</tbody></table></div>'
      + (list.length ? '<div class="rpt-pager">'
        + '<button type="button" data-page="-1"' + (state.page ? '' : ' disabled') + ' aria-label="Previous page">‹</button>'
        + '<span>' + fmt(state.page * PAGE + 1) + '–' + fmt(state.page * PAGE + shown.length) + ' of ' + fmt(list.length) + '</span>'
        + '<button type="button" data-page="1"' + (state.page < pages - 1 ? '' : ' disabled') + ' aria-label="Next page">›</button></div>' : '');
  };
  render();

  root.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b || !root.contains(b)) { return; }
    let focus = null;
    if (b.dataset.reset) { state.sort = -1; state.dir = 1; state.page = 0; focus = '[data-reset]'; }
    else if (b.dataset.page) { state.page += Number(b.dataset.page); focus = '[data-page="' + b.dataset.page + '"]'; }
    else if (b.dataset.col) {
      const i = Number(b.dataset.col);
      // First click: names A to Z, numbers high to low; a second click flips it.
      state.dir = state.sort === i ? -state.dir : (cols[i].num ? -1 : 1);
      state.sort = i; state.page = 0; focus = '[data-col="' + i + '"]';
    } else { return; }
    render();
    const f = focus && root.querySelector(focus);
    if (f && !f.disabled) { f.focus(); }
  });
};
