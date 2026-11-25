// --- Screening and treatment cascades (story 14.2, AD-51) (dashboard_src/cascade/cascade.js) ---
// Declares one name: cascade. Self-contained. Built from HTN_Cascades_Indonesia_India_Ethiopia.html
// and the UX audit of 2026-11-18 (ux-audit-2026-11-18.md): one denominator per chart (its first
// bar), large colored percents above the bars, exact black counts, descriptive grey labels, thin
// column lines, and in the screening chart only, a second percent under each label: the share of
// the step before ("9% of screened"). No target lines (owner, 2026-11-26).
// Names and step 4 come from COUNTRIES, so a new country needs a new entry, not new code.
// scripts/build_cascade_panel.py pastes this file into panel-stc on the Hypertension tab.
const cascade = (() => {
  const esc = (x) => String(x == null ? '' : x).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (x) => (x === null || x === undefined || x === '' || isNaN(Number(x)) ? null : Number(x));
  const fmt = (x) => (num(x) === null ? '–' : Math.round(num(x)).toLocaleString('en-US'));
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const H = 120; // plot height in px
  const IN = 28; // a bar at least this tall holds its percent inside
  const pctTxt = (p) => (!isFinite(p) ? '–' : p >= 10 ? Math.round(p) + '%' : (Math.round(p * 10) / 10) + '%');
  const COLOR = { eligible: 'base', screened: 'screen', raised: 'raised', linked: 'link', diagnosed: 'start' };

  // One entry per country (the five-slot standard, HTN_Cascades_Design_Decisions.md). The meaning of
  // each slot is fixed; the names, base, year start and step 4 change by country.
  //   who     who the screening chart counts, for its subtitle
  //   labels  the descriptive name under each bar
  //   short   the name after "x% of ..." in the step-before line
  // Step 4 (linked) shows only when the panel query returns a value for it (not NULL).
  // To switch country, change ACTIVE.
  const COUNTRIES = {
    idn: {
      name: 'Indonesia', ageGroup: '15+', who: 'Eligible adults (15+)', yearStartMonth: 1,
      labels: { eligible: 'Adults eligible for screening', screened: 'Adults screened', raised: 'Raised BP (140/90 or higher)', linked: 'Given starter medicine', diagnosed: 'Diagnosed with hypertension this year' },
      short: { eligible: 'eligible', screened: 'screened', raised: 'raised BP', linked: 'given starter medicine', diagnosed: 'diagnosed' },
    },
    ind: {
      name: 'India', ageGroup: '30+', who: 'Eligible adults (30+) not on treatment', yearStartMonth: 4,
      labels: { eligible: 'Adults eligible for screening', screened: 'Adults screened', raised: 'Referred (raised BP)', linked: 'Examined by MO', diagnosed: 'Diagnosed with hypertension this year' },
      short: { eligible: 'eligible', screened: 'screened', raised: 'referred', linked: 'examined', diagnosed: 'diagnosed' },
    },
    eth: {
      name: 'Ethiopia', ageGroup: '30+', who: 'Adult OPD visits without known hypertension', yearStartMonth: 7,
      labels: { eligible: 'OPD visits eligible for screening', screened: 'Visits with BP measured', raised: 'Raised BP (140/90 or higher)', linked: 'Linked to NCD clinic', diagnosed: 'Diagnosed with hypertension this year' },
      short: { eligible: 'eligible', screened: 'screened', raised: 'raised BP', linked: 'linked', diagnosed: 'diagnosed' },
    },
  };
  const ACTIVE = 'idn';
  const settings = (code) => COUNTRIES[code || ACTIVE];

  // Reporting month 'YYYY-MM-DD' to {y, m} (m is 1 to 12).
  const ym = (s) => { const p = String(s || '').split('-'); return { y: Number(p[0]), m: Number(p[1]) }; };
  // "Jan to Oct 2026", or "Apr 2026 to Feb 2027" when the year crosses January.
  const periodText = (month, startMonth) => {
    const { y, m } = ym(month);
    const s = Number(startMonth) || 1;
    const sy = m >= s ? y : y - 1;
    return sy === y ? MON[s - 1] + ' to ' + MON[m - 1] + ' ' + y : MON[s - 1] + ' ' + sy + ' to ' + MON[m - 1] + ' ' + y;
  };

  // One bar. The first bar is the denominator: grey, 100% inside. Other bars show their share of
  // the first bar, inside when the bar is tall enough, otherwise just above it. Bars fill their
  // column edge to edge.
  const bar = (b, base, isBase) => {
    const p = base > 0 ? b.v / base * 100 : 0;
    const px = H * p / 100;
    const inside = isBase || px >= IN;
    const h = isBase ? '100%' : (px < 3 ? (b.v > 0 ? '3px' : '0') : Math.min(p, 100) + '%');
    const label = isBase ? '100%' : pctTxt(p);
    const color = isBase ? 'var(--csc-baseInk)' : inside ? '#fff' : 'var(--csc-' + b.c + ')';
    const pct = '<span class="' + (inside ? 'csc-in' : 'csc-up') + '" style="color:' + color + '">' + label + '</span>';
    return '<div class="csc-col">'
      + (inside ? '' : pct) + '<div class="csc-bar" style="height:' + h + ';background-color:var(--csc-' + b.c + ')">' + (inside ? pct : '') + '</div></div>';
  };

  // One chart: title, a two-line subtitle, the bars, then count, label and an optional status line.
  const half = (o) => {
    const body = o.empty ? '<div class="csc-empty">' + esc(o.empty) + '</div>'
      : '<div class="csc-scroll"><div class="csc-plot"><div class="csc-chart"><div class="csc-bars">' + o.bars.map((b, i) => bar(b, o.base, i === 0)).join('') + '</div></div>'
        + '<div class="csc-meta">' + o.bars.map((b) => '<div>'
          + '<div class="csc-n">' + fmt(b.v) + '</div><div class="csc-l">' + esc(b.label) + '</div>'
          + (b.line ? '<div class="csc-s"><span class="csc-s-n" style="color:var(--csc-' + b.c + ')">' + esc(b.line.pct) + '</span> ' + esc(b.line.word) + '</div>' : '')
          + '</div>').join('') + '</div></div></div>';
    return '<div class="csc-half"><h3>' + esc(o.title) + '</h3><p class="csc-sub">' + esc(o.sub)
      + (o.legend && !o.empty ? '<span class="csc-legend">' + esc(o.legend) + '</span>' : '') + '</p>' + body
      + (o.warn ? '<div class="csc-warn">' + esc(o.warn) + '</div>' : '') + '</div>';
  };

  // The screening slots. The bar percent is always a share of the first bar. Every bar after
  // "screened" adds the share of the bar just before it ("9% of screened"). Step 4 (linked) shows
  // only when the query has a value for it.
  const screeningBars = (c, d) => {
    const base = num(d.adults) || 0;
    const keys = ['eligible', 'screened', 'raised', 'linked', 'diagnosed'].filter((k) => k !== 'linked' || num(d.linked) !== null);
    const warns = [];
    let prev = null;
    const bars = keys.map((k) => {
      const v = k === 'eligible' ? base : (num(d[k]) || 0);
      const b = { k, label: c.labels[k], v, c: COLOR[k] };
      if (prev && prev.k !== 'eligible') {
        b.line = { pct: pctTxt(prev.v > 0 ? v / prev.v * 100 : NaN), word: 'of ' + c.short[prev.k] };
        if (v > prev.v) warns.push(b.label + ' (' + fmt(v) + ') is bigger than ' + prev.label + ' (' + fmt(prev.v) + '). Check the numbers.');
      }
      prev = b;
      return b;
    });
    return { bars, base, warns };
  };

  // Draws both charts into root from the panel's one row of numbers (dashboard_src/cascade/panel.sql).
  const draw = (root, d) => {
    const c = settings();
    const { y, m } = ym(d.reporting_month);
    const asOf = MON[m - 1] + ' ' + y;
    const place = d.place ? 'in ' + d.place : 'in all locations';
    const hasScreening = (num(d.screening_rows) || 0) > 0;
    const hasBase = (num(d.adults) || 0) > 0;
    const s = screeningBars(c, d);
    const scr = half({
      title: 'Screening cascade',
      sub: c.who + ' ' + place + ' screened and diagnosed, ' + periodText(d.reporting_month, c.yearStartMonth) + '.',
      base: s.base, bars: s.bars,
      empty: !hasScreening ? 'No screening data for this place and month.'
        : !hasBase ? 'No population data for this place, so there is no base for the percentages.' : '',
      warn: hasScreening && hasBase ? s.warns.join(' ') : '',
    });
    const est = num(d.estimated);
    const reg = num(d.registered) || 0;
    const care = num(d.under_care) || 0;
    const ctrl = num(d.controlled) || 0;
    const trt = half({
      title: 'Treatment cascade',
      sub: 'Estimated adults (' + c.ageGroup + ') ' + place + ' with hypertension, as of ' + asOf + '.',
      base: est || 0,
      bars: [
        { k: 'est', v: est || 0, label: 'Estimated people with hypertension', c: 'base' },
        { k: 'reg', v: reg, label: 'Cumulative registered patients', c: 'reg' },
        { k: 'care', v: care, label: 'Patients under care', c: 'care' },
        { k: 'ctrl', v: ctrl, label: 'Patients with BP controlled', c: 'ctrl' },
      ],
      empty: est ? '' : 'No population data for this place, so there is no estimate. Registered: ' + fmt(reg) + '. Under care: ' + fmt(care) + '. BP controlled: ' + fmt(ctrl) + '.',
    });
    root.innerHTML = '<div class="csc-card">' + scr + '<div class="csc-divider"></div>' + trt + '</div>';
  };
  return { draw, periodText, settings, COUNTRIES, ACTIVE };
})();
