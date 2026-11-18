// --- Screening and treatment cascades (story 14.2, AD-51) (dashboard_src/cascade/cascade.js) ---
// Declares one name: cascade. Self-contained. Built from HTN_Cascades_Indonesia_India_Ethiopia.html
// and the UX audit of 2026-11-18 (ux-audit-2026-11-18.md): one denominator per chart (its first
// bar), large colored percents above the bars, exact black counts, descriptive grey labels, thin
// column lines, and in the screening chart only, a grey line for the step rate ("9% of screened").
// Names, targets and step 4 come from COUNTRIES, so a new country needs a new entry, not new code.
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
  // each slot is fixed; the names, base, year start, targets and step 4 change by country.
  //   who     who the screening chart counts, for its subtitle
  //   labels  the descriptive name under each bar
  //   short   the name after "x% of ..." in the step-rate line
  // To switch country, change ACTIVE. Targets are temporary front-end values until H360-499.
  const COUNTRIES = {
    idn: {
      name: 'Indonesia', ageGroup: '15+', who: 'Eligible adults (15+)', yearStartMonth: 1, targetType: 'year',
      labels: { eligible: 'Adults eligible for screening', screened: 'Adults screened', raised: 'Raised BP (140/90 or higher)', linked: 'Given starter medicine', diagnosed: 'Newly diagnosed with hypertension' },
      short: { eligible: 'eligible', screened: 'screened', raised: 'raised BP', linked: 'given medicine', diagnosed: 'diagnosed' },
      // Hidden for now (owner, 2026-11-18): set to true to show the starter medicine step again.
      showLinked: false, apart: { diagnosed: true },
      screenedTargetPct: 46, diagnosedGoalPct: 11.4,
    },
    ind: {
      name: 'India', ageGroup: '30+', who: 'Eligible adults (30+) not on treatment', yearStartMonth: 4, targetType: 'due',
      labels: { eligible: 'Adults eligible for screening', screened: 'Adults screened', raised: 'Referred (raised BP)', linked: 'Examined by MO', diagnosed: 'Newly diagnosed with hypertension' },
      short: { eligible: 'eligible', screened: 'screened', raised: 'referred', linked: 'examined', diagnosed: 'diagnosed' },
      showLinked: true, apart: { linked: true, diagnosed: true },
      screenedTargetPct: 66.7, diagnosedGoalPct: 12.6,
    },
    eth: {
      name: 'Ethiopia', ageGroup: '30+', who: 'Adult OPD visits without known hypertension', yearStartMonth: 7, targetType: 'year',
      labels: { eligible: 'OPD visits eligible for screening', screened: 'Visits with BP measured', raised: 'Raised BP (140/90 or higher)', linked: 'Linked to NCD clinic', diagnosed: 'Newly diagnosed with hypertension' },
      short: { eligible: 'eligible', screened: 'screened', raised: 'raised BP', linked: 'linked', diagnosed: 'diagnosed' },
      showLinked: true, apart: {},
      screenedTargetPct: 80, diagnosedGoalPct: null,
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
  // Months since the year started, 1 to 12, for targets that are due by month.
  const monthsIn = (month, startMonth) => { const { m } = ym(month); const s = Number(startMonth) || 1; return ((m - s + 12) % 12) + 1; };

  // One bar. The first bar is the denominator: grey, 100% inside. Other bars show their share of
  // the first bar, inside when the bar is tall enough, otherwise above it on a white pill (so it
  // stays readable over a target line). A target is a dashed line with a light tint, no label.
  const bar = (b, base, isBase) => {
    const p = base > 0 ? b.v / base * 100 : 0;
    const px = H * p / 100;
    const inside = isBase || px >= IN;
    const h = isBase ? '100%' : (px < 3 ? (b.v > 0 ? '3px' : '0') : Math.min(p, 100) + '%');
    const label = isBase ? '100%' : pctTxt(p);
    let t = '';
    if (b.target) {
      const tp = Math.min(b.target.p, 100);
      if (tp > p) { t += '<div class="csc-tzone" style="height:' + tp + '%;background:var(--csc-' + b.target.c + 'Tint)"></div>'; }
      t += '<div class="csc-tline" style="bottom:' + tp + '%;border-top-color:var(--csc-' + b.target.c + ')"></div>';
    }
    const color = isBase ? 'var(--csc-baseInk)' : inside ? '#fff' : 'var(--csc-' + b.c + ')';
    // A short bar under a target line: its percent sits just above the line, not on it.
    const over = !inside && b.target && Math.min(b.target.p, 100) > p;
    const lift = over ? ';position:absolute;left:0;right:0;text-align:center;bottom:calc(' + Math.min(b.target.p, 100) + '% + 3px)' : '';
    const pct = '<span class="' + (inside ? 'csc-in' : 'csc-up') + '" style="color:' + color + lift + '">' + label + '</span>';
    return '<div class="csc-col' + (b.apart ? ' csc-apart' : '') + '">' + t
      + (inside ? '' : pct) + '<div class="csc-bar" style="height:' + h + ';background-color:var(--csc-' + b.c + ')">' + (inside ? pct : '') + '</div></div>';
  };

  // One chart: title, a two-line subtitle, the bars, then count, label and an optional status line.
  const half = (o) => {
    const body = o.empty ? '<div class="csc-empty">' + esc(o.empty) + '</div>'
      : '<div class="csc-scroll"><div class="csc-plot"><div class="csc-chart"><div class="csc-bars">' + o.bars.map((b, i) => bar(b, o.base, i === 0)).join('') + '</div></div>'
        + '<div class="csc-meta">' + o.bars.map((b) => '<div class="' + (b.apart ? 'csc-apart' : '') + '">'
          + '<div class="csc-n">' + fmt(b.v) + '</div><div class="csc-l">' + esc(b.label) + '</div>'
          + (b.line ? '<div class="csc-s"' + (b.lineColor ? ' style="color:var(--csc-' + b.lineColor + ')"' : '') + '>' + esc(b.line) + '</div>' : '')
          + '</div>').join('') + '</div></div></div>';
    return '<div class="csc-half"><h3>' + esc(o.title) + '</h3><p class="csc-sub">' + esc(o.sub) + '</p>' + body
      + (o.warn ? '<div class="csc-warn">' + esc(o.warn) + '</div>' : '') + '</div>';
  };

  // The screening slots. The bar percent is always a share of the first bar. The status line is the
  // step rate ("9% of screened") or, on a bar with a target, the progress in the target color.
  const screeningBars = (c, d) => {
    const base = num(d.adults) || 0;
    const due = c.targetType === 'due';
    const monthName = MON[ym(d.reporting_month).m - 1];
    const share = due ? monthsIn(d.reporting_month, c.yearStartMonth) / 12 : 1;
    const keys = ['eligible', 'screened', 'raised', 'linked', 'diagnosed'].filter((k) => k !== 'linked' || c.showLinked);
    const target = { screened: c.screenedTargetPct, diagnosed: c.diagnosedGoalPct };
    const warns = [];
    let prev = null;
    const bars = keys.map((k) => {
      const v = k === 'eligible' ? base : (num(d[k]) || 0);
      const b = { k, label: c.labels[k], v, c: COLOR[k], apart: !!(c.apart || {})[k] };
      const tgt = num(target[k]);
      if (tgt !== null) {
        const tp = tgt * share;
        const want = tp / 100 * base;
        const word = k === 'diagnosed' ? 'goal' : 'target';
        b.target = { p: tp, c: k === 'diagnosed' ? 'start' : 'screen' };
        b.line = due ? fmt(Math.abs(v - want)) + (v < want ? ' behind ' : ' ahead of ') + monthName + ' ' + word
          : pctTxt(want > 0 ? v / want * 100 : NaN) + ' of ' + word;
        b.lineColor = b.target.c;
      } else if (prev && prev.k !== 'eligible' && !b.apart) {
        b.line = pctTxt(prev.v > 0 ? v / prev.v * 100 : NaN) + ' of ' + c.short[prev.k];
      }
      if (prev && prev.k !== 'eligible' && !b.apart && v > prev.v) {
        warns.push(b.label + ' (' + fmt(v) + ') is bigger than ' + prev.label + ' (' + fmt(prev.v) + '). Check the numbers.');
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
