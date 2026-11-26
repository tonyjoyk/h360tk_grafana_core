// --- Reports shared monthly table (dashboard_src/reports/_shared/monthly.js) ---
// Declares one name: rptMonthly. Needs states.js (rpt) included first. Business Text afterRender only.
// The Metabase monthly form (titration, statins): one row per month, oldest first, the place in view
// beside the average of all places. The newest month is bold; it equals the tab's headline.
//
// rptMonthly(root, {
//   rows: rpt.rows('A'),                 // report_<name>_monthly rows WHERE is_selected, by month_date
//   place: 'District-D',                 // name over the place columns
//   cols: [                              // the same columns for the place and the average
//     { label: 'High-BP visits', place: 'follow_up_n', avg: 'average_follow_up_n' },
//     { label: 'Stepped up', place: 'titrated_n', avg: 'average_titrated_n' },
//     { label: 'Rate', place: 'rate_pct', avg: 'average_rate_pct', pct: true, of: [1, 0] },  // of: [n col, d col]
//   ],
//   tooFew: 'Too few visits',            // shown in the place's percent cell of a too_few month
//   caption: 'Stepped up by month, ...',
// })
const rptMonthly = (root, cfg) => {
  const { esc, fmt, num, yes } = rpt;
  const rows = (cfg.rows || []).slice().sort((a, b) => (rpt.toDate(a.month_date) || 0) - (rpt.toDate(b.month_date) || 0));
  if (!rows.length) { root.innerHTML = rpt.noData(); return; }
  const cols = cfg.cols || [];
  const cell = (r, c, side, first) => {
    const key = c[side];
    const cls = 'num' + (first ? ' rpt-mt-gap' : '');
    if (!c.pct) { return '<td class="' + cls + '">' + fmt(r[key]) + '</td>'; }
    if (side === 'place' && yes(r.too_few)) {
      return '<td class="' + cls + '"><span class="rpt-mt-few" title="' + esc(cfg.tooFew || 'Too few') + '">—</span></td>';
    }
    const n = c.of ? r[cols[c.of[0]][side]] : null, d = c.of ? r[cols[c.of[1]][side]] : null;
    const title = num(r[key]) === null ? '' : String(num(r[key])) + '%' + (c.of ? ' · ' + fmt(n) + ' of ' + fmt(d) : '');
    return '<td class="' + cls + '"' + (title ? ' title="' + esc(title) + '"' : '') + '>' + rpt.pct(r[key]) + '</td>';
  };
  const n = cols.length;
  root.innerHTML = '<div class="rpt-wrap"><table class="rpt-table rpt-mt">'
    + '<caption class="rpt-sr">' + esc(cfg.caption || 'By month, against the average of all places.') + '</caption>'
    + '<thead><tr class="rpt-mt-group"><th scope="col"></th>'
    + '<th scope="colgroup" colspan="' + n + '" class="rpt-mt-place rpt-mt-gap">' + esc(cfg.place) + '</th>'
    + '<th scope="colgroup" colspan="' + n + '" class="rpt-mt-avg rpt-mt-gap">Average of all places</th></tr>'
    + '<tr><th scope="col">Month</th>'
    + ['place', 'avg'].map((side) => cols.map((c, i) => '<th scope="col" class="num' + (i ? '' : ' rpt-mt-gap') + '">' + esc(c.label) + '</th>').join('')).join('')
    + '</tr></thead><tbody>'
    + rows.map((r, k) => '<tr' + (k === rows.length - 1 ? ' class="rpt-mt-last"' : '') + '><th scope="row">' + esc(rpt.month(r.month_date)) + '</th>'
      + cols.map((c, i) => cell(r, c, 'place', !i)).join('') + cols.map((c, i) => cell(r, c, 'avg', !i)).join('') + '</tr>').join('')
    + '</tbody></table></div>';
};
