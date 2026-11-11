/*
 * HEARTS360 chat widget (stories 6.8 and 6.9; AD-17, AD-30, AD-33; PD-12 to PD-15).
 *
 * Injected into Grafana's page shell at image build (docker_build/heart360.grafana.docker).
 * Plain JS, no dependencies. Everything lives under one root element (#h360-chat-root)
 * with `h360c-` prefixed classes.
 *
 * It calls only H360_API, with credentials:'include' and X-H360-Request: 1:
 *   GET  /chat/chips?org_unit_id&reporting_month -> {scope, place, month, mode, chips:[{id,label}]}
 *   POST /chat {chip_id|text, org_unit_id, reporting_month}
 *        -> {mode, place, month, reasons, also_check, stock_line, nudge, plan, honesty, links}
 *           plus (story 7.9) title, control_line, control_figure, control_evidence, stock_evidence;
 *           each reason may carry tag, figure and evidence.
 *
 * Evidence (UX-10, after the hearts360ai supervision prototype): a reason's figure is drawn with a
 * dashed underline. Hovering or focusing it opens a card beside the panel with the chart or table
 * behind the number, the place and month, and `See this in Reports: <tab>`. The figure is a
 * button: Enter or Space pins the card, Tab moves into its link, Escape closes it.
 *
 * window.H360_API defaults to <page protocol>//<page hostname>:<Grafana port + 5090> (3000 -> 8090).
 * Set it before this script runs to point elsewhere (mocks). The stock form reads the same value.
 */
(function () {
  'use strict';

  if (window.__h360ChatWidget) { return; }
  window.__h360ChatWidget = true;

  var boot = window.grafanaBootData;
  if (!boot || !boot.user || !boot.user.isSignedIn) { return; }

  // ---------------------------------------------------------------- constants
  var STORE_OPEN = 'h360.chat.open';
  var MAX_TEXT = 200;
  var SLOW_MS = 3000;
  var GIVE_UP_MS = 10000;
  var CLEAR_SELECTORS = [
    // Grafana 13 dashboard scroll container (dashboard scene with sidebar splitter).
    '[data-testid="data-testid DashboardSidebarSplitter body container"]'
  ];
  // The row is titled `Change location · <place>` on the boards (UX-18): match by prefix.
  var ROW_TOGGLE = '[data-testid^="data-testid dashboard-row-toggle-for-Change location"], button[aria-label^="Expand row Change location"], button[aria-label^="Collapse row Change location"]';
  var ROW_WRAPPER = '[data-testid^="data-testid dashboard-row-wrapper-for-Change location"]';
  var ICON_ONLY_BELOW = 1440; // UX-22: the full pill covers panel content on smaller screens
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var TXT = {
    pill: 'Ask HEARTS360',
    openLabel: 'Open HEARTS360 assistant',
    dialog: 'HEARTS360 assistant',
    close: 'Close HEARTS360 assistant',
    htnOnly: 'Hypertension only',
    intro: 'Pick a question. I answer from your reports.',
    national: 'Pick a district or a facility to ask a question.',
    nationalViewer: 'Pick your facility or district in Change location above to ask a question.',
    pickPlace: 'Pick a place',
    chipsGroup: 'Questions you can ask',
    placeholder: 'Or type a question',
    ask: 'Ask',
    loading: 'Looking at your reports\u2026',
    slow: 'Still working\u2026',
    error: 'I couldn\u2019t get an answer. Your reports are not affected.',
    tryAgain: 'Try again',
    pickAnother: 'Pick another question',
    signedOut: 'Your session ended. Reload the page and sign in.',
    noAccess: 'You do not have access to this place.',
    noMatch: 'I can only answer the questions above. Pick one.',
    fallback: 'Claude was not available, so this is written from a template.',
    badgeOffline: 'Written from your reports',
    badgeOfflineTitle: 'Written from your reports with a fixed template. The numbers are the same.',
    badgeClaude: 'Claude wording',
    badgeClaudeTitle: 'Claude wrote the words. The numbers are the same.',
    whatToDo: 'What to do',
    seeIn: 'See this in Reports: ',
    alsoCheck: 'Also check: ',
    planUnit: 'a week',
    planTotal: ' overdue with a phone',
    showData: 'Show the data',
    closeCard: 'Close',
    emptyChips: 'No questions are ready for this place yet.'
  };

  // ---------------------------------------------------------------- helpers
  function ssGet(k) { try { return window.sessionStorage.getItem(k); } catch (e) { return null; } }
  function ssSet(k, v) { try { window.sessionStorage.setItem(k, v); } catch (e) { /* ignore */ } }

  window.H360_API = window.H360_API || (location.protocol + '//' + location.hostname + ':' + ((Number(location.port) || 80) + 5090));

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) { n.className = cls; }
    if (text !== undefined && text !== null) { n.textContent = String(text); }
    return n;
  }

  function fmtMonth(m) {
    if (!m) { return ''; }
    var r = /^(\d{4})-(\d{2})/.exec(String(m));
    if (!r) { return String(m); }
    var i = parseInt(r[2], 10) - 1;
    return (MONTHS[i] || r[2]) + '-' + r[1];
  }

  function placeName(p) {
    if (!p) { return ''; }
    if (typeof p === 'string') { return p; }
    return p.name || '';
  }

  // Only same-origin links (relative paths or this Grafana origin) are rendered.
  function safeHref(u) {
    if (typeof u !== 'string' || !u) { return null; }
    if (u.charAt(0) === '/' && u.charAt(1) !== '/') { return u; }
    try {
      var p = new URL(u, location.href);
      if (p.origin === location.origin) { return p.pathname + p.search + p.hash; }
    } catch (e) { /* ignore */ }
    return null;
  }

  // ---------------------------------------------------------------- URL scope
  function readScope() {
    var q;
    try { q = new URLSearchParams(location.search); } catch (e) { q = null; }
    var org = q ? (q.get('var-org_unit') || '') : '';
    if (org === '$__all' || org === 'All') { org = ''; }
    // UX-20: the month carries on every board that names it.
    var month = q ? (q.get('var-reporting_month') || '') : '';
    if (!/^\d{4}-\d{2}-01$/.test(month)) { month = ''; }
    return { org: org, month: month };
  }

  // ---------------------------------------------------------------- CSS
  var CSS = [
    '#h360-chat-root{all:initial;}',
    '#h360-chat-root, #h360-chat-root *{box-sizing:border-box;font-family:Inter,Roboto,Helvetica,Arial,sans-serif;}',
    '#h360-chat-root .h360c-sr{position:absolute!important;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0;}',
    '#h360-chat-root button{font:inherit;cursor:pointer;}',
    '#h360-chat-root :focus-visible{outline:2px solid #3D71D9;outline-offset:2px;}',
    // pill
    '#h360-chat-root .h360c-pill{position:fixed;right:64px;bottom:20px;z-index:1000;height:48px;padding:0 20px 0 16px;border:0;border-radius:9999px;background:#3D71D9;color:#fff;display:flex;align-items:center;gap:8px;font-size:14px;font-weight:600;line-height:1;box-shadow:0 4px 16px rgba(17,18,23,0.16);}',
    '#h360-chat-root .h360c-pill:hover{background:#2F5FC0;}',
    '#h360-chat-root .h360c-pill:focus-visible{outline:2px solid #111217;outline-offset:2px;box-shadow:0 0 0 2px #fff,0 4px 16px rgba(17,18,23,0.16);}',
    '#h360-chat-root .h360c-pill svg{width:20px;height:20px;flex:none;}',
    '#h360-chat-root.h360c-iconly .h360c-pill{width:48px;padding:0;justify-content:center;}',
    '#h360-chat-root.h360c-iconly .h360c-pill-label{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0);}',
    '#h360-chat-root.h360c-open .h360c-pill{display:none;}',
    // panel
    '#h360-chat-root .h360c-panel{position:fixed;right:64px;bottom:76px;z-index:1000;width:380px;height:min(560px, calc(100vh - 100px));display:none;flex-direction:column;background:#fff;border:1px solid #D8D9DA;border-radius:8px;box-shadow:0 4px 16px rgba(17,18,23,0.16);color:#111217;font-size:14px;line-height:1.45;overflow:hidden;}',
    '#h360-chat-root.h360c-open .h360c-panel{display:flex;}',
    '#h360-chat-root.h360c-open.h360c-anim .h360c-panel{animation:h360c-fade 120ms ease-out;}',
    '@keyframes h360c-fade{from{opacity:0}to{opacity:1}}',
    '@media (max-width:479px){#h360-chat-root .h360c-panel{left:8px;right:8px;width:auto;}}',
    '@media (prefers-reduced-motion:reduce){#h360-chat-root *{animation:none!important;transition:none!important;scroll-behavior:auto!important;}}',
    // header
    '#h360-chat-root .h360c-head{flex:none;min-height:56px;padding:12px 16px;border-bottom:1px solid #D8D9DA;display:flex;align-items:center;gap:8px;}',
    '#h360-chat-root .h360c-head-txt{flex:1;min-width:0;}',
    '#h360-chat-root .h360c-scope{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin:0;}',
    '#h360-chat-root .h360c-sub{font-size:12px;color:#6E6E6E;margin:0;}',
    '#h360-chat-root .h360c-badge{flex:none;font-size:12px;font-weight:600;padding:4px 8px;border-radius:9999px;background:#ECEEEF;color:#111217;white-space:nowrap;}',
    '#h360-chat-root .h360c-badge.h360c-claude{background:#E8EFFC;color:#2B57B3;}',
    '#h360-chat-root .h360c-badge[hidden]{display:none;}',
    '#h360-chat-root .h360c-close{flex:none;width:36px;height:36px;border:0;border-radius:4px;background:transparent;color:#111217;font-size:22px;line-height:1;display:flex;align-items:center;justify-content:center;}',
    '#h360-chat-root .h360c-close:hover{background:#F4F5F5;}',
    // body
    '#h360-chat-root .h360c-body{flex:1;overflow-y:auto;padding:16px;background:#F4F5F5;display:flex;flex-direction:column;gap:12px;}',
    '#h360-chat-root .h360c-p{margin:0;}',
    '#h360-chat-root .h360c-chips{display:flex;flex-direction:column;gap:8px;}',
    '#h360-chat-root .h360c-chip{width:100%;min-height:36px;padding:6px 14px;text-align:left;background:#fff;color:#2B57B3;border:1px solid #3D71D9;border-radius:9999px;font-size:14px;}',
    '#h360-chat-root .h360c-chip:hover:not(:disabled){background:#EEF3FD;}',
    '#h360-chat-root .h360c-chip:disabled{opacity:0.55;cursor:default;}',
    '#h360-chat-root .h360c-log{display:flex;flex-direction:column;gap:12px;}',
    '#h360-chat-root .h360c-user{align-self:flex-end;max-width:85%;background:#3D71D9;color:#fff;font-size:14px;border-radius:8px 8px 2px 8px;padding:8px 12px;overflow-wrap:anywhere;}',
    // cards
    '#h360-chat-root .h360c-card{background:#fff;border:1px solid #D8D9DA;border-radius:8px;padding:16px;display:flex;flex-direction:column;gap:12px;}',
    '#h360-chat-root .h360c-title{font-size:14px;font-weight:600;margin:0;}',
    '#h360-chat-root .h360c-title:focus{outline:none;}',
    '#h360-chat-root .h360c-title:focus-visible{outline:2px solid #3D71D9;outline-offset:2px;}',
    '#h360-chat-root .h360c-muted{font-size:12px;color:#6E6E6E;margin:0;}',
    '#h360-chat-root .h360c-reasons{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;}',
    '#h360-chat-root .h360c-reason{display:flex;gap:10px;padding:10px 0;border-top:1px solid #D8D9DA;}',
    '#h360-chat-root .h360c-reason:first-child{border-top:0;padding-top:0;}',
    '#h360-chat-root .h360c-rank{flex:none;width:24px;height:24px;border-radius:50%;background:#111217;color:#fff;font-size:12px;font-weight:600;display:flex;align-items:center;justify-content:center;}',
    '#h360-chat-root .h360c-rtext{flex:1;min-width:0;display:flex;flex-direction:column;gap:4px;}',
    '#h360-chat-root .h360c-num{font-weight:700;}',
    '#h360-chat-root .h360c-wtd{font-size:12px;font-weight:600;color:#6E6E6E;margin:4px 0 0;}',
    '#h360-chat-root .h360c-link{font-size:12px;color:#3D71D9;text-decoration:none;display:inline-flex;align-items:center;min-height:36px;}',
    '#h360-chat-root .h360c-link:hover{text-decoration:underline;}',
    '#h360-chat-root .h360c-btn{width:100%;min-height:36px;padding:6px 12px;background:#fff;color:#2B57B3;border:1px solid #3D71D9;border-radius:4px;font-size:14px;text-align:center;}',
    '#h360-chat-root .h360c-btn:hover:not(:disabled){background:#EEF3FD;}',
    '#h360-chat-root .h360c-btn:disabled{opacity:0.55;cursor:default;}',
    '#h360-chat-root .h360c-also{background:#EFEFEF;border-radius:4px;padding:8px 12px;margin:0;}',
    '#h360-chat-root .h360c-stock{background:#FFF8E1;border-left:4px solid #EEAB00;border-radius:4px;padding:8px 12px;margin:0;}',
    '#h360-chat-root .h360c-err{border-left:4px solid #EEAB00;}',
    '#h360-chat-root .h360c-row{display:flex;gap:8px;flex-wrap:wrap;}',
    '#h360-chat-root .h360c-row .h360c-btn{width:auto;flex:1;}',
    // plan
    '#h360-chat-root .h360c-big{font-size:32px;font-weight:600;line-height:1.1;}',
    '#h360-chat-root .h360c-weeks{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;}',
    '#h360-chat-root .h360c-week{background:#DAE0E1;border-radius:4px;padding:8px;text-align:center;}',
    '#h360-chat-root .h360c-week span{display:block;font-size:12px;color:#4E545A;}',
    '#h360-chat-root .h360c-week strong{display:block;font-size:16px;font-weight:600;}',
    // honesty
    '#h360-chat-root .h360c-honesty{font-size:12px;color:#6E6E6E;border-top:1px solid #D8D9DA;padding-top:12px;margin:0;}',
    // skeleton
    '#h360-chat-root .h360c-skel{height:12px;border-radius:4px;background:#DAE0E1;}',
    '#h360-chat-root .h360c-skel:nth-child(2){width:85%;}',
    '#h360-chat-root .h360c-skel:nth-child(3){width:65%;}',
    // footer
    '#h360-chat-root .h360c-foot{flex:none;display:flex;gap:8px;padding:8px 12px;border-top:1px solid #D8D9DA;background:#fff;}',
    '#h360-chat-root .h360c-input{flex:1;min-width:0;height:40px;padding:0 10px;border:1px solid #D8D9DA;border-radius:4px;font-size:14px;color:#111217;background:#fff;}',
    '#h360-chat-root .h360c-input::placeholder{color:#6E6E6E;}',
    '#h360-chat-root .h360c-ask{flex:none;height:40px;min-width:56px;padding:0 12px;border:1px solid #D8D9DA;border-radius:4px;background:#fff;color:#111217;font-size:14px;}',
    '#h360-chat-root .h360c-ask:disabled{opacity:0.55;cursor:default;}',
    // tags, figures and evidence cards (story 7.9, after the hearts360ai supervision prototype)
    '#h360-chat-root .h360c-tag{display:inline-block;margin:0 6px 2px 0;padding:1px 8px;border-radius:9999px;background:#FDECEC;color:#8A1C1C;font-size:11px;font-weight:600;line-height:18px;vertical-align:1px;}',
    '#h360-chat-root .h360c-fig{display:inline;padding:0 1px;margin:0;border:0;border-radius:2px;background:transparent;color:inherit;font:inherit;font-weight:700;cursor:help;text-decoration:underline 1px dashed #6C737A;text-underline-offset:4px;}',
    '#h360-chat-root .h360c-fig:hover,#h360-chat-root .h360c-fig[aria-expanded="true"]{background:#E9F3FF;}',
    '#h360-chat-root .h360c-showdata{display:inline-block;margin-top:2px;padding:0;border:0;background:transparent;color:#2B57B3;font-size:12px;cursor:help;text-decoration:underline 1px dashed #6C737A;text-underline-offset:3px;}',
    '#h360-chat-root .h360c-ev{position:fixed;z-index:1001;width:340px;max-width:calc(100vw - 16px);padding:16px 16px 0;background:#fff;border-radius:8px;box-shadow:0 2px 6px rgba(17,18,23,0.12),0 8px 24px rgba(17,18,23,0.18);color:#111217;font-size:13px;line-height:1.35;}',
    '#h360-chat-root .h360c-ev[hidden]{display:none;}',
    '#h360-chat-root .h360c-ev::after{content:"";position:absolute;right:-7px;top:var(--h360c-arrow-y,24px);width:14px;height:14px;background:#fff;transform:rotate(45deg);border-radius:2px;box-shadow:3px -3px 4px rgba(17,18,23,0.06);}',
    '#h360-chat-root .h360c-ev.h360c-below::after{display:none;}',
    '#h360-chat-root .h360c-ev h4{margin:0 24px 2px 0;font-size:15px;font-weight:700;line-height:1.2;}',
    '#h360-chat-root .h360c-ev .h360c-def{margin:0 0 10px;font-size:12px;color:#6E6E6E;}',
    '#h360-chat-root .h360c-ev .h360c-rate{margin:0 0 2px;font-size:28px;font-weight:700;line-height:1;}',
    '#h360-chat-root .h360c-ev .h360c-detail{font-size:12px;color:#6E6E6E;min-height:32px;}',
    '#h360-chat-root .h360c-ev svg{display:block;width:100%;height:132px;margin-top:6px;overflow:visible;}',
    '#h360-chat-root .h360c-ev svg:focus-visible{outline:2px solid #3D71D9;outline-offset:2px;}',
    '#h360-chat-root .h360c-ev .h360c-x{position:absolute;top:8px;right:8px;width:28px;height:28px;border:0;border-radius:4px;background:transparent;color:#6E6E6E;font-size:18px;line-height:1;}',
    '#h360-chat-root .h360c-ev .h360c-x:hover{background:#F4F5F5;}',
    '#h360-chat-root .h360c-ev table{width:100%;border-collapse:collapse;margin:4px 0 4px;font-size:12px;}',
    '#h360-chat-root .h360c-ev th{padding:0 6px 4px;text-align:right;font-weight:600;color:#6E6E6E;}',
    '#h360-chat-root .h360c-ev td{padding:3px 6px;text-align:right;color:#4E545A;border-top:1px solid #ECEEEF;}',
    '#h360-chat-root .h360c-ev th:first-child,#h360-chat-root .h360c-ev td:first-child{text-align:left;padding-left:4px;}',
    '#h360-chat-root .h360c-ev tr.h360c-target td{background:#E9F3FF;color:#0C3966;border-top:0;}',
    '#h360-chat-root .h360c-ev tr.h360c-focus td{background:#E9F3FF;color:#111217;font-weight:700;}',
    '#h360-chat-root .h360c-ev td.h360c-bad{color:#B42318;font-weight:700;}',
    '#h360-chat-root .h360c-ev .h360c-band{display:flex;align-items:center;justify-content:space-between;gap:8px;margin:10px -16px 0;padding:8px 16px;background:#E9F3FF;color:#0C3966;font-size:12px;font-weight:500;border-radius:0 0 8px 8px;}',
    '#h360-chat-root .h360c-ev .h360c-band a{color:#0075EB;text-decoration:none;white-space:nowrap;}',
    '#h360-chat-root .h360c-ev .h360c-band a:hover{text-decoration:underline;}',
    '#h360-chat-root .h360c-ev .h360c-band span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}',
    '#h360-chat-root .h360c-legend{display:flex;gap:12px;margin-top:2px;font-size:11px;color:#6E6E6E;}',
    '#h360-chat-root .h360c-legend i{display:inline-block;width:14px;height:0;margin-right:4px;vertical-align:3px;border-top:2px solid #3D71D9;}',
    '#h360-chat-root .h360c-legend i.h360c-avg{border-top:2px dashed #8E9399;}',
    '#h360-chat-root .h360c-plan-basis{font-size:13px;color:#4E545A;margin:0;}',
    '@media (max-width:' + (ICON_ONLY_BELOW - 1) + 'px){#h360-chat-root .h360c-pill{width:48px;padding:0;justify-content:center;}#h360-chat-root .h360c-pill-label{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0);}}',
    // clearance for Grafana's scroll container (PD-15)
    '.h360c-clearance{padding-bottom:72px!important;}'
  ].join('\n');

  var ICON = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path fill="currentColor" d="M12 3C6.5 3 2 6.6 2 11c0 2.2 1.1 4.2 2.9 5.6-.2 1.5-.9 2.9-2 4 .1.1 3.3-.2 5.6-1.9 1.1.3 2.3.4 3.5.4 5.5 0 10-3.6 10-8S17.5 3 12 3zm-5 9.3a1.3 1.3 0 1 1 0-2.6 1.3 1.3 0 0 1 0 2.6zm5 0a1.3 1.3 0 1 1 0-2.6 1.3 1.3 0 0 1 0 2.6zm5 0a1.3 1.3 0 1 1 0-2.6 1.3 1.3 0 0 1 0 2.6z"/></svg>';

  // ---------------------------------------------------------------- state
  var S = {
    scope: readScope(),
    chipsFor: null,      // scope key the chips were fetched for
    chipsData: null,
    busy: false,
    reqSeq: 0,
    honesty: null,
    lastPath: location.pathname + location.search
  };

  // ---------------------------------------------------------------- DOM
  var root, pill, panel, scopeEl, badge, closeBtn, body, chipsWrap, chipsIntro, chipsGroup, log, input, askBtn, honestyEl;

  function build() {
    var style = el('style');
    style.id = 'h360-chat-style';
    style.textContent = CSS;
    if (window.nonce) { style.setAttribute('nonce', window.nonce); }
    document.head.appendChild(style);

    root = el('div');
    root.id = 'h360-chat-root';

    pill = el('button', 'h360c-pill');
    pill.type = 'button';
    pill.setAttribute('aria-expanded', 'false');
    pill.setAttribute('aria-controls', 'h360c-panel');
    pill.setAttribute('aria-label', TXT.openLabel);
    pill.innerHTML = ICON;
    pill.appendChild(el('span', 'h360c-pill-label', TXT.pill));
    pill.addEventListener('click', function () { openPanel(true); });

    panel = el('div', 'h360c-panel');
    panel.id = 'h360c-panel';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', TXT.dialog);

    var head = el('div', 'h360c-head');
    var headTxt = el('div', 'h360c-head-txt');
    scopeEl = el('p', 'h360c-scope', '\u00a0');
    headTxt.appendChild(scopeEl);
    headTxt.appendChild(el('p', 'h360c-sub', TXT.htnOnly));
    badge = el('span', 'h360c-badge');
    badge.hidden = true;
    closeBtn = el('button', 'h360c-close');
    closeBtn.type = 'button';
    closeBtn.setAttribute('aria-label', TXT.close);
    closeBtn.innerHTML = '<span aria-hidden="true">\u00d7</span>';
    closeBtn.addEventListener('click', function () { closePanel(true); });
    head.appendChild(headTxt);
    head.appendChild(badge);
    head.appendChild(closeBtn);

    body = el('div', 'h360c-body');
    body.addEventListener('scroll', function () { if (openCard) { placeCard(openCard.card, openCard.anchor); } });
    chipsWrap = el('div', 'h360c-chipswrap');
    chipsIntro = el('p', 'h360c-p', TXT.intro);
    chipsGroup = el('div', 'h360c-chips');
    chipsGroup.setAttribute('role', 'group');
    chipsGroup.setAttribute('aria-label', TXT.chipsGroup);
    chipsWrap.appendChild(chipsIntro);
    chipsWrap.appendChild(el('div', null)).style.height = '8px';
    chipsWrap.appendChild(chipsGroup);
    log = el('div', 'h360c-log');
    log.setAttribute('role', 'log');
    log.setAttribute('aria-live', 'polite');
    log.setAttribute('aria-label', 'Answers');
    body.appendChild(chipsWrap);
    body.appendChild(log);

    var foot = el('form', 'h360c-foot');
    foot.setAttribute('autocomplete', 'off');
    input = el('input', 'h360c-input');
    input.type = 'text';
    input.maxLength = MAX_TEXT;
    input.placeholder = TXT.placeholder;
    input.setAttribute('aria-label', TXT.placeholder);
    askBtn = el('button', 'h360c-ask', TXT.ask);
    askBtn.type = 'submit';
    foot.appendChild(input);
    foot.appendChild(askBtn);
    foot.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var t = (input.value || '').trim().slice(0, MAX_TEXT);
      if (!t || S.busy) { return; }
      if (S.chipsData && S.chipsData.scope === 'national') { pickDistrict(); return; }
      input.value = '';
      ask({ text: t }, t);
    });

    panel.appendChild(head);
    panel.appendChild(body);
    panel.appendChild(foot);

    root.appendChild(pill);
    root.appendChild(panel);
    document.body.appendChild(root);
  }

  // ---------------------------------------------------------------- open/close
  function isOpen() { return root.classList.contains('h360c-open'); }

  function openPanel(focus) {
    // Fade only when the user opens it; a restored-open panel on page load appears at once.
    root.classList.toggle('h360c-anim', !!focus);
    root.classList.add('h360c-open');
    pill.setAttribute('aria-expanded', 'true');
    ssSet(STORE_OPEN, '1');
    ensureChips();
    if (focus) {
      S.focusChips = true;
      setTimeout(function () {
        var first = chipsGroup.querySelector('button.h360c-chip:not(:disabled)');
        if (first) { S.focusChips = false; first.focus(); } else { closeBtn.focus(); }
      }, 0);
    }
  }

  function closePanel(returnFocus) {
    if (openCard) { openCard.pinned = false; hideCard(false); }
    root.classList.remove('h360c-open');
    pill.setAttribute('aria-expanded', 'false');
    ssSet(STORE_OPEN, '0');
    if (returnFocus) { pill.focus(); }
  }

  // ---------------------------------------------------------------- fetch
  function apiFetch(path, opts, signal) {
    var o = opts || {};
    var headers = { 'X-H360-Request': '1' };
    if (o.body) { headers['Content-Type'] = 'application/json'; }
    return fetch(String(window.H360_API).replace(/\/+$/, '') + path, {
      method: o.method || 'GET',
      credentials: 'include',
      headers: headers,
      body: o.body ? JSON.stringify(o.body) : undefined,
      signal: signal
    }).then(function (r) {
      return r.text().then(function (t) {
        var data = null;
        try { data = t ? JSON.parse(t) : null; } catch (e) { data = null; }
        return { status: r.status, ok: r.ok, data: data };
      });
    });
  }

  function withTimers(onSlow) {
    var ctrl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
    var slowT = setTimeout(onSlow, SLOW_MS);
    var giveT = setTimeout(function () { if (ctrl) { ctrl.abort(); } }, GIVE_UP_MS);
    return {
      signal: ctrl ? ctrl.signal : undefined,
      done: function () { clearTimeout(slowT); clearTimeout(giveT); }
    };
  }

  function statusMessage(res) {
    if (res && res.status === 401) { return TXT.signedOut; }
    if (res && res.status === 403) { return TXT.noAccess; }
    return null;
  }

  // ---------------------------------------------------------------- header
  function setHeader(place, month) {
    var name = placeName(place);
    var m = fmtMonth(month);
    var txt = name && m ? name + ' \u00b7 ' + m : (name || m || '\u00a0');
    scopeEl.textContent = txt;
    scopeEl.title = name || '';
  }

  function setBadge(mode) {
    if (!mode) { badge.hidden = true; return; }
    badge.hidden = false;
    if (mode === 'claude') {
      badge.textContent = TXT.badgeClaude;
      badge.title = TXT.badgeClaudeTitle;
      badge.classList.add('h360c-claude');
    } else {
      badge.textContent = TXT.badgeOffline;
      badge.title = TXT.badgeOfflineTitle;
      badge.classList.remove('h360c-claude');
    }
  }

  // ---------------------------------------------------------------- chips
  function scopeKey(s) { return s.org + '|' + s.month; }

  function chipsQuery() {
    var p = new URLSearchParams();
    p.set('org_unit_id', S.scope.org);
    if (S.scope.month) { p.set('reporting_month', S.scope.month); }
    return p.toString();
  }

  function ensureChips(force) {
    var key = scopeKey(S.scope);
    if (!force && S.chipsFor === key) { return; }
    S.chipsFor = key;
    loadChips(key);
  }

  function loadChips(key) {
    chipsIntro.textContent = TXT.loading;
    chipsGroup.innerHTML = '';
    chipsGroup.appendChild(skeletonBlock());
    var t = withTimers(function () { if (S.chipsFor === key) { chipsIntro.textContent = TXT.slow; } });
    apiFetch('/chat/chips?' + chipsQuery(), null, t.signal).then(function (res) {
      t.done();
      if (S.chipsFor !== key) { return; }
      if (!res.ok || !res.data) { chipsError(statusMessage(res)); return; }
      renderChips(res.data);
    }, function () {
      t.done();
      if (S.chipsFor !== key) { return; }
      chipsError(null);
    });
  }

  function chipsError(msg) {
    S.chipsData = null;
    chipsIntro.textContent = '';
    chipsGroup.innerHTML = '';
    var card = el('div', 'h360c-card h360c-err');
    card.appendChild(el('p', 'h360c-p', msg || TXT.error));
    if (!msg || msg === TXT.error) {
      var b = el('button', 'h360c-btn', TXT.tryAgain);
      b.type = 'button';
      b.addEventListener('click', function () { ensureChips(true); });
      card.appendChild(b);
    }
    chipsGroup.appendChild(card);
  }

  function renderChips(d) {
    S.chipsData = d;
    setHeader(d.place, d.month);
    setBadge(d.mode);
    chipsGroup.innerHTML = '';
    var national = d.scope === 'national';
    var admin = !!(boot.user && (boot.user.isGrafanaAdmin || boot.user.orgRole === 'Admin'));
    chipsIntro.textContent = national ? (admin ? TXT.national : TXT.nationalViewer) : TXT.intro;
    var chips = Array.isArray(d.chips) ? d.chips : [];
    if (!chips.length) {
      chipsGroup.appendChild(el('p', 'h360c-p', TXT.emptyChips));
      return;
    }
    chips.forEach(function (c) {
      if (!c || !c.label) { return; }
      var b = el('button', 'h360c-chip', (national || c.id === 'pick_district') ? TXT.pickPlace : c.label);
      b.type = 'button';
      b.setAttribute('data-chip', c.id || '');
      b.disabled = S.busy;
      b.addEventListener('click', function () {
        if (S.busy) { return; }
        if (national || c.id === 'pick_district') { pickDistrict(); return; }
        ask({ chip_id: c.id }, c.label);
      });
      chipsGroup.appendChild(b);
    });
    if (S.focusChips && isOpen() && (!document.activeElement || document.activeElement === closeBtn || document.activeElement === document.body)) {
      var first = chipsGroup.querySelector('button.h360c-chip');
      if (first) { first.focus(); }
    }
    S.focusChips = false;
  }

  function setBusy(b) {
    S.busy = b;
    chipsGroup.querySelectorAll('button.h360c-chip').forEach(function (x) { x.disabled = b; });
    askBtn.disabled = b;
    log.setAttribute('aria-busy', b ? 'true' : 'false');
  }

  // ---------------------------------------------------------------- Pick a district
  function pickDistrict() {
    closePanel(false);
    var toggle = document.querySelector(ROW_TOGGLE);
    if (!toggle) { pill.focus(); return; }
    if (toggle.getAttribute('aria-expanded') === 'false') { toggle.click(); }
    var tries = 0;
    (function look() {
      var wrap = document.querySelector(ROW_WRAPPER);
      var cid = toggle.getAttribute('aria-controls');
      var scopeNode = wrap || (cid && document.getElementById(cid)) || document;
      var search = scopeNode.querySelector('input[type="search"], input[placeholder*="Search" i]');
      if (search) {
        try { search.scrollIntoView({ block: 'center' }); } catch (e) { /* ignore */ }
        search.focus();
        return;
      }
      if (++tries < 30) { setTimeout(look, 100); } else { toggle.focus(); }
    })();
  }

  // ---------------------------------------------------------------- ask
  function ask(payload, label, opts) {
    opts = opts || {};
    if (S.busy) { return; }
    var seq = ++S.reqSeq;
    var key = scopeKey(S.scope);
    var reqBody = { org_unit_id: payload.org_unit_id != null ? String(payload.org_unit_id) : S.scope.org, reporting_month: S.scope.month || null };
    if (payload.chip_id) { reqBody.chip_id = payload.chip_id; } else { reqBody.text = payload.text; }

    if (label && !opts.noBubble) {
      var bubble = el('div', 'h360c-user', label);
      if (opts.anchor) { opts.anchor.appendChild(bubble); } else { appendToLog(bubble); }
    }
    var holder = el('div', 'h360c-card');
    holder.setAttribute('aria-busy', 'true');
    var status = el('p', 'h360c-muted', TXT.loading);
    status.setAttribute('role', 'status');
    holder.appendChild(skeletonBlock());
    holder.appendChild(status);
    if (opts.anchor) { opts.anchor.appendChild(holder); } else { appendToLog(holder); }
    scrollTo(holder);
    setBusy(true);

    var t = withTimers(function () { if (seq === S.reqSeq) { status.textContent = TXT.slow; } });
    apiFetch('/chat', { method: 'POST', body: reqBody }, t.signal).then(function (res) {
      t.done();
      if (seq !== S.reqSeq || key !== scopeKey(S.scope)) { holder.remove(); return; }
      setBusy(false);
      if (res.ok && res.data && typeof res.data === 'object') {
        var card = opts.plan ? renderPlanOnly(res.data, label) : renderAnswer(res.data, label);
        holder.replaceWith(card);
        afterRender(card);
        if (opts.onPlan && res.data.plan) { opts.onPlan(card); }
        return;
      }
      var msg = statusMessage(res);
      if (!msg && payload.text && res.status >= 400 && res.status < 500) { msg = TXT.noMatch; }
      var err = errorCard(msg, function () { err.remove(); ask(payload, label, { noBubble: true, anchor: opts.anchor, plan: opts.plan, onPlan: opts.onPlan }); });
      holder.replaceWith(err);
      afterRender(err);
    }, function () {
      t.done();
      if (seq !== S.reqSeq) { holder.remove(); return; }
      setBusy(false);
      var err = errorCard(null, function () { err.remove(); ask(payload, label, { noBubble: true, anchor: opts.anchor, plan: opts.plan, onPlan: opts.onPlan }); });
      holder.replaceWith(err);
      afterRender(err);
    });
  }

  function skeletonBlock() {
    var w = el('div');
    w.style.display = 'flex';
    w.style.flexDirection = 'column';
    w.style.gap = '8px';
    w.setAttribute('aria-hidden', 'true');
    w.appendChild(el('div', 'h360c-skel'));
    w.appendChild(el('div', 'h360c-skel'));
    w.appendChild(el('div', 'h360c-skel'));
    return w;
  }

  function errorCard(msg, retry) {
    var card = el('div', 'h360c-card h360c-err');
    var title = el('p', 'h360c-title', msg || TXT.error);
    title.tabIndex = -1;
    title.setAttribute('data-h360-focus', '1');
    card.appendChild(title);
    if (msg === TXT.signedOut || msg === TXT.noAccess) { return card; }
    var row = el('div', 'h360c-row');
    if (msg !== TXT.noMatch) {
      var a = el('button', 'h360c-btn', TXT.tryAgain);
      a.type = 'button';
      a.addEventListener('click', retry);
      row.appendChild(a);
    }
    var b = el('button', 'h360c-btn', TXT.pickAnother);
    b.type = 'button';
    b.addEventListener('click', focusChips);
    row.appendChild(b);
    card.appendChild(row);
    return card;
  }

  function focusChips() {
    var first = chipsGroup.querySelector('button:not(:disabled)');
    if (first) {
      body.scrollTop = 0;
      first.focus({ preventScroll: true });
    }
  }

  function appendToLog(node) {
    if (honestyEl && honestyEl.parentNode === log) { log.insertBefore(node, honestyEl); } else { log.appendChild(node); }
  }

  function afterRender(card) {
    var f = card.querySelector('[data-h360-focus]');
    if (f) {
      try { f.focus({ preventScroll: true }); } catch (e) { f.focus(); }
    }
    scrollTo(card);
  }

  // Scroll only the panel body (never Grafana's page) so the node's top is in view.
  function scrollTo(node) {
    if (!node || !body.contains(node)) { return; }
    var top = node.getBoundingClientRect().top - body.getBoundingClientRect().top + body.scrollTop - 8;
    body.scrollTop = Math.max(0, top);
  }

  // Honesty line: drawn once per thread, always last (after any plan card). PD-13.
  function setHonesty(text) {
    if (!text) { return; }
    S.honesty = text;
    if (!honestyEl) { honestyEl = el('p', 'h360c-honesty'); }
    honestyEl.textContent = text;
    log.appendChild(honestyEl); // moves it to the end
  }

  function resetThread() {
    if (openCard) { openCard.pinned = false; hideCard(false); }
    S.reqSeq++;
    setBusy(false);
    log.innerHTML = '';
    honestyEl = null;
    S.honesty = null;
  }

  // ---------------------------------------------------------------- answer rendering
  function textWithNumber(text, number) {
    var p = el('p', 'h360c-p');
    var s = String(text || '');
    var tokens = [];
    if (number !== null && number !== undefined && number !== '') {
      var n = String(number);
      tokens.push(n + '%', n);
    }
    var at = -1, tok = '';
    for (var i = 0; i < tokens.length; i++) {
      at = s.indexOf(tokens[i]);
      if (at >= 0) { tok = tokens[i]; break; }
    }
    if (at < 0) {
      // Bold the first number in the sentence instead.
      var m = /\d[\d,.]*%?/.exec(s);
      if (m) { at = m.index; tok = m[0]; }
    }
    if (at < 0) { p.textContent = s; return p; }
    p.appendChild(document.createTextNode(s.slice(0, at)));
    p.appendChild(el('strong', 'h360c-num', tok));
    p.appendChild(document.createTextNode(s.slice(at + tok.length)));
    return p;
  }

  function linkInfo(l) {
    if (!l) { return null; }
    var url = typeof l === 'string' ? l : l.url;
    var href = safeHref(url);
    if (!href) { return null; }
    // The API always sends a label.
    return { href: href, label: (typeof l === 'object' && l.label) ? String(l.label) : 'Reports' };
  }

  function reportLink(l) {
    var li = linkInfo(l);
    if (!li) { return null; }
    var a = el('a', 'h360c-link');
    a.href = li.href;
    a.textContent = /^See this/i.test(li.label) ? li.label : TXT.seeIn + li.label;
    return a;
  }


  // ---------------------------------------------------------------- evidence cards (UX-10)
  // After the hearts360ai supervision prototype's hover charts: title, definition, the figure for
  // the hovered month with its counts, a small line (or table), and a band naming the place with
  // the dashboard link. Plain SVG; every number comes from the API's evidence object.
  var SVGNS = 'http://www.w3.org/2000/svg';
  var LINE = '#3D71D9', AVG = '#8E9399', TARGET = '#C2410C';
  var openCard = null, hideTimer = null, cardSeq = 0;

  function svgEl(tag, attrs) {
    var n = document.createElementNS(SVGNS, tag);
    for (var k in attrs) { if (Object.prototype.hasOwnProperty.call(attrs, k)) { n.setAttribute(k, attrs[k]); } }
    return n;
  }
  function numOf(v) { var n = parseFloat(v); return isFinite(n) ? n : null; }
  function fmtCount(v) { var n = numOf(v); return n === null ? '–' : Math.round(n).toLocaleString('en'); }
  function fmtValue(v, ev) {
    var n = numOf(v);
    if (n === null) { return '–'; }
    if (ev.unit === '%') { return (Math.abs(n) < 10 && n !== 0 ? n.toFixed(1) : String(Math.round(n))) + '%'; }
    return n.toFixed(ev.decimals || 0);
  }

  function lineChart(ev, onPick) {
    var pts = Array.isArray(ev.points) ? ev.points : [];
    var W = 300, H = 132, L = 30, R = 8, T = 22, B = 20;
    var vals = [];
    pts.forEach(function (p) { [p.value, p.average].forEach(function (v) { if (numOf(v) !== null) { vals.push(numOf(v)); } }); });
    var target = numOf(ev.target);
    if (target !== null) { vals.push(target); }
    var max = ev.unit === '%' ? 100 : Math.max(1, Math.ceil(Math.max.apply(null, vals.concat([1])) * 1.15));
    var svg = svgEl('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', tabindex: '0',
      'aria-label': (ev.title || '') + ' by ' + (pts.length && /^Q/.test(pts[0].label || '') ? 'quarter' : 'month') + '. Use the arrow keys to read each point.' });
    var x = function (i) { return pts.length < 2 ? L + (W - L - R) / 2 : L + i * (W - L - R) / (pts.length - 1); };
    var y = function (v) { return T + (H - T - B) * (1 - v / max); };
    [0, max / 2, max].forEach(function (g) {
      svg.appendChild(svgEl('line', { x1: L, x2: W - R, y1: y(g), y2: y(g), stroke: '#ECEEEF', 'stroke-width': 1 }));
      var t = svgEl('text', { x: L - 4, y: y(g) + 3, 'text-anchor': 'end', 'font-size': 9, fill: '#6E6E6E' });
      t.textContent = (ev.unit === '%' ? Math.round(g) + '%' : (max > 5 ? Math.round(g) : g.toFixed(1)));
      svg.appendChild(t);
    });
    if (target !== null) {
      svg.appendChild(svgEl('line', { x1: L, x2: W - R, y1: y(target), y2: y(target), stroke: TARGET, 'stroke-width': 2,
        'stroke-dasharray': '1 5', 'stroke-linecap': 'round', opacity: 0.8 }));
      var tl = svgEl('text', { x: W - R, y: Math.max(10, y(target) - 5), 'text-anchor': 'end', 'font-size': 10, fill: TARGET });
      tl.textContent = ev.target_label || '';
      svg.appendChild(tl);
    }
    function path(key, color, dash) {
      var d = '', on = false;
      pts.forEach(function (p, i) {
        var v = numOf(p[key]);
        if (v === null) { on = false; return; }
        d += (on ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(v).toFixed(1) + ' ';
        on = true;
      });
      if (d) { svg.appendChild(svgEl('path', { d: d, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-dasharray': dash || '', 'stroke-linejoin': 'round' })); }
    }
    var hasAvg = pts.some(function (p) { return numOf(p.average) !== null; });
    if (hasAvg) { path('average', AVG, '4 3'); }
    path('value', LINE);
    var hover = svgEl('line', { y1: T, y2: H - B, stroke: 'rgba(0,0,0,0.12)', 'stroke-width': 2, visibility: 'hidden' });
    svg.appendChild(hover);
    var dots = [];
    pts.forEach(function (p, i) {
      var lab = svgEl('text', { x: x(i), y: H - 5, 'text-anchor': 'middle', 'font-size': 9, fill: '#6E6E6E' });
      lab.textContent = String(p.label || '').replace(/-\d{4}$/, '');
      svg.appendChild(lab);
      var v = numOf(p.value);
      if (v === null) { dots.push(null); return; }
      var c = svgEl('circle', { cx: x(i), cy: y(v), r: 3.5, fill: '#fff', stroke: LINE, 'stroke-width': 2 });
      svg.appendChild(c);
      dots.push(c);
    });
    var at = pts.length - 1;
    function pick(i) {
      at = Math.max(0, Math.min(pts.length - 1, i));
      hover.setAttribute('x1', x(at)); hover.setAttribute('x2', x(at)); hover.setAttribute('visibility', 'visible');
      dots.forEach(function (d, j) { if (d) { d.setAttribute('r', j === at ? 5 : 3.5); } });
      onPick(at);
    }
    svg.addEventListener('mousemove', function (e) {
      var r = svg.getBoundingClientRect();
      var px = (e.clientX - r.left) * W / r.width;
      var best = 0, bd = Infinity;
      pts.forEach(function (p, i) { var d = Math.abs(x(i) - px); if (d < bd) { bd = d; best = i; } });
      pick(best);
    });
    svg.addEventListener('mouseleave', function () { hover.setAttribute('visibility', 'hidden'); onPick(pts.length - 1); });
    svg.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft') { e.preventDefault(); pick(at - 1); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); pick(at + 1); }
    });
    return { svg: svg, hasAvg: hasAvg };
  }

  function evidenceTable(ev) {
    var t = el('table');
    var head = el('tr');
    (ev.columns || []).forEach(function (c) { head.appendChild(el('th', null, c)); });
    t.appendChild(head);
    if (Array.isArray(ev.target)) {
      var tr = el('tr', 'h360c-target');
      ev.target.forEach(function (c) { tr.appendChild(el('td', null, c)); });
      t.appendChild(tr);
    }
    (ev.rows || []).forEach(function (r) {
      var row = el('tr', r.focus ? 'h360c-focus' : null);
      (r.cells || []).forEach(function (c, i) {
        row.appendChild(el('td', r.flag && i > 0 ? 'h360c-bad' : null, c));
      });
      t.appendChild(row);
    });
    return t;
  }

  function evidenceCard(ev, monthLabel) {
    var card = el('div', 'h360c-ev');
    card.id = 'h360c-ev-' + (++cardSeq);
    card.hidden = true;
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'false');
    card.setAttribute('aria-label', ev.title || TXT.showData);
    var x = el('button', 'h360c-x');
    x.type = 'button';
    x.setAttribute('aria-label', TXT.closeCard);
    x.innerHTML = '<span aria-hidden="true">×</span>';
    card.appendChild(el('h4', null, ev.title || ''));
    if (ev.definition) { card.appendChild(el('p', 'h360c-def', ev.definition)); }
    if (ev.kind === 'line') {
      var rate = el('div', 'h360c-rate');
      var detail = el('div', 'h360c-detail');
      detail.setAttribute('aria-live', 'polite');
      var pts = ev.points || [];
      var fill = function (i) {
        var p = pts[i] || {};
        rate.textContent = fmtValue(p.value, ev);
        var lines = [];
        if (p.num !== null && p.num !== undefined) { lines.push(fmtCount(p.num) + ' ' + (ev.num_label || '')); }
        if (p.den !== null && p.den !== undefined) { lines.push('of ' + fmtCount(p.den) + ' ' + (ev.den_label || '') + ', ' + (p.label || '')); }
        if (numOf(p.average) !== null) { lines.push('Average of all facilities: ' + fmtValue(p.average, ev)); }
        if (p.value === null || p.value === undefined) { lines = [(p.label || '') + ': too few to show']; }
        detail.innerHTML = '';
        lines.forEach(function (l) { detail.appendChild(el('div', null, l)); });
      };
      card.appendChild(rate);
      card.appendChild(detail);
      var chart = lineChart(ev, fill);
      card.appendChild(chart.svg);
      var legend = el('div', 'h360c-legend');
      var me = el('span'); me.appendChild(el('i')); me.appendChild(document.createTextNode(ev.place || ''));
      legend.appendChild(me);
      if (chart.hasAvg) {
        var av = el('span'); av.appendChild(el('i', 'h360c-avg')); av.appendChild(document.createTextNode('Average'));
        legend.appendChild(av);
      }
      card.appendChild(legend);
      fill(pts.length - 1);
    } else {
      card.appendChild(evidenceTable(ev));
    }
    var band = el('div', 'h360c-band');
    band.appendChild(el('span', null, [ev.place, monthLabel].filter(Boolean).join(' · ')));
    var li = ev.link ? { href: safeHref(ev.link.url), label: ev.link.label } : null;
    if (li && li.href) {
      var a = el('a', null, li.label + ' ↗');
      a.href = li.href;
      band.appendChild(a);
    }
    card.appendChild(band);
    card.appendChild(x);
    return { card: card, close: x };
  }

  function placeCard(card, anchor) {
    var pr = panel.getBoundingClientRect();
    var ar = anchor.getBoundingClientRect();
    card.hidden = false;
    var w = card.offsetWidth, h = card.offsetHeight, gap = 14;
    var left = pr.left - w - gap;
    var below = left < 8;
    card.classList.toggle('h360c-below', below);
    if (below) {
      left = Math.max(8, Math.min(window.innerWidth - w - 8, ar.left));
      var top = ar.bottom + 8;
      if (top + h > window.innerHeight - 8) { top = Math.max(8, ar.top - h - 8); }
      card.style.left = left + 'px'; card.style.top = top + 'px';
      return;
    }
    var t = Math.max(8, Math.min(window.innerHeight - h - 8, ar.top + ar.height / 2 - 28));
    card.style.left = left + 'px';
    card.style.top = t + 'px';
    card.style.setProperty('--h360c-arrow-y', Math.max(12, Math.min(h - 24, ar.top + ar.height / 2 - t - 7)) + 'px');
  }

  // The card's chart, link and close button join the Tab order only while the card is pinned.
  function cardTabs(card, on) {
    card.querySelectorAll('svg[tabindex], a, button').forEach(function (n) { n.setAttribute('tabindex', on ? '0' : '-1'); });
  }

  function hideCard(returnFocus) {
    clearTimeout(hideTimer);
    if (!openCard) { return; }
    var o = openCard;
    openCard = null;
    o.card.hidden = true;
    cardTabs(o.card, false);
    o.anchor.setAttribute('aria-expanded', 'false');
    if (returnFocus) { o.anchor.focus(); }
  }

  function showCard(o) {
    clearTimeout(hideTimer);
    if (openCard && openCard !== o) { hideCard(false); }
    openCard = o;
    o.anchor.setAttribute('aria-expanded', 'true');
    placeCard(o.card, o.anchor);
  }

  function hideSoon() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(function () {
      if (!openCard || openCard.pinned) { return; }
      var a = document.activeElement;
      if (a && (openCard.card.contains(a) || a === openCard.anchor)) { return; }
      hideCard(false);
    }, 200);
  }

  // Wires a figure (a button) to its evidence card, which follows it in the DOM so Tab reaches the link.
  function attachEvidence(anchor, ev, monthLabel, host) {
    var built = evidenceCard(ev, monthLabel);
    var o = { anchor: anchor, card: built.card, pinned: false };
    anchor.setAttribute('aria-expanded', 'false');
    anchor.setAttribute('aria-controls', built.card.id);
    anchor.setAttribute('aria-haspopup', 'dialog');
    anchor.addEventListener('mouseenter', function () { showCard(o); });
    anchor.addEventListener('mouseleave', hideSoon);
    anchor.addEventListener('focus', function () { showCard(o); });
    anchor.addEventListener('blur', hideSoon);
    anchor.addEventListener('click', function (e) {
      e.preventDefault();
      if (openCard === o && o.pinned) { o.pinned = false; hideCard(false); return; }
      o.pinned = true;
      showCard(o);
      cardTabs(o.card, true);
    });
    built.card.addEventListener('mouseenter', function () { clearTimeout(hideTimer); });
    built.card.addEventListener('mouseleave', hideSoon);
    built.card.addEventListener('focusout', hideSoon);
    built.close.addEventListener('click', function () { o.pinned = false; hideCard(true); });
    cardTabs(built.card, false);
    host.appendChild(built.card);
    return o;
  }

  function figButton(text) {
    var b = el('button', 'h360c-fig', text);
    b.type = 'button';
    return b;
  }

  // A sentence with its figure as the evidence button; else the first number bold and a
  // `Show the data` button after it (for example when Claude reworded around the figure).
  function evidenceText(text, figure, number, ev, monthLabel, host, srPrefix) {
    var p = el('p', 'h360c-p');
    if (srPrefix) { p.appendChild(el('span', 'h360c-sr', srPrefix)); }
    var s = String(text || '');
    var at = ev && figure ? s.indexOf(figure) : -1;
    if (at < 0) {
      var plain = textWithNumber(s, number);
      while (plain.firstChild) { p.appendChild(plain.firstChild); }
      if (ev) {
        p.appendChild(document.createTextNode(' '));
        var sd = el('button', 'h360c-showdata', TXT.showData);
        sd.type = 'button';
        p.appendChild(sd);
        attachEvidence(sd, ev, monthLabel, p);
      }
      return p;
    }
    p.appendChild(document.createTextNode(s.slice(0, at)));
    var b = figButton(figure);
    b.setAttribute('aria-label', figure + ', ' + TXT.showData.toLowerCase() + ': ' + (ev.title || ''));
    p.appendChild(b);
    p.appendChild(document.createTextNode(s.slice(at + figure.length)));
    // The card goes right after the sentence's text, so Tab moves from the figure into its link.
    attachEvidence(b, ev, monthLabel, p);
    return p;
  }

  function renderAnswer(d, question) {
    if (d.place || d.month) { setHeader(d.place || (S.chipsData && S.chipsData.place), d.month || (S.chipsData && S.chipsData.month)); }
    setBadge(d.mode);
    var card = el('div', 'h360c-card');
    var pname = placeName(d.place) || placeName(S.chipsData && S.chipsData.place);

    // 1. Title and control line (`title` and `control_line` from the API; else the question asked).
    var title = el('h3', 'h360c-title', d.title || question || pname || TXT.dialog);
    title.tabIndex = -1;
    title.setAttribute('data-h360-focus', '1');
    card.appendChild(title);
    var m = fmtMonth(d.month);
    if (d.control_line) {
      var cl = evidenceText(d.control_line, d.control_figure, null, d.control_evidence || null, m, card);
      cl.className = 'h360c-muted';
      card.appendChild(cl);
    }
    else if (pname || m) { card.appendChild(el('p', 'h360c-muted', [pname, m].filter(Boolean).join(' \u00b7 '))); }
    if (d.mode === 'offline_fallback') { card.appendChild(el('p', 'h360c-muted', TXT.fallback)); }

    // Stock first (UX-09): read before any stepping-up or calling advice.
    if (d.stock_line) {
      var st = el('div', 'h360c-stock');
      st.appendChild(evidenceText(d.stock_line, null, null, d.stock_evidence || null, m, st));
      card.appendChild(st);
    }

    // 2. Reasons (max three).
    var reasons = Array.isArray(d.reasons) ? d.reasons.slice(0, 3) : [];
    var seen = {};
    if (reasons.length === 1 && !reasons[0].what_to_do && !reasons[0].link) {
      card.appendChild(textWithNumber(reasons[0].text, reasons[0].number));
    } else if (reasons.length) {
      var ol = el('ol', 'h360c-reasons');
      reasons.forEach(function (r, i) {
        if (!r) { return; }
        var li = el('li', 'h360c-reason');
        li.appendChild(el('span', 'h360c-rank', String(i + 1))).setAttribute('aria-hidden', 'true');
        var box = el('div', 'h360c-rtext');
        // No `Reason 1:` label: the ordered list already numbers the reasons.
        var p = evidenceText(r.text, r.figure, r.number, r.evidence || null, m, box);
        if (r.tag) { p.insertBefore(el('span', 'h360c-tag', r.tag), p.firstChild); }
        box.appendChild(p);
        if (r.what_to_do) {
          box.appendChild(el('p', 'h360c-wtd', TXT.whatToDo));
          box.appendChild(el('p', 'h360c-p', r.what_to_do));
        }
        var a = reportLink(r.link);
        if (a) { seen[a.getAttribute('href')] = 1; box.appendChild(a); }
        li.appendChild(box);
        ol.appendChild(li);
      });
      card.appendChild(ol);
    }

    // Inline plan (who_to_call returns the plan with the answer).
    var planNode = null;
    if (d.plan) { planNode = planCard(d.plan, pname, d.reasons && d.reasons[0] && d.reasons[0].evidence, m); }

    // 3. Nudge button (a link when the API sends `nudge.url`).
    var nudgeHref = d.nudge && d.nudge.label ? safeHref(d.nudge.url) : null;
    if (nudgeHref) {
      var na = el('a', 'h360c-btn', d.nudge.label);
      na.href = nudgeHref;
      card.appendChild(na);
    } else if (d.nudge && d.nudge.label) {
      var nb = el('button', 'h360c-btn', d.nudge.label);
      nb.type = 'button';
      var planTarget = null;
      nb.addEventListener('click', function () {
        if (planTarget) { scrollTo(planTarget); var f = planTarget.querySelector('[data-h360-focus]'); if (f) { f.focus(); } return; }
        if (S.busy) { return; }
        var anchor = el('div', 'h360c-log');
        card.parentNode && card.parentNode.insertBefore(anchor, card.nextSibling);
        ask({ chip_id: d.nudge.chip_id, org_unit_id: d.nudge.org_unit_id }, d.nudge.label, {
          anchor: anchor,
          plan: true,
          onPlan: function (node) { planTarget = node; }
        });
      });
      card.appendChild(nb);
    }

    // Report links from `links` (deduplicated against the reason links).
    (Array.isArray(d.links) ? d.links : []).forEach(function (l) {
      var a = reportLink(l);
      if (a && !seen[a.getAttribute('href')]) { seen[a.getAttribute('href')] = 1; card.appendChild(a); }
    });

    // 4. Also check.
    if (d.also_check) {
      var also = el('p', 'h360c-also');
      also.appendChild(el('span', null, '\u25c6 ')).setAttribute('aria-hidden', 'true');
      var s = String(d.also_check);
      also.appendChild(document.createTextNode(/^Also check/i.test(s) ? s : TXT.alsoCheck + s));
      card.appendChild(also);
    }


    var wrap = card;
    if (planNode) {
      wrap = el('div', 'h360c-log');
      wrap.appendChild(card);
      wrap.appendChild(planNode);
    }
    setHonesty(d.honesty);
    return wrap;
  }

  // Result of a nudge: the plan card, or a normal answer card if there is no plan.
  function renderPlanOnly(d, label) {
    setBadge(d.mode);
    var pname = placeName(d.place) || placeName(S.chipsData && S.chipsData.place);
    var node;
    if (d.plan) {
      node = planCard(d.plan, pname, d.reasons && d.reasons[0] && d.reasons[0].evidence, fmtMonth(d.month));
      if (d.mode === 'offline_fallback') { node.insertBefore(el('p', 'h360c-muted', TXT.fallback), node.children[1] || null); }
      setHonesty(d.honesty);
    } else {
      node = renderAnswer(d, label);
    }
    return node;
  }

  // UX-08: a plan sized to one nurse's week, with how the number was chosen; the whole list is
  // context, not the target. UX-12: above facility level the link opens the Overdue calls table.
  function planCard(plan, pname, ev, monthLabel) {
    var card = el('div', 'h360c-card');
    var title = el('h3', 'h360c-title', 'Calling plan' + (pname ? ' for ' + pname : ''));
    title.tabIndex = -1;
    title.setAttribute('data-h360-focus', '1');
    card.appendChild(title);
    var tot = el('div');
    // The API always sends per_week and list_link.
    tot.appendChild(el('div', 'h360c-big', String(plan.per_week) + ' ' + TXT.planUnit));
    tot.appendChild(el('p', 'h360c-muted', fmtCount(plan.total) + TXT.planTotal));
    card.appendChild(tot);
    var weeks = Array.isArray(plan.weeks) ? plan.weeks.slice(0, 4) : [];
    if (weeks.length) {
      var g = el('div', 'h360c-weeks');
      weeks.forEach(function (w, i) {
        var c = el('div', 'h360c-week');
        c.appendChild(el('span', null, 'Week ' + (i + 1)));
        c.appendChild(el('strong', null, String(w)));
        g.appendChild(c);
      });
      card.appendChild(g);
    }
    if (plan.text) { card.appendChild(el('p', 'h360c-plan-basis', plan.text)); }
    var ll = plan.list_link && safeHref(plan.list_link.url);
    if (ll) {
      var a = el('a', 'h360c-link', plan.list_link.label);
      a.href = ll;
      card.appendChild(a);
    }
    if (ev) {
      var holder = el('div');
      var sd = el('button', 'h360c-showdata', TXT.showData);
      sd.type = 'button';
      holder.appendChild(sd);
      card.appendChild(holder);
      attachEvidence(sd, ev, monthLabel, holder);
    }
    return card;
  }

  // ---------------------------------------------------------------- clearance (PD-15)
  var clearedNode = null;
  function applyClearance() {
    var found = null;
    for (var i = 0; i < CLEAR_SELECTORS.length && !found; i++) {
      try { found = document.querySelector(CLEAR_SELECTORS[i]); } catch (e) { found = null; }
    }
    if (found !== clearedNode) {
      if (clearedNode && clearedNode.classList) { clearedNode.classList.remove('h360c-clearance'); }
      clearedNode = found;
    }
    if (found) {
      if (!found.classList.contains('h360c-clearance')) { found.classList.add('h360c-clearance'); }
      root.classList.remove('h360c-iconly');
    } else {
      root.classList.add('h360c-iconly');
    }
  }

  // ---------------------------------------------------------------- URL watch
  function checkUrl() {
    var cur = location.pathname + location.search;
    if (cur !== S.lastPath) {
      S.lastPath = cur;
      var s = readScope();
      if (scopeKey(s) !== scopeKey(S.scope)) {
        S.scope = s;
        resetThread();
        S.chipsFor = null;
        if (isOpen()) { ensureChips(); }
      }
    }
    applyClearance();
  }

  // ---------------------------------------------------------------- start
  function start() {
    if (!document.body) { return setTimeout(start, 50); }
    build();
    applyClearance();
    if (ssGet(STORE_OPEN) === '1') { openPanel(false); }
    window.addEventListener('popstate', checkUrl);
    setInterval(checkUrl, 1000);
    document.addEventListener('keydown', function (ev) {
      if ((ev.key === 'Escape' || ev.key === 'Esc') && openCard) {
        ev.preventDefault();
        ev.stopPropagation();
        var back = root.contains(document.activeElement);
        openCard.pinned = false;
        hideCard(back);
        return;
      }
      if ((ev.key === 'Escape' || ev.key === 'Esc') && isOpen() && root.contains(document.activeElement)) {
        ev.preventDefault();
        ev.stopPropagation();
        closePanel(true);
      }
    }, true);
  }

  start();
})();
