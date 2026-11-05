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
 *
 * H360_API defaults to <page protocol>//<page hostname>:8090. To point it elsewhere:
 *   - set window.H360_API = 'http://host:port' (console or another script), or
 *   - open any Grafana page with ?h360_api=http://<same hostname>:<port> once; the value is kept
 *     in sessionStorage for the tab. Only the page's own hostname is accepted this way.
 *     ?h360_api=default clears it.
 */
(function () {
  'use strict';

  if (window.__h360ChatWidget) { return; }
  window.__h360ChatWidget = true;

  var boot = window.grafanaBootData;
  if (!boot || !boot.user || !boot.user.isSignedIn) { return; }

  // ---------------------------------------------------------------- constants
  var STORE_OPEN = 'h360.chat.open';
  var STORE_API = 'h360.chat.api';
  var MAX_TEXT = 200;
  var SLOW_MS = 3000;
  var GIVE_UP_MS = 10000;
  var CLEAR_SELECTORS = [
    // Grafana 13 dashboard scroll container (dashboard scene with sidebar splitter).
    '[data-testid="data-testid DashboardSidebarSplitter body container"]'
  ];
  var ROW_TOGGLE = '[data-testid="data-testid dashboard-row-toggle-for-Change location"], button[aria-label="Expand row Change location"], button[aria-label="Collapse row Change location"]';
  var ROW_WRAPPER = '[data-testid="data-testid dashboard-row-wrapper-for-Change location"]';
  var TAB_NAMES = {
    'Right-medicines': 'Right medicines',
    'Stepping-up': 'Stepping up',
    'BP-readings-check': 'BP readings check',
    'Statins': 'Statins',
    'Overdue-calls': 'Overdue calls'
  };
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var TXT = {
    pill: 'Ask HEARTS360',
    openLabel: 'Open HEARTS360 assistant',
    dialog: 'HEARTS360 assistant',
    close: 'Close HEARTS360 assistant',
    htnOnly: 'Hypertension only',
    intro: 'Pick a question. I answer from your reports.',
    national: 'Pick a district or a facility to ask a question.',
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
    planStart: 'Start with the patients overdue longest.',
    planOpen: 'Open the overdue list',
    planUnit: 'overdue and have a phone',
    emptyChips: 'No questions are ready for this place yet.'
  };

  // ---------------------------------------------------------------- helpers
  function ssGet(k) { try { return window.sessionStorage.getItem(k); } catch (e) { return null; } }
  function ssSet(k, v) { try { window.sessionStorage.setItem(k, v); } catch (e) { /* ignore */ } }
  function ssDel(k) { try { window.sessionStorage.removeItem(k); } catch (e) { /* ignore */ } }

  (function readApiParam() {
    var v;
    try { v = new URLSearchParams(location.search).get('h360_api'); } catch (e) { v = null; }
    if (v === null) { return; }
    if (v === '' || v === 'default') { ssDel(STORE_API); return; }
    try {
      var u = new URL(v);
      if ((u.protocol === 'http:' || u.protocol === 'https:') && u.hostname === location.hostname) {
        ssSet(STORE_API, u.origin);
      }
    } catch (e) { /* ignore bad value */ }
  })();

  function apiBase() {
    if (typeof window.H360_API === 'string' && window.H360_API) { return window.H360_API.replace(/\/+$/, ''); }
    var s = ssGet(STORE_API);
    if (s) { return s; }
    return location.protocol + '//' + location.hostname + ':8090';
  }

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

  function tabNameFromUrl(u) {
    var m = /[?&]-?dtab=([^&#]+)/.exec(u || '');
    if (m) {
      var slug = decodeURIComponent(m[1]);
      return TAB_NAMES[slug] || slug.replace(/-/g, ' ');
    }
    return null;
  }

  // ---------------------------------------------------------------- URL scope
  function readScope() {
    var q;
    try { q = new URLSearchParams(location.search); } catch (e) { q = null; }
    var org = q ? (q.get('var-org_unit') || '') : '';
    if (org === '$__all' || org === 'All') { org = ''; }
    var onReports = /\/d\/heart360_reports(\/|$)/.test(location.pathname);
    var month = (onReports && q) ? (q.get('var-reporting_month') || '') : '';
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
    return fetch(apiBase() + path, {
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
    chipsIntro.textContent = national ? TXT.national : TXT.intro;
    var chips = Array.isArray(d.chips) ? d.chips : [];
    if (!chips.length) {
      chipsGroup.appendChild(el('p', 'h360c-p', TXT.emptyChips));
      return;
    }
    chips.forEach(function (c) {
      if (!c || !c.label) { return; }
      var b = el('button', 'h360c-chip', c.label);
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
    var label = (typeof l === 'object' && l.label) ? String(l.label) : null;
    var tab = tabNameFromUrl(href);
    if (!label) { label = tab || 'Reports'; }
    return { href: href, label: label };
  }

  function reportLink(l) {
    var li = linkInfo(l);
    if (!li) { return null; }
    var a = el('a', 'h360c-link');
    a.href = li.href;
    a.textContent = /^See this/i.test(li.label) ? li.label : TXT.seeIn + li.label;
    return a;
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
    if (d.control_line) { card.appendChild(el('p', 'h360c-muted', d.control_line)); }
    else if (pname || m) { card.appendChild(el('p', 'h360c-muted', [pname, m].filter(Boolean).join(' \u00b7 '))); }
    if (d.mode === 'offline_fallback') { card.appendChild(el('p', 'h360c-muted', TXT.fallback)); }

    // 2. Reasons (max three).
    var reasons = Array.isArray(d.reasons) ? d.reasons.slice(0, 3) : [];
    var seen = {};
    if (reasons.length === 1 && !reasons[0].what_to_do && !reasons[0].link && reasons.length) {
      card.appendChild(textWithNumber(reasons[0].text, reasons[0].number));
    } else if (reasons.length) {
      var ol = el('ol', 'h360c-reasons');
      reasons.forEach(function (r, i) {
        if (!r) { return; }
        var li = el('li', 'h360c-reason');
        li.appendChild(el('span', 'h360c-rank', String(i + 1))).setAttribute('aria-hidden', 'true');
        var box = el('div', 'h360c-rtext');
        var sr = el('span', 'h360c-sr', 'Reason ' + (i + 1) + ': ');
        var p = textWithNumber(r.text, r.number);
        p.insertBefore(sr, p.firstChild);
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
    if (d.plan) { planNode = planCard(d.plan, pname, d.links); }

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

    // 5. Stock callout.
    if (d.stock_line) { card.appendChild(el('p', 'h360c-stock', d.stock_line)); }

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
      node = planCard(d.plan, pname, d.links);
      if (d.mode === 'offline_fallback') { node.insertBefore(el('p', 'h360c-muted', TXT.fallback), node.children[1] || null); }
      setHonesty(d.honesty);
    } else {
      node = renderAnswer(d, label);
    }
    return node;
  }

  function overdueHref(links) {
    var arr = Array.isArray(links) ? links : [];
    for (var i = 0; i < arr.length; i++) {
      var li = linkInfo(arr[i]);
      if (li && (/overdue list/i.test(li.label) || /dtab=Overdue-list/i.test(li.href))) { return li.href; }
    }
    var p = new URLSearchParams();
    p.set('var-org_unit', S.scope.org);
    p.set('-dtab', 'Overdue-list');
    return '/d/heart360_showcase?' + p.toString();
  }

  function planCard(plan, pname, links) {
    var card = el('div', 'h360c-card');
    var title = el('h3', 'h360c-title', 'Calling plan' + (pname ? ' for ' + pname : ''));
    title.tabIndex = -1;
    title.setAttribute('data-h360-focus', '1');
    card.appendChild(title);
    var tot = el('div');
    tot.appendChild(el('div', 'h360c-big', String(plan.total) + (plan.total === 1 ? ' patient' : ' patients')));
    tot.appendChild(el('p', 'h360c-muted', TXT.planUnit));
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
    if (plan.text && String(plan.text).trim() !== TXT.planStart) { card.appendChild(el('p', 'h360c-p', plan.text)); }
    card.appendChild(el('p', 'h360c-p', TXT.planStart));
    var a = el('a', 'h360c-link', TXT.planOpen);
    a.href = overdueHref(links);
    card.appendChild(a);
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
      if ((ev.key === 'Escape' || ev.key === 'Esc') && isOpen() && root.contains(document.activeElement)) {
        ev.preventDefault();
        ev.stopPropagation();
        closePanel(true);
      }
    }, true);
  }

  start();
})();
