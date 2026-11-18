// --- Screening and treatment cascades (story 14.3, AD-51) (dashboard_src/cascade/cascade.js) ---
// Declares one name: cascade. Self-contained. It copies bar(), half() and screeningBars() from
// HTN_Cascades_Indonesia_India_Ethiopia.html. Names, targets and step 4 come from the active
// cascade_settings row, so a new country needs a new row, not new code.
// scripts/build_cascade_panel.py pastes this file into panel-stc on the Hypertension tab.
const cascade = (() => {
  const esc = (x) => String(x == null ? '' : x).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (x) => (x === null || x === undefined || x === '' || isNaN(Number(x)) ? null : Number(x));
  const fmt = (x) => (num(x) === null ? '–' : Math.round(num(x)).toLocaleString('en-US'));
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const H = 210;
  const pctTxt = (p) => (!isFinite(p) ? '–' : p >= 10 ? Math.round(p) + '%' : (Math.round(p * 10) / 10) + '%');
  const lower = (t) => String(t || '').charAt(0).toLowerCase() + String(t || '').slice(1);
  const yes = (x) => x === true || x === 't' || x === 'true' || x === 1;
  const COLOR = { eligible: 'base', screened: 'screen', raised: 'raised', linked: 'link', diagnosed: 'start' };

  // One entry per country (the five-slot standard, HTN_Cascades_Design_Decisions.md). The meaning of
  // each slot is fixed; the names, base, year start, targets and step 4 change by country.
  // To switch country, change ACTIVE. To rename a step or change a target, edit the entry.
  // Targets are temporary front-end values until H360-499 stores them.
  const COUNTRIES = {
    idn: {
      name: 'Indonesia', ageGroup: '15+', baseText: 'adults aged 15+', yearStartMonth: 1, targetType: 'year',
      labels: { eligible: 'Eligible for screening', screened: 'Screened', raised: 'Raised BP', linked: 'Given starter medicine', diagnosed: 'Diagnosed with hypertension' },
      showLinked: true, apart: { diagnosed: 'EHR data' }, apartNote: { diagnosed: 'From EHR, not CKG' },
      screenedTargetPct: 46, diagnosedGoalPct: 11.4,
      info: 'Steps 1 to 4 come from CKG. Diagnosed counts new I10 registrations in puskesmas EHR data, a different system. Targets are for the full year.',
    },
    ind: {
      name: 'India', ageGroup: '30+', baseText: 'adults aged 30+ not on treatment on 1 April', yearStartMonth: 4, targetType: 'due',
      labels: { eligible: 'Eligible for screening', screened: 'Screened', raised: 'Referred (raised BP)', linked: 'Examined by MO', diagnosed: 'Diagnosed with hypertension' },
      showLinked: true, apart: { linked: 'At facility', diagnosed: 'At facility' }, apartNote: { linked: 'Includes walk-ins', diagnosed: 'Includes walk-ins' },
      screenedTargetPct: 66.7, diagnosedGoalPct: 12.6,
      info: 'All values come from NP-NCD reports. The year target is set on 1 April. Target lines show the share due by the end of the target month.',
    },
    eth: {
      name: 'Ethiopia', ageGroup: '30+', baseText: 'adult OPD visits by people without known hypertension', yearStartMonth: 7, targetType: 'year',
      labels: { eligible: 'Eligible for screening', screened: 'Screened', raised: 'Raised BP', linked: 'Linked to NCD clinic', diagnosed: 'Diagnosed with hypertension' },
      showLinked: true, apart: {}, apartNote: {},
      screenedTargetPct: 80, diagnosedGoalPct: null,
      info: 'Counts are OPD visits by adults without known hypertension, not unique people. All steps come from facility records.',
    },
  };
  const ACTIVE = 'idn';
  // The active country as the flat field names that screeningBars() and draw() read.
  const settings = (code) => {
    const c = COUNTRIES[code || ACTIVE];
    return {
      country_name: c.name, age_group: c.ageGroup, base_text: c.baseText, year_start_month: c.yearStartMonth, target_type: c.targetType,
      eligible_label: c.labels.eligible, screened_label: c.labels.screened, raised_label: c.labels.raised, linked_label: c.labels.linked, diagnosed_label: c.labels.diagnosed,
      show_linked: c.showLinked, linked_apart: c.apart.linked || null, diagnosed_apart: c.apart.diagnosed || null,
      linked_apart_note: c.apartNote.linked || null, diagnosed_apart_note: c.apartNote.diagnosed || null,
      screened_target_pct: c.screenedTargetPct, diagnosed_goal_pct: c.diagnosedGoalPct, screening_info: c.info,
    };
  };

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

  const clashes = (b, base) => {
    const p = b.v / base * 100;
    return H * p / 100 < 34 && b.target && b.target.p > p && (b.target.p - p) * 2.1 < 30;
  };
  const bar = (b, base, isBase) => {
    const p = base > 0 ? b.v / base * 100 : 0;
    const px = H * p / 100;
    const inside = isBase || px >= 34;
    const h = isBase ? '100%' : (px < 5 ? (b.v > 0 ? '5px' : '0') : Math.min(p, 100) + '%');
    const label = isBase ? '100%' : pctTxt(p);
    const txt = b.c === 'base' ? 'var(--csc-baseInk)' : '#fff';
    let t = '';
    if (b.target) {
      const tc = b.target.c || 'screen';
      const tp = Math.min(b.target.p, 100);
      if (tp > p) { t += '<div class="csc-tzone" style="bottom:0;height:' + tp + '%;background:var(--csc-' + tc + 'Tint)"></div>'; }
      t += '<div class="csc-tline" style="bottom:' + tp + '%;border-top-color:var(--csc-' + tc + ')"></div>'
        + '<div class="csc-tlab" style="bottom:calc(' + tp + '% + 4px);color:var(--csc-' + tc + ')">' + esc(b.target.label) + '</div>';
    }
    const above = !inside && !clashes(b, base) ? '<span class="csc-up" style="color:var(--csc-' + (b.c === 'base' ? 'baseInk' : b.c) + ')">' + label + '</span>' : '';
    const within = inside ? '<span class="csc-in" style="color:' + txt + '">' + label + '</span>' : '';
    const ap = b.apartFirst ? ' csc-apart" data-apart="' + esc(b.apart) : '';
    return '<div class="csc-col' + ap + '">' + t + above + '<div class="csc-bar" style="height:' + h + ';background-color:var(--csc-' + b.c + ')"' + (b.title ? ' title="' + esc(b.title) + '"' : '') + '>' + within + '</div></div>';
  };
  const axis = () => [0, 25, 50, 75].map((v) => '<div class="csc-gl" style="top:' + v + '%"></div>').join('')
    + [[0, '100%'], [25, '75%'], [50, '50%'], [75, '25%'], [100, '0%']].map(([t, l]) => '<div class="csc-yl" style="top:' + t + '%">' + l + '</div>').join('');
  const half = (o) => {
    // Compact text when five bars share the width, or when a count has 8 or more characters (2,100,000).
    const many = o.bars.length >= 5 || o.bars.some((x) => fmt(x.v).length >= 8) ? ' csc-many' : '';
    const body = o.empty ? '<div class="csc-empty">' + esc(o.empty) + '</div>'
      : '<div class="csc-scroll"><div class="csc-plot"><div class="csc-chart' + many + '">' + axis() + '<div class="csc-bars">' + o.bars.map((b, i) => bar(b, o.base, i === 0)).join('') + '</div></div>'
        + '<div class="csc-meta' + many + '">' + o.bars.map((b, i) => {
          const pp = i > 0 && clashes(b, o.base) ? ' <span class="csc-pp">' + pctTxt(b.v / o.base * 100) + '</span>' : '';
          const color = b.c === 'base' ? 'ink' : b.c;
          return '<div class="' + (b.apartFirst ? 'csc-apart' : '') + '"><div class="csc-n" style="color:var(--csc-' + color + ')">' + fmt(b.v) + pp + '</div>'
            + '<div class="csc-l">' + esc(b.label) + '</div>' + (b.steps || []).map((x) => '<div class="csc-s">' + esc(x) + '</div>').join('') + '</div>';
        }).join('') + '</div></div></div>';
    return '<div class="csc-half"><h3>' + esc(o.title) + (o.info ? ' <span class="csc-info" tabindex="0" title="' + esc(o.info) + '">i</span>' : '') + '</h3>'
      + '<span class="csc-period">' + esc(o.period) + '</span><p class="csc-sub">' + o.sub + '</p>' + body
      + (o.warn ? '<div class="csc-warn">' + esc(o.warn) + '</div>' : '') + (o.note ? '<p class="csc-note">' + esc(o.note) + '</p>' : '') + '</div>';
  };

  // The five screening slots from the settings row r and its counts.
  const screeningBars = (r) => {
    const base = num(r.adults) || 0;
    const due = r.target_type === 'due';
    const monthName = MON[ym(r.reporting_month).m - 1];
    const share = due ? monthsIn(r.reporting_month, r.year_start_month) / 12 : 1;
    const slots = [
      { k: 'eligible', label: r.eligible_label, v: base },
      { k: 'screened', label: r.screened_label, v: num(r.screened), tgt: num(r.screened_target_pct), short: 'screened' },
      { k: 'raised', label: r.raised_label, v: num(r.raised) },
      { k: 'linked', label: r.linked_label, v: num(r.linked), apart: r.linked_apart, note: r.linked_apart_note },
      { k: 'diagnosed', label: r.diagnosed_label, v: num(r.diagnosed), tgt: num(r.diagnosed_goal_pct), goal: true, apart: r.diagnosed_apart, note: r.diagnosed_apart_note },
    ].filter((s) => s.k !== 'linked' || yes(r.show_linked));
    const warns = [];
    let prev = null;
    let prevApart = null;
    const bars = slots.map((s) => {
      const b = { k: s.k, label: s.label, v: s.v || 0, c: COLOR[s.k], steps: [] };
      b.apart = s.apart || null;
      b.apartFirst = !!b.apart && b.apart !== prevApart;
      prevApart = b.apart;
      if (s.tgt !== null && s.tgt !== undefined) {
        const tp = s.tgt * share;
        const word = s.goal ? 'goal' : 'target';
        b.target = { p: tp, c: s.goal ? 'start' : 'screen',
          label: due ? 'Due by ' + monthName + ' ' + Math.round(tp) + '%' : 'Year ' + word + ' ' + Math.round(tp) + '%' };
      }
      if (prev && s.k !== 'screened') {
        if (b.apartFirst) { b.steps.push(s.note || 'Other source'); }
        else {
          b.steps.push(pctTxt(prev.v > 0 ? b.v / prev.v * 100 : NaN) + ' of ' + lower(prev.label));
          if (b.v > prev.v && prev.k !== 'eligible') { warns.push(b.label + ' (' + fmt(b.v) + ') is bigger than ' + prev.label + ' (' + fmt(prev.v) + '). Check the numbers.'); }
        }
      }
      if (s.k !== 'eligible' && b.v > base) { warns.push(b.label + ' is bigger than ' + lower(r.eligible_label) + '. Check the numbers.'); }
      if (b.target) {
        const want = b.target.p / 100 * base;
        const diff = b.v - want;
        b.steps.push(due ? fmt(Math.abs(diff)) + (diff < 0 ? ' behind ' : ' ahead of ') + monthName + ' target'
          : pctTxt(want > 0 ? b.v / want * 100 : NaN) + ' of year ' + (s.goal ? 'goal' : 'target'));
      }
      prev = b;
      return b;
    });
    return { bars, base, warns };
  };

  // Draws both halves into root from the panel's one row of numbers (dashboard_src/cascade/panel.sql).
  const draw = (root, data) => {
    const r = Object.assign(settings(), data);
    const { m } = ym(r.reporting_month);
    const asOf = MON[m - 1] + ' ' + ym(r.reporting_month).y;
    const period = periodText(r.reporting_month, r.year_start_month);
    const hasScreening = (num(r.screening_rows) || 0) > 0;
    const hasBase = (num(r.adults) || 0) > 0;
    const s = screeningBars(r);
    const scr = half({
      title: 'Screening cascade', info: r.screening_info, period: 'This year: ' + period,
      sub: hasBase ? 'Of <b>' + esc(fmt(r.adults) + ' ' + r.base_text) + '</b>, how many reached each step this year.' : 'No population data for this place.',
      base: s.base, bars: s.bars,
      empty: !hasScreening ? 'No screening data for this place and month.'
        : !hasBase ? 'No population data for this place, so there is no base for the percentages.' : '',
      warn: hasScreening && hasBase ? s.warns.join(' ') : '',
    });
    const est = num(r.estimated);
    const reg = num(r.registered) || 0;
    const care = num(r.under_care) || 0;
    const ctrl = num(r.controlled) || 0;
    const tBase = est || 0;
    const trt = half({
      title: 'Treatment cascade', period: 'All registered patients, as of ' + asOf,
      info: 'Under care means at least one visit in the last 12 months. BP controlled means below 140/90 at the last visit.',
      sub: est ? 'Of <b>' + esc(fmt(est) + ' estimated adults aged ' + r.age_group) + '</b> with hypertension, how many are registered, under care and have controlled BP.'
        : 'No estimate for this place.',
      base: tBase,
      bars: [
        { v: tBase, label: 'Estimated', c: 'base', steps: est ? [Number(r.prevalence_pct) + '% of ' + fmt(r.adults) + ' adults'] : [] },
        { v: reg, label: 'Registered', c: 'reg', steps: [] },
        { v: care, label: 'Under care', c: 'care', steps: [pctTxt(reg > 0 ? care / reg * 100 : NaN) + ' of registered'] },
        { v: ctrl, label: 'BP controlled', c: 'ctrl', steps: [pctTxt(care > 0 ? ctrl / care * 100 : NaN) + ' of under care'] },
      ],
      empty: est ? '' : 'No population data for this place, so there is no estimate. Registered: ' + fmt(reg) + '. Under care: ' + fmt(care) + '. BP controlled: ' + fmt(ctrl) + '.',
    });
    root.innerHTML = '<div class="csc-card">' + scr + '<div class="csc-divider"></div>' + trt + '</div>'
      + '<p class="csc-note">Screening counts this year only. Treatment counts every patient ever registered. Each chart reads against its own first bar. '
      + 'Population, prevalence and screening counts are example data, not program data.</p>';
  };
  return { draw, periodText, settings, COUNTRIES, ACTIVE };
})();
