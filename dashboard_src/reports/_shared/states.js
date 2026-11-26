// --- Reports shared helpers and states (dashboard_src/reports/_shared/states.js) ---
// Declares one name: rpt. Business Text afterRender only (it reads context.grafana).
const rpt = (() => {
  const grafana = (typeof context !== 'undefined' && context.grafana) || {};
  // A variable's value; '' when the dashboard has no such variable (replaceVariables leaves `${name}`).
  const v = (name) => { const x = grafana.replaceVariables ? String(grafana.replaceVariables('${' + name + '}')) : ''; return x === '${' + name + '}' ? '' : x; };

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

  // The user's home unit (hidden variable home_org_unit, the home dashboard's UserOrgUnitId query).
  // '' for admins and users with access everywhere.
  const homeUnit = () => { const h = v('home_org_unit').trim(); return h && h !== '0' ? h : ''; };

  // Tabs from the builder's TABS list: [{report, title, slug}], in tab order. TABS[0] is `Start here`.
  const TABS = {{tabs}};
  // The five report tabs (every tab but `Start here`), in tab order.
  const REPORTS = TABS.filter((t) => t.report !== 'start');
  const tab = (report) => TABS.find((t) => t.report === report) || null;
  // AD-29 deep link; keeps the location and month unless given. extra: more URL parameters,
  // for example { 'var-include_new': 'true' }.
  const link = (report, org, mon, extra) => {
    const t = tab(report);
    if (!t) { return ''; }
    const more = Object.keys(extra || {}).map((k) => '&' + encodeURIComponent(k) + '=' + encodeURIComponent(extra[k])).join('');
    return '/d/heart360_reports?var-org_unit=' + encodeURIComponent(org == null ? orgUnit() : org)
      + '&var-reporting_month=' + encodeURIComponent(mon == null ? reportingMonth() : mon) + more + '&-dtab=' + encodeURIComponent(t.slug);
  };
  // A facility name that narrows this tab to that facility (UX-15). Plain text when it is already the place in view.
  const placeLink = (report, id, name) => (id == null || String(id) === orgUnit() || !tab(report)
    ? esc(name) : '<a class="rpt-link" href="' + esc(link(report, id)) + '" title="' + esc('Show ' + name + ' only') + '">' + esc(name) + '</a>');
  // `Next step` line at the end of a tab: one link, sentence case.
  const nextStep = (text, href) => '<div class="rpt-next"><span class="rpt-next-label">Next step</span>'
    + '<a class="rpt-link" href="' + esc(href) + '">' + esc(text) + ' →</a></div>';
  // Same-page links: an <a href="#some-id"> inside el scrolls the element with that id into view
  // (Grafana scrolls its own pane, so a plain hash link does not move it). Use with nextStep('...', '#id').
  // Grafana draws panels lazily: while the target is not drawn yet, the pane scrolls down a screen at a
  // time until it appears.
  const wireScroll = (el) => {
    if (!el || el.__rptScroll) { return; }
    el.__rptScroll = true;
    const pane = (node) => { let p = node.parentElement; while (p && !(p.scrollHeight > p.clientHeight && /auto|scroll/.test(getComputedStyle(p).overflowY))) { p = p.parentElement; } return p; };
    el.addEventListener('click', (e) => {
      const a = e.target.closest && e.target.closest('a[href^="#"]');
      if (!a || !el.contains(a)) { return; }
      e.preventDefault();
      const id = a.getAttribute('href').slice(1);
      const box = pane(el);
      let tries = 0;
      const go = () => {
        const t = document.getElementById(id);
        if (t) { t.scrollIntoView({ behavior: 'smooth', block: 'start' }); return; }
        if (!box || tries++ > 8) { return; }
        box.scrollTop += Math.round(box.clientHeight * 0.8);
        setTimeout(go, 350);
      };
      go();
    });
  };
  // Medicine stock board for the place and month in view.
  const stockHref = () => '/d/heart360_drug_stock?' + (orgUnit() !== '0' ? 'var-org_unit=' + encodeURIComponent(orgUnit()) + '&' : '')
    + 'var-reporting_month=' + encodeURIComponent(reportingMonth());
  // The program dashboard's Overdue list tab for a facility.
  const overdueHref = (id) => '/d/heart360_showcase?var-org_unit=' + encodeURIComponent(id) + '&-dtab=Overdue-list';
  // At or below the facility level (selected_level 3 or more): patient lists and the overdue list work here.
  const atFacility = () => (num(v('selected_level')) || 0) >= 3;

  // --- States (DESIGN States, FR-32) ---
  // Grey note, no warning tone (Voice rule 8, UX-21). html is trusted markup; use esc() on data.
  const info = (html) => '<div class="rpt-info">' + html + '</div>';
  // No access: plain words and the next step. The access team names sit in a closed `Details` for the admin.
  const banner = () => {
    const teams = v('requiredGroups').replace(/<[^>]*>/g, '').trim();
    return info('<span>You cannot see this place. Pick your own area in <strong>Change location</strong> above.</span>'
      + (teams ? '<details class="rpt-details"><summary>Details for your admin</summary>Access comes from: ' + esc(teams) + '</details>' : ''));
  };
  // Shown while the page moves a user with no location to their home unit (UX-02).
  const OPENING_HOME = 'Opening your area…';
  // For views that need one facility (patient lists): a grey line with the next step.
  const PICK_FACILITY = 'Pick a facility in Change location above to see its patients.';
  const NO_DATA = 'No data for this place.';
  const NO_FACILITIES = 'No facilities for this location.';
  const noData = (text) => '<div class="rpt-empty">' + esc(text || NO_DATA) + '</div>';
  // "Need at least 20; this place has 12."
  const needAtLeast = (k, n) => 'Need at least ' + fmt(k) + '; this place has ' + fmt(n) + '.';
  // Place for the subtitle: the selected name, or all locations.
  const place = (name) => (orgUnit() === '0' ? 'All locations you can access' : (name || 'This place'));
  // One column of a headline strip: big number, label, muted lines; few greys the number.
  const col = (big, color, label, lines, title, few) => '<div' + (title ? ' title="' + esc(title) + '"' : '') + '>'
    + '<div class="rpt-big' + (few ? ' rpt-few' : '') + '"' + (color ? ' style="color:' + color + '"' : '') + '>' + esc(big) + '</div>'
    + '<div class="rpt-label">' + esc(label) + '</div>' + [].concat(lines).filter(Boolean).map((l) => '<div class="rpt-line">' + esc(l) + '</div>').join('') + '</div>';

  // UX-02: a user with no location who may not see all places is moved to their home unit, keeping
  // the month and tab. Returns true when it does so.
  const goHome = () => {
    const home = homeUnit();
    if (allowed() || orgUnit() !== '0' || !home) { return false; }
    // Several panels call this on one render; move once (a later blank pick moves again).
    if (Date.now() - (window.__rptGoHome || 0) > 3000) {
      window.__rptGoHome = Date.now();
      const ls = grafana.locationService;
      if (ls && ls.partial) { ls.partial({ 'var-org_unit': home }, true); }
      else { const u = new URL(window.location.href); u.searchParams.set('var-org_unit', home); window.location.replace(u.toString()); }
    }
    return true;
  };
  // True while the panel's query is still running.
  const loading = () => !!(context.panelData && context.panelData.state === 'Loading');

  // Mount: returns the root element, or null when access is denied. The banner is drawn once per tab,
  // by the panel mounted with { banner: true } (the title strip); other panels stay empty under it.
  // A user with no location is first moved to their home unit (UX-02); meanwhile the banner panel
  // shows `Opening your area…`. opts.loading: a line to show while the query runs (null is returned).
  const mount = (selector, opts) => {
    const o = opts || {};
    const root = context.element.querySelector(selector);
    if (!root) { return null; }
    if (goHome()) { root.innerHTML = o.banner ? '<div class="rpt-muted">' + esc(OPENING_HOME) + '</div>' : ''; return null; }
    if (!allowed()) { root.innerHTML = o.banner ? banner() : ''; return null; }
    if (o.loading && loading()) { root.innerHTML = '<div class="rpt-muted rpt-loading">' + esc(o.loading) + '</div>'; return null; }
    return root;
  };

  return { v, esc, num, fmt, pct, score, yes, day, month, toDate, rows, orgUnit, reportingMonth, allowed, homeUnit,
    TABS, REPORTS, tab, link, placeLink, nextStep, stockHref, overdueHref, wireScroll, atFacility, flagsFrom, info, banner, OPENING_HOME, PICK_FACILITY,
    NO_DATA, NO_FACILITIES, noData, needAtLeast, place, col, loading, goHome, mount };
})();
