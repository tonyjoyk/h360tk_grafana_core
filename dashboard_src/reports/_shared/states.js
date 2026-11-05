// --- Reports shared helpers and states (dashboard_src/reports/_shared/states.js) ---
// Declares one name: rpt. Business Text afterRender only (it reads context.grafana).
const rpt = (() => {
  const grafana = (typeof context !== 'undefined' && context.grafana) || {};
  const v = (name) => (grafana.replaceVariables ? String(grafana.replaceVariables('${' + name + '}')) : '');

  const esc = (x) => String(x == null ? '' : x).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (x) => (x === null || x === undefined || x === '' || isNaN(Number(x)) ? null : Number(x));
  // Thousands commas.
  const fmt = (x) => (num(x) === null ? '—' : Math.round(num(x)).toLocaleString('en-US'));
  // Percent: whole, one decimal under 10% (DESIGN Typography).
  const pct = (x) => { const n = num(x); if (n === null) { return '—'; } return (Math.abs(n) < 10 ? n.toFixed(1) : String(Math.round(n))) + '%'; };
  // Scores: two decimals.
  const score = (x) => (num(x) === null ? '—' : num(x).toFixed(2));
  const yes = (x) => x === true || x === 1 || x === 't' || x === 'true';

  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  // Postgres dates arrive as ms numbers or 'YYYY-MM-DD' strings; read them as UTC days.
  const toDate = (x) => { if (x == null || x === '') { return null; } const d = typeof x === 'number' ? new Date(x) : new Date(String(x).slice(0, 10) + 'T00:00:00Z'); return isNaN(d) ? null : d; };
  const day = (x) => { const d = toDate(x); return d ? d.getUTCDate() + '-' + MONTHS[d.getUTCMonth()] + '-' + d.getUTCFullYear() : ''; };
  const month = (x) => { const d = toDate(x); return d ? MONTHS[d.getUTCMonth()] + '-' + d.getUTCFullYear() : ''; };

  // Rows of the frame with refId ref, as objects.
  const rows = (ref) => {
    const series = (context.panelData && context.panelData.series) || [];
    const f = series.find((s) => s.refId === ref);
    if (!f) { return []; }
    const cols = f.fields.map((x) => [x.name, Array.from(x.values)]);
    const n = cols.length ? cols[0][1].length : 0;
    return Array.from({ length: n }, (_, i) => Object.fromEntries(cols.map(([k, vals]) => [k, vals[i]])));
  };

  // report_flags rows from a flags_json column (json_agg of {report, flag_reason, patients_n}) on each row.
  const flagsFrom = (list) => [].concat(...(list || []).map((r) => {
    let parsed = [];
    try { parsed = r.flags_json ? JSON.parse(r.flags_json) : []; } catch (e) { parsed = []; }
    return (Array.isArray(parsed) ? parsed : []).map((f) => Object.assign({ org_unit_id: r.org_unit_id, org_unit_name: r.org_unit_name }, f));
  }));

  // Variables, read in the browser so no access query is needed.
  const orgUnit = () => { const o = v('org_unit').trim(); return o && o !== '0' ? o : '0'; };
  const reportingMonth = () => v('reporting_month');
  const allowed = () => v('isAllowed') === '1';

  // Tabs from the builder's TABS list: [{report, title, slug}].
  const TABS = {{tabs}};
  const tab = (report) => TABS.find((t) => t.report === report) || null;
  // AD-29 deep link; keeps the location and month unless given.
  const link = (report, org, mon) => {
    const t = tab(report);
    return t ? '/d/heart360_reports?var-org_unit=' + encodeURIComponent(org == null ? orgUnit() : org)
      + '&var-reporting_month=' + encodeURIComponent(mon == null ? reportingMonth() : mon) + '&-dtab=' + encodeURIComponent(t.slug) : '';
  };

  // --- States (DESIGN States, FR-32) ---
  // Existing HTN access banner, verbatim (program dashboard overdue list).
  const banner = () => '<div class="rpt-warn"><span>⚠️</span><span><strong>Access Denied:</strong> Ask admin to add to one of these teams: ' + v('requiredGroups') + '</span></div>';
  const NO_DATA = 'No data for this place.';
  const NO_FACILITIES = 'No facilities for this location.';
  const NO_FLAGS = 'No facility is flagged.';
  const noData = (text) => '<div class="rpt-empty">' + esc(text || NO_DATA) + '</div>';
  // "Need at least 20; this place has 12."
  const needAtLeast = (k, n) => 'Need at least ' + fmt(k) + '; this place has ' + fmt(n) + '.';
  // Place for the subtitle: the selected name, or all locations.
  const place = (name) => (orgUnit() === '0' ? 'All locations you can access' : (name || 'This place'));

  // Thresholds from report_flag_thresholds rows ({report, key, value}).
  const thresholds = (list) => { const t = {}; (list || []).forEach((r) => { t[r.report + '.' + r.key] = num(r.value); }); return t; };

  // Mount: returns the root element, or null when access is denied. The banner is drawn once per tab,
  // by the panel mounted with { banner: true } (the title strip); other panels stay empty under it.
  const mount = (selector, opts) => {
    const root = context.element.querySelector(selector);
    if (!root) { return null; }
    if (!allowed()) { root.innerHTML = opts && opts.banner ? banner() : ''; return null; }
    return root;
  };

  return { v, esc, num, fmt, pct, score, yes, day, month, toDate, rows, orgUnit, reportingMonth, allowed,
    TABS, tab, link, flagsFrom, banner, NO_DATA, NO_FACILITIES, NO_FLAGS, noData, needAtLeast, place, thresholds, mount };
})();
