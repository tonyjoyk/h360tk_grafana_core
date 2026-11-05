// --- Reports shared ECharts tooltip (dashboard_src/reports/_shared/tip.js) ---
// Copied from the program dashboard's ECharts panels (panel-outcomes, panel-overdue): same dark card,
// bold header, "Label: 61%" over "3,901 of 6,523 patients" in lighter text.
// Declares: fmt, soft, dot, pctStr, shareRows, tip, chartColors. ECharts getOption only.
const fmt = (v) => Math.round(Number(v) || 0).toLocaleString('en-US');
const soft = (t) => '<span style="opacity:0.7">' + t + '</span>';
// Colour key for charts with more than one series. Like hearts360 (Chart.js), the colour sits on
// white with a 1px white border, so translucent series colours read the same as on the chart.
const dot = (c) => '<span style="display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;'
  + (c ? 'border:1px solid #fff;background:linear-gradient(' + c + ',' + c + '),#fff' : 'border:1px solid transparent') + '"></span>';
const pctStr = (v, d) => (Number(d) ? Math.round(100 * (Number(v) || 0) / Number(d)) : 0) + '%';
// "Label: 61%" over "3,901 of 6,523 patients"; several rows become "Label: 29%, 387 patients" over "of 1,352 patients"
// (an optional third item per row adds a colour key).
const shareRows = (rows, d) => rows.length === 1
  ? [rows[0][0] + ': ' + pctStr(rows[0][1], d), soft(fmt(rows[0][1]) + ' of ' + fmt(d) + ' patients')]
  : rows.map(([label, v, c]) => dot(c) + label + ': ' + pctStr(v, d) + ', ' + fmt(v) + ' patients').concat(soft('of ' + fmt(d) + ' patients'));
// Shared tooltip. rowsFor(dataIndex, axisIndex) gives the lines under the bold header; headFor(dataIndex)
// gives the header (default: the hovered axis label, e.g. a month or a band). extra overrides any option,
// e.g. { axisPointer: { type: 'shadow' } } for bars.
const tip = (rowsFor, headFor, extra) => Object.assign({
  trigger: 'axis', backgroundColor: 'rgba(28,28,28,0.92)', borderWidth: 0, padding: [8, 12],
  textStyle: { color: '#fff', fontSize: 13 }, extraCssText: 'border-radius: 6px;',
  axisPointer: { lineStyle: { color: 'rgba(110,127,141,0.6)' } },
  formatter: (ps) => {
    const p = [].concat(ps)[0];
    if (!p || p.dataIndex == null) { return ''; }
    const head = headFor ? headFor(p.dataIndex) : p.axisValueLabel;
    return '<b>' + head + '</b><br>' + rowsFor(p.dataIndex, p.axisIndex || 0).join('<br>');
  }
}, extra || {});
// DESIGN tokens used by charts (cascade colours keep their meaning).
const chartColors = {
  controlled: '#3BB231', uncontrolled: '#EEAB00', noVisit: '#ED6300', estimated: '#DAE0E1',
  text: '#111217', muted: '#6E6E6E', axis: '#6e7f8d', grid: 'rgba(128,128,128,0.15)', axisLine: 'rgba(128,128,128,0.4)',
  step: ['#E1DEF5', '#C3BDEB', '#A49BE0', '#8578D3', '#6655BF', '#4A3A9E'], stepOther: '#B3BAC1', stepOff: '#6E7782'
};
