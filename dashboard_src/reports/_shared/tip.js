// --- Reports shared ECharts tooltip (dashboard_src/reports/_shared/tip.js) ---
// Copied from the program dashboard's ECharts panels (panel-outcomes, panel-overdue): same dark card,
// bold header, "Label: 61%" over "3,901 of 6,523 patients" in lighter text.
// Declares: frame, col, esc, fmt, soft, dot, tip, chartColors, lineVsAverage. ECharts getOption only.
// The panel's query A (or its first frame), and one column of it as an array ([] when missing).
const frame = (context.panel.data.series || []).find((s) => s.refId === 'A') || (context.panel.data.series || [])[0];
function col(n) { const f = frame && frame.fields.find((x) => x.name === n); if (!f) { return []; } return Array.from(f.values && f.values.buffer ? f.values.buffer : f.values); }
const esc = (x) => String(x == null ? '' : x).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = (v) => Math.round(Number(v) || 0).toLocaleString('en-US');
const soft = (t) => '<span style="opacity:0.7">' + t + '</span>';
// Colour key for charts with more than one series. Like hearts360 (Chart.js), the colour sits on
// white with a 1px white border, so translucent series colours read the same as on the chart.
const dot = (c) => '<span style="display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;'
  + (c ? 'border:1px solid #fff;background:linear-gradient(' + c + ',' + c + '),#fff' : 'border:1px solid transparent') + '"></span>';
// Shared tooltip. rowsFor(dataIndex, axisIndex) gives the lines under the bold header; headFor(dataIndex)
// gives the header (default: the hovered axis label, e.g. a month or a band), escaped here; rows are HTML, so
// escape data in them. extra overrides any option,
// e.g. { axisPointer: { type: 'shadow' } } for bars.
const tip = (rowsFor, headFor, extra) => Object.assign({
  trigger: 'axis', backgroundColor: 'rgba(28,28,28,0.92)', borderWidth: 0, padding: [8, 12],
  textStyle: { color: '#fff', fontSize: 13 }, extraCssText: 'border-radius: 6px;',
  axisPointer: { lineStyle: { color: 'rgba(110,127,141,0.6)' } },
  formatter: (ps) => {
    const p = [].concat(ps)[0];
    if (!p || p.dataIndex == null) { return ''; }
    const head = headFor ? headFor(p.dataIndex) : p.axisValueLabel;
    return '<b>' + esc(head) + '</b><br>' + rowsFor(p.dataIndex, p.axisIndex || 0).join('<br>');
  }
}, extra || {});
// DESIGN tokens used by charts (cascade colours keep their meaning).
const chartColors = {
  controlled: '#3BB231', uncontrolled: '#EEAB00', noVisit: '#ED6300', estimated: '#DAE0E1',
  text: '#111217', muted: '#6E6E6E', axis: '#6e7f8d', grid: 'rgba(128,128,128,0.15)', axisLine: 'rgba(128,128,128,0.4)',
  step: ['#E1DEF5', '#C3BDEB', '#A49BE0', '#8578D3', '#6655BF', '#4A3A9E'], stepOther: '#B3BAC1', stepOff: '#6E7782',
  // Place against the average (Metabase monthly reports): place blue, average purple.
  place: '#3D71D9', average: '#9B7FD4'
};
// Monthly line of the place in view against the average of all places (Metabase titration and statins form).
// cfg: { months: [ms or 'YYYY-MM-DD'], place: 'District-D', value: [pct|null], avg: [pct|null],
//        placeLines: (k) => ['195 of 535 visits'], avgLines: (k) => [...], empty: 'No data for this place.' }
const lineVsAverage = (cfg) => {
  const C = chartColors;
  const M = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const mon = (x) => { const d = typeof x === 'number' ? new Date(x) : new Date(String(x).slice(0, 10) + 'T00:00:00Z'); return isNaN(d) ? '' : M[d.getUTCMonth()] + '-' + d.getUTCFullYear(); };
  const pc = (v) => (v === null || v === undefined ? '—' : (Math.abs(v) < 10 ? Number(v).toFixed(1) : String(Math.round(v))) + '%');
  if (!cfg.months.length) {
    return { graphic: cfg.empty ? [{ type: 'text', left: 'center', top: 'middle', style: { text: cfg.empty, fontSize: 14, fill: C.muted } }] : [] };
  }
  const avgName = 'Average of all places';
  const last = cfg.months.length - 1;
  const endLabel = (color) => ({ show: true, position: 'right', color: color, fontSize: 12, fontWeight: 600,
    formatter: (p) => (p.dataIndex === last ? pc(p.value) : '') });
  return {
    animation: false,
    color: [C.place, C.average],
    legend: { top: 0, left: 0, icon: 'circle', itemWidth: 10, itemHeight: 10, textStyle: { color: C.text, fontSize: 12 } },
    grid: { left: 8, right: 44, top: 32, bottom: 8, containLabel: true },
    tooltip: tip((k) => [dot(C.place) + esc(cfg.place) + ': ' + pc(cfg.value[k])].concat((cfg.placeLines ? cfg.placeLines(k) : []).map(soft))
      .concat([dot(C.average) + 'Average: ' + pc(cfg.avg[k])]).concat((cfg.avgLines ? cfg.avgLines(k) : []).map(soft)),
      (k) => mon(cfg.months[k])),
    xAxis: { type: 'category', data: cfg.months.map(mon), boundaryGap: false, axisTick: { show: false },
      axisLabel: { color: C.axis, fontSize: 11 }, axisLine: { lineStyle: { color: C.axisLine } } },
    yAxis: { type: 'value', min: 0, max: 100, interval: 25, axisLabel: { color: C.axis, fontSize: 11, formatter: (v) => v + '%' },
      splitLine: { lineStyle: { color: C.grid, type: 'dashed' } } },
    series: [
      { type: 'line', name: cfg.place, data: cfg.value, symbol: 'circle', symbolSize: 6, connectNulls: false,
        lineStyle: { width: 2, color: C.place }, itemStyle: { color: C.place }, label: endLabel(C.place) },
      { type: 'line', name: avgName, data: cfg.avg, symbol: 'circle', symbolSize: 6, connectNulls: false,
        lineStyle: { width: 2, color: C.average }, itemStyle: { color: C.average }, label: endLabel(C.average) }
    ]
  };
};
