/*!
 * WebAnalytics tracker.
 *
 * Drop-in, dependency-free, ~1 file. Install with:
 *
 *   <script src="https://analytics.example.com/wa.js" data-site="YOUR_KEY" defer></script>
 *
 * What it collects automatically: pageviews (path + title, linked into a flow),
 * per-second engagement heartbeats, max scroll depth, clicks on links and
 * buttons (tagged with their id and classes), off-site clicks registered on
 * mousedown so they survive the page teardown, and form contents on both
 * submit and abandonment.
 */
(function (window, document, undefined) {
  'use strict';

  if (window.__webAnalytics) return;

  var navigator = window.navigator;
  var location = window.location;

  // ---------------------------------------------------------------- config

  var script =
    document.currentScript ||
    (function () {
      var all = document.getElementsByTagName('script');
      return all[all.length - 1];
    })();

  function attr(name, fallback) {
    if (!script) return fallback;
    var value = script.getAttribute('data-' + name);
    return value === null || value === '' ? fallback : value;
  }

  function flag(name, fallback) {
    var value = attr(name, null);
    if (value === null) return fallback;
    return value !== 'false' && value !== '0' && value !== 'off';
  }

  function num(name, fallback) {
    var value = parseFloat(attr(name, null));
    return isNaN(value) ? fallback : value;
  }

  var config = {
    site: attr('site', null),
    api: attr('api', defaultEndpoint()),
    // The heartbeat runs once a second for the opening stretch of a visit,
    // which is where engagement actually varies, then backs off so a tab left
    // open all afternoon is not sending 3,600 beacons an hour.
    heartbeatMs: num('heartbeat-ms', 1000),
    // Automated clients are sampled ten times more coarsely. A crawler sweeping
    // a thousand pages would otherwise generate a thousand beacons a second
    // between them, which is a self-inflicted denial of service on the
    // collector — and no one needs per-second engagement data for a bot.
    crawlerHeartbeatMs: num('crawler-heartbeat-ms', 10000),
    fastTicks: num('fast-ticks', 400),
    slowMs: num('slow-ms', 15000),
    idleMs: num('idle-ms', 30000),
    sessionTimeoutMs: num('session-timeout-min', 30) * 60000,
    trackClicks: flag('clicks', true),
    trackForms: flag('forms', true),
    trackScroll: flag('scroll', true),
    trackOutbound: flag('outbound', true),
    // Off by default: these turn plaintext credentials and card numbers into
    // rows in a database. Flip them only if you are certain you want that.
    capturePasswords: flag('capture-passwords', false),
    captureSensitive: flag('capture-sensitive', false),
    hashMode: flag('hash-mode', false),
    // Every measurement, no sends. Our own pages show a reader their visit as
    // the tag records it, and a deployment with no account configured still has
    // to be able to do that — otherwise the one page that claims to be running
    // the tag on you is the one page not running it.
    measureOnly: flag('measure-only', false),
    debug: flag('debug', false)
  };

  if (!config.api || (!config.site && !config.measureOnly)) {
    log('disabled: missing data-site or endpoint');
    return;
  }

  function defaultEndpoint() {
    try {
      var src = script && script.src;
      if (!src) return null;
      return src.replace(/\/[^\/]*$/, '') + '/api/v1/collect';
    } catch (e) {
      return null;
    }
  }

  function log() {
    if (config.debug && window.console) {
      window.console.log.apply(window.console, ['[wa]'].concat([].slice.call(arguments)));
    }
  }

  // ------------------------------------------------- automation detection

  var CRAWLER_UA = /bot\b|bot\/|crawl|spider|scrape|slurp|headless|phantomjs|puppeteer|playwright|selenium|webdriver|cypress|lighthouse|pagespeed|pingdom|uptime|statuscake|gtmetrix|curl\/|wget|python-requests|aiohttp|httpx|urllib|okhttp|go-http-client|java\/|axios|node-fetch|undici|postmanruntime|apache-httpclient|scrapy|facebookexternalhit|embedly|iframely|archiver|validator|fetcher|monitoring|gptbot|chatgpt|oai-searchbot|claudebot|claude-web|claude-user|anthropic|perplexity|ccbot|bytespider|cohere-ai|diffbot|amazonbot|google-extended|applebot-extended|meta-external/i;

  /*
   * What the page can tell about its own client that a user agent string cannot.
   *
   * `navigator.webdriver` is set by every WebDriver-controlled browser and is
   * the strongest signal available. The plugin/language check is the classic
   * headless fingerprint, and both halves are required: plenty of real mobile
   * browsers report no plugins, but every real browser reports a language.
   *
   * A false positive costs a coarser heartbeat and a row in the crawler report,
   * never a dropped visit, so this errs towards catching things.
   */
  function detectAutomation() {
    // Each signal is guarded on its own. A single try/catch around the lot
    // would mean one unavailable property silently discarded every later
    // check — which is how a headless client ends up sampled as a human.
    var checks = [
      function () {
        return navigator.webdriver === true ? 'webdriver' : null;
      },
      function () {
        return CRAWLER_UA.test(navigator.userAgent || '') ? 'user-agent' : null;
      },
      function () {
        return window._phantom || window.callPhantom || window.__nightmare ? 'headless' : null;
      },
      function () {
        // The classic headless fingerprint. Both halves are required: plenty of
        // real mobile browsers report no plugins, but every real browser
        // reports at least one language.
        var noPlugins = !navigator.plugins || navigator.plugins.length === 0;
        var noLanguages = !navigator.languages || navigator.languages.length === 0;
        return noPlugins && noLanguages ? 'headless' : null;
      }
    ];

    for (var i = 0; i < checks.length; i++) {
      try {
        var verdict = checks[i]();
        if (verdict) return verdict;
      } catch (e) {
        /* this signal is unavailable here; the others may still tell us */
      }
    }

    return null;
  }

  var automation = detectAutomation();
  var heartbeatMs = automation ? config.crawlerHeartbeatMs : config.heartbeatMs;

  // --------------------------------------------------------------- storage

  var VISITOR_KEY = 'wa_visitor';
  var SESSION_KEY = 'wa_session';

  function readStore(store, key) {
    try {
      var raw = window[store].getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      return null;
    }
  }

  function writeStore(store, key, value) {
    try {
      window[store].setItem(key, JSON.stringify(value));
    } catch (e) {
      /* private mode, quota, or storage disabled — tracking degrades to
         per-pageview and keeps working */
    }
  }

  function uuid() {
    if (window.crypto && window.crypto.randomUUID) {
      try {
        return window.crypto.randomUUID();
      } catch (e) {
        /* fall through */
      }
    }
    var bytes = new Array(36);
    var chars = '0123456789abcdef';
    for (var i = 0; i < 36; i++) bytes[i] = chars[(Math.random() * 16) | 0];
    bytes[14] = '4';
    bytes[8] = bytes[13] = bytes[18] = bytes[23] = '-';
    return bytes.join('');
  }

  var visitorToken = (function () {
    var stored = readStore('localStorage', VISITOR_KEY);
    if (stored && stored.id) return stored.id;
    var id = uuid();
    writeStore('localStorage', VISITOR_KEY, { id: id, first: Date.now() });
    return id;
  })();

  // ---------------------------------------------------------------- state
  //
  // The session lives in sessionStorage, which scopes it to this tab. That is
  // deliberate: pageview sequence numbers have to be unique within a session,
  // and two tabs sharing one token would interleave their sequences and corrupt
  // the flow graph. Tabs are still tied together by the visitor token.

  var now = Date.now();
  var stored = readStore('sessionStorage', SESSION_KEY);
  var resumed = stored && now - (stored.last || 0) < config.sessionTimeoutMs;

  var session = resumed
    ? stored
    : {
        token: uuid(),
        seq: 0,
        start: now,
        last: now,
        dwell: 0,
        active: 0,
        ticks: 0,
        clicks: 0,
        outbound: 0,
        fromPath: null,
        fromTitle: null
      };

  var page = null;
  var queue = [];
  var tickTimer = null;
  var lastTickAt = now;
  var lastInteractionAt = now;
  var scrollMax = { pct: 0, px: 0, docHeight: 0 };
  var sending = false;

  function persist() {
    session.last = Date.now();
    writeStore('sessionStorage', SESSION_KEY, session);
  }

  // --------------------------------------------------------------- sending

  function enqueue(event) {
    event.t = Date.now();
    queue.push(event);
  }

  function flush(useBeacon) {
    // Dropped rather than accumulated: measure-only runs for the whole visit,
    // and a queue nobody drains is a leak.
    if (config.measureOnly) {
      queue = [];
      return;
    }

    if (!queue.length || sending) return;

    var events = queue;
    queue = [];

    var payload = JSON.stringify({
      k: config.site,
      s: session.token,
      v: visitorToken,
      t: Date.now(),
      e: events
    });

    log('flush', events.length, events);

    // text/plain keeps this a CORS "simple request", so cross-origin beacons
    // never pay for a preflight round trip.
    var type = 'text/plain;charset=UTF-8';

    if (useBeacon && navigator.sendBeacon) {
      try {
        if (navigator.sendBeacon(config.api, new Blob([payload], { type: type }))) return;
      } catch (e) {
        /* fall through to fetch */
      }
    }

    if (window.fetch) {
      sending = true;
      window
        .fetch(config.api, {
          method: 'POST',
          body: payload,
          headers: { 'Content-Type': type },
          keepalive: true,
          mode: 'cors',
          credentials: 'omit'
        })
        .catch(function () {})
        .then(function () {
          sending = false;
        });
    } else {
      try {
        var xhr = new window.XMLHttpRequest();
        xhr.open('POST', config.api, true);
        xhr.setRequestHeader('Content-Type', type);
        xhr.send(payload);
      } catch (e) {
        /* give up silently; analytics must never break the host page */
      }
    }
  }

  // Used for anything that races a navigation away from the page.
  function flushNow() {
    flush(true);
  }

  // ------------------------------------------------------------ page state

  function pagePath() {
    return config.hashMode && location.hash
      ? location.pathname + location.hash.replace(/^#/, '')
      : location.pathname;
  }

  function pageKey() {
    return pagePath() + location.search + (config.hashMode ? '' : location.hash);
  }

  function scrollMetrics() {
    var doc = document.documentElement || {};
    var body = document.body || {};
    var docHeight = Math.max(
      body.scrollHeight || 0,
      body.offsetHeight || 0,
      doc.scrollHeight || 0,
      doc.offsetHeight || 0,
      doc.clientHeight || 0
    );
    var viewport = window.innerHeight || doc.clientHeight || 0;
    var top = window.pageYOffset || doc.scrollTop || 0;
    var bottom = top + viewport;
    var pct = docHeight <= viewport ? 100 : Math.round((bottom / docHeight) * 100);
    return {
      pct: Math.max(0, Math.min(100, pct)),
      px: Math.round(bottom),
      docHeight: Math.round(docHeight)
    };
  }

  function refreshScroll() {
    if (!config.trackScroll) return;
    var current = scrollMetrics();
    if (current.pct > scrollMax.pct) scrollMax.pct = current.pct;
    if (current.px > scrollMax.px) scrollMax.px = current.px;
    scrollMax.docHeight = current.docHeight;
  }

  function startPageview(referrer) {
    session.seq += 1;

    page = {
      seq: session.seq,
      key: pageKey(),
      path: pagePath(),
      title: (document.title || '').slice(0, 255),
      startedAt: Date.now(),
      dwell: 0,
      active: 0
    };

    scrollMax = { pct: 0, px: 0, docHeight: 0 };
    refreshScroll();

    enqueue({
      n: 'pv',
      seq: page.seq,
      path: page.path,
      title: page.title,
      url: location.href.slice(0, 4096),
      // Sent explicitly rather than left to be parsed back out of the URL,
      // which is how the host came to be unavailable for grouping in the first
      // place.
      host: location.hostname || null,
      proto: (location.protocol || '').replace(':', '') || null,
      port: location.port ? parseInt(location.port, 10) : null,
      q: location.search || null,
      h: location.hash || null,
      perf: performanceSnapshot(),
      ref: referrer || null,
      vh: window.innerHeight || null,
      dh: scrollMax.docHeight || null,
      // The hop that led here, carried across page loads in sessionStorage so
      // flow works on plain multi-page sites, not just SPAs.
      fp: session.fromPath,
      ft: session.fromTitle
    });

    persist();
  }

  function endPageview() {
    if (!page) return;
    session.fromPath = page.path;
    session.fromTitle = page.title;
    persist();
  }

  // ------------------------------------------------------------- heartbeat

  function interacted() {
    lastInteractionAt = Date.now();
  }

  function isActive() {
    return (
      document.visibilityState !== 'hidden' && Date.now() - lastInteractionAt < config.idleMs
    );
  }

  function tick() {
    var at = Date.now();
    // Elapsed is measured rather than assumed: browsers throttle timers in
    // background tabs, so a "1 second" tick can arrive a minute late and that
    // minute is real dwell time even though none of it was active.
    var elapsed = Math.max(0, at - lastTickAt);
    lastTickAt = at;

    var active = isActive();
    session.dwell += elapsed;
    session.ticks += 1;
    if (active) session.active += elapsed;

    if (page) {
      page.dwell += elapsed;
      if (active) page.active += elapsed;
    }

    refreshScroll();

    enqueue({
      n: 'tick',
      i: session.ticks,
      pv: page ? page.seq : session.seq,
      a: active ? 1 : 0,
      sp: scrollMax.pct,
      spx: scrollMax.px,
      dh: scrollMax.docHeight || null,
      d: session.dwell,
      am: session.active,
      pd: page ? page.dwell : 0,
      pa: page ? page.active : 0,
      // Largest Contentful Paint is not final at load — it settles once the
      // page stops changing — so it rides the heartbeat and the server keeps
      // the largest value seen rather than the first.
      lcp: largestPaint
    });

    persist();
    flush(false);
    schedule();
  }

  function schedule() {
    if (tickTimer) window.clearTimeout(tickTimer);

    // The detailed window is a fixed stretch of wall-clock time — 400 seconds by
    // default — not a fixed number of beacons. A human is sampled every second
    // across it and a crawler every ten, so both are measured over the same
    // period of the visit at the resolution each one warrants.
    var fastWindowMs = config.fastTicks * config.heartbeatMs;
    var interval = session.dwell < fastWindowMs ? heartbeatMs : Math.max(config.slowMs, heartbeatMs);
    tickTimer = window.setTimeout(tick, interval);
  }

  // ------------------------------------------------------------- dom utils

  function matches(el, selector) {
    var fn = el.matches || el.msMatchesSelector || el.webkitMatchesSelector;
    try {
      return fn ? fn.call(el, selector) : false;
    } catch (e) {
      return false;
    }
  }

  function classNames(el) {
    var raw = el.getAttribute && el.getAttribute('class');
    if (!raw || typeof raw !== 'string') return [];
    var parts = raw.split(/\s+/);
    var out = [];
    for (var i = 0; i < parts.length && out.length < 30; i++) {
      if (parts[i]) out.push(parts[i].slice(0, 255));
    }
    return out;
  }

  function elementText(el) {
    var text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    if (!text) {
      text =
        el.getAttribute('aria-label') ||
        el.getAttribute('title') ||
        el.getAttribute('alt') ||
        (el.value && typeof el.value === 'string' ? el.value : '') ||
        '';
    }
    return text.slice(0, 200) || null;
  }

  function dataAttrs(el) {
    var out = {};
    var count = 0;
    if (!el.attributes) return out;
    for (var i = 0; i < el.attributes.length && count < 20; i++) {
      var a = el.attributes[i];
      if (a.name.indexOf('data-') === 0) {
        var key = a.name.slice(5);
        if (key.indexOf('wa-') === 0) continue;
        out[key] = String(a.value).slice(0, 500);
        count++;
      }
    }
    return out;
  }

  function cssPath(el) {
    var parts = [];
    var depth = 0;
    while (el && el.nodeType === 1 && depth < 6) {
      var part = el.tagName.toLowerCase();
      if (el.id) {
        parts.unshift(part + '#' + el.id);
        break;
      }
      var cls = classNames(el).slice(0, 2);
      if (cls.length) part += '.' + cls.join('.');
      var parent = el.parentElement;
      if (parent) {
        var same = 0;
        var index = 0;
        for (var i = 0; i < parent.children.length; i++) {
          var child = parent.children[i];
          if (child.tagName === el.tagName) {
            same++;
            if (child === el) index = same;
          }
        }
        if (same > 1) part += ':nth-of-type(' + index + ')';
      }
      parts.unshift(part);
      el = parent;
      depth++;
    }
    return parts.join('>').slice(0, 4096);
  }

  function absolute(url) {
    try {
      return new window.URL(url, location.href);
    } catch (e) {
      return null;
    }
  }

  var INTERACTIVE =
    'a,button,[role="button"],[role="link"],[role="menuitem"],[role="tab"],' +
    'input[type="submit"],input[type="button"],input[type="reset"],summary,[data-wa-track]';

  function interactiveAncestor(el) {
    var depth = 0;
    while (el && el.nodeType === 1 && depth < 12) {
      if (matches(el, INTERACTIVE)) return el;
      el = el.parentElement;
      depth++;
    }
    return null;
  }

  function ignored(el) {
    var depth = 0;
    while (el && el.nodeType === 1 && depth < 12) {
      if (el.hasAttribute && el.hasAttribute('data-wa-ignore')) return true;
      el = el.parentElement;
      depth++;
    }
    return false;
  }

  /*
   * Where would activating this element take the visitor?
   *
   * Anchors are the easy case. Buttons are not: their destination lives in a
   * formaction, the enclosing form's action, or a data attribute, and none of
   * that is visible from the click event itself.
   */
  function destination(el) {
    if (el.tagName === 'A' || el.tagName === 'AREA') {
      var raw = el.getAttribute('href');
      if (!raw) return null;
      if (raw.charAt(0) === '#') return null;
      if (/^javascript:/i.test(raw)) return null;
      return absolute(el.href || raw);
    }

    var data = el.getAttribute('data-href') || el.getAttribute('data-url');
    if (data) return absolute(data);

    var formAction = el.getAttribute('formaction');
    if (formAction) return absolute(formAction);

    var submits =
      el.tagName === 'BUTTON'
        ? (el.getAttribute('type') || 'submit').toLowerCase() === 'submit'
        : el.tagName === 'INPUT' && /^(submit|image)$/i.test(el.type || '');

    if (submits && el.form && el.form.getAttribute('action')) {
      return absolute(el.form.getAttribute('action'));
    }

    return null;
  }

  function classify(el) {
    var url = destination(el);
    if (!url) return { kind: 'click', outbound: false, url: null };

    if (url.protocol === 'mailto:') return { kind: 'mailto', outbound: true, url: url };
    if (url.protocol === 'tel:') return { kind: 'tel', outbound: true, url: url };

    var sameHost = url.host === location.host;

    if (el.hasAttribute && el.hasAttribute('download')) {
      return { kind: 'download', outbound: !sameHost, url: url };
    }

    if (!sameHost) return { kind: 'outbound', outbound: true, url: url };
    return { kind: 'click', outbound: false, url: url };
  }

  function opensNewTab(el, event) {
    var target = (el.getAttribute && el.getAttribute('target')) || '';
    if (target && target !== '_self') return true;
    if (!event) return false;
    return !!(event.metaKey || event.ctrlKey || event.shiftKey || event.button === 1);
  }

  function describe(el, event, verdict, trigger) {
    var url = verdict.url;
    var rect = null;
    try {
      rect = el.getBoundingClientRect();
    } catch (e) {
      /* detached node */
    }

    var x = event && typeof event.clientX === 'number' ? event.clientX : rect ? rect.left : null;
    var y = event && typeof event.clientY === 'number' ? event.clientY : rect ? rect.top : null;

    // Counted on the session so state() can report them without the page having
    // to watch for clicks a second time.
    session.clicks = (session.clicks || 0) + 1;
    if (verdict.outbound) session.outbound = (session.outbound || 0) + 1;

    return {
      n: 'click',
      pv: page ? page.seq : session.seq,
      k: verdict.kind,
      tag: el.tagName ? el.tagName.toLowerCase() : null,
      // id and classes are kept as first-class fields, not just inside the
      // selector, so the dashboard can group clicks by either one directly.
      id: el.id || null,
      cls: classNames(el),
      clsr: (el.getAttribute && el.getAttribute('class')) || null,
      ename: el.getAttribute ? el.getAttribute('name') : null,
      role: el.getAttribute ? el.getAttribute('role') : null,
      ety: el.getAttribute ? el.getAttribute('type') : null,
      nm: el.getAttribute ? el.getAttribute('data-wa-name') : null,
      txt: elementText(el),
      sel: cssPath(el),
      data: dataAttrs(el),
      href: url ? url.href.slice(0, 4096) : null,
      host: url ? url.host : null,
      hpath: url ? url.pathname : null,
      out: verdict.outbound ? 1 : 0,
      nt: opensNewTab(el, event) ? 1 : 0,
      trig: trigger,
      vx: x === null ? null : Math.round(x),
      vy: y === null ? null : Math.round(y),
      px: x === null ? null : Math.round(x + (window.pageXOffset || 0)),
      py: y === null ? null : Math.round(y + (window.pageYOffset || 0)),
      sp: scrollMax.pct,
      ms: page ? Date.now() - page.startedAt : null
    };
  }

  // ---------------------------------------------------------------- clicks

  // Outbound clicks are recorded on mousedown and sent straight away. Waiting
  // for the click event risks losing them: the browser may already be tearing
  // the document down, and a queued beacon dies with it. This is also why the
  // same element is then suppressed for a moment — the click that follows the
  // mousedown is the same interaction, not a second one.
  var lastOutbound = { el: null, at: 0 };

  function recordOutbound(el, event, trigger) {
    var verdict = classify(el);
    if (!verdict.outbound) return false;

    lastOutbound = { el: el, at: Date.now() };
    enqueue(describe(el, event, verdict, trigger));
    flushNow();
    log('outbound', verdict.kind, verdict.url && verdict.url.href);
    return true;
  }

  function onMouseDown(event) {
    interacted();
    if (!config.trackOutbound) return;
    if (event.button !== 0 && event.button !== 1) return;

    var el = interactiveAncestor(event.target);
    if (!el || ignored(el)) return;
    recordOutbound(el, event, event.button === 1 ? 'auxdown' : 'mousedown');
  }

  function onClick(event) {
    interacted();
    if (!config.trackClicks) return;

    var el = interactiveAncestor(event.target);
    if (!el || ignored(el)) return;

    // Already captured on mousedown.
    if (el === lastOutbound.el && Date.now() - lastOutbound.at < 2000) return;

    var verdict = classify(el);
    if (verdict.outbound && config.trackOutbound) {
      recordOutbound(el, event, 'click');
      return;
    }

    enqueue(describe(el, event, verdict, 'click'));
  }

  function onKeyDown(event) {
    interacted();
    if (!config.trackClicks) return;
    if (event.key !== 'Enter' && event.key !== ' ' && event.keyCode !== 13) return;

    var el = interactiveAncestor(event.target);
    if (!el || ignored(el)) return;

    var verdict = classify(el);
    if (verdict.outbound && config.trackOutbound) {
      recordOutbound(el, event, 'keydown');
    } else {
      enqueue(describe(el, event, verdict, 'keydown'));
    }
  }

  // Scripted navigation is invisible to click handlers, so window.open is
  // wrapped to catch off-site jumps that never touch an anchor.
  function wrapWindowOpen() {
    if (!config.trackOutbound || !window.open) return;
    var original = window.open;

    window.open = function (url) {
      try {
        var parsed = url ? absolute(String(url)) : null;
        if (parsed && parsed.host && parsed.host !== location.host) {
          enqueue({
            n: 'click',
            pv: page ? page.seq : session.seq,
            k: 'outbound',
            tag: 'window.open',
            cls: [],
            href: parsed.href.slice(0, 4096),
            host: parsed.host,
            hpath: parsed.pathname,
            out: 1,
            nt: 1,
            trig: 'window.open',
            sp: scrollMax.pct,
            ms: page ? Date.now() - page.startedAt : null
          });
          flushNow();
        }
      } catch (e) {
        /* never break the host page's navigation */
      }
      return original.apply(window, arguments);
    };
  }

  // ----------------------------------------------------------------- forms

  var SENSITIVE = /pass|pwd|secret|token|cvv|cvc|csc|card.?num|cc.?num|creditcard|ssn|social.?security|routing|iban|sort.?code|pin\b/i;
  var SKIP_TYPES = /^(submit|button|reset|image|hidden)$/i;

  var forms = [];

  function formState(form) {
    for (var i = 0; i < forms.length; i++) {
      if (forms[i].el === form) return forms[i];
    }
    var state = {
      el: form,
      firstInputAt: null,
      changes: {},
      focus: {},
      focusStart: {},
      submitted: false
    };
    forms.push(state);
    return state;
  }

  function fieldKey(el) {
    return el.getAttribute('name') || el.id || cssPath(el);
  }

  function fieldLabel(el) {
    if (el.id) {
      var byFor = document.querySelector('label[for="' + cssEscape(el.id) + '"]');
      if (byFor) return (byFor.innerText || byFor.textContent || '').trim().slice(0, 200);
    }
    var parent = el.parentElement;
    var depth = 0;
    while (parent && depth < 4) {
      if (parent.tagName === 'LABEL') {
        return (parent.innerText || parent.textContent || '').trim().slice(0, 200);
      }
      parent = parent.parentElement;
      depth++;
    }
    return (
      el.getAttribute('aria-label') ||
      el.getAttribute('placeholder') ||
      el.getAttribute('name') ||
      null
    );
  }

  function cssEscape(value) {
    if (window.CSS && window.CSS.escape) return window.CSS.escape(value);
    return String(value).replace(/["\\]/g, '\\$&');
  }

  function maskedField(el, type) {
    if (type === 'password' && !config.capturePasswords) return true;
    if (config.captureSensitive) return false;
    var hint =
      (el.getAttribute('name') || '') +
      ' ' +
      (el.id || '') +
      ' ' +
      (el.getAttribute('autocomplete') || '');
    return SENSITIVE.test(hint);
  }

  function fieldValue(el, type) {
    if (type === 'checkbox' || type === 'radio') return el.checked ? el.value || 'on' : null;
    if (el.tagName === 'SELECT' && el.multiple) {
      var picked = [];
      for (var i = 0; i < el.options.length; i++) {
        if (el.options[i].selected) picked.push(el.options[i].value);
      }
      return picked.length ? picked.join(', ') : null;
    }
    if (type === 'file') {
      if (!el.files || !el.files.length) return null;
      var names = [];
      for (var f = 0; f < el.files.length; f++) names.push(el.files[f].name);
      return names.join(', ');
    }
    return el.value === undefined || el.value === null || el.value === '' ? null : String(el.value);
  }

  function serializeForm(state) {
    var form = state.el;
    var fields = [];
    var elements = form.elements ? form.elements : form.querySelectorAll('input,select,textarea');

    for (var i = 0; i < elements.length && fields.length < 300; i++) {
      var el = elements[i];
      if (!el.tagName) continue;
      if (el.disabled) continue;
      if (ignored(el)) continue;

      var type = (el.getAttribute('type') || el.type || 'text').toLowerCase();
      if (SKIP_TYPES.test(type)) continue;
      if (el.tagName !== 'INPUT' && el.tagName !== 'SELECT' && el.tagName !== 'TEXTAREA') continue;

      var key = fieldKey(el);
      var masked = maskedField(el, type);
      var value = fieldValue(el, type);

      fields.push({
        name: el.getAttribute('name') || null,
        id: el.id || null,
        type: type,
        label: fieldLabel(el),
        value: masked ? null : value === null ? null : String(value).slice(0, 4096),
        filled: value !== null && value !== '',
        masked: masked,
        changes: state.changes[key] || 0,
        focus_ms: Math.round(state.focus[key] || 0)
      });
    }

    return fields;
  }

  function sendForm(state, status) {
    var form = state.el;
    if (ignored(form)) return;

    var fields = serializeForm(state);
    if (!fields.length) return;

    // Nothing was ever typed — not worth recording as an abandoned form.
    if (status === 'abandoned' && !state.firstInputAt) return;

    enqueue({
      n: 'form',
      pv: page ? page.seq : session.seq,
      st: status,
      fid: form.id || null,
      fnm: form.getAttribute('name') || null,
      act: form.getAttribute('action') || null,
      mth: (form.getAttribute('method') || 'get').toLowerCase(),
      sel: cssPath(form),
      cls: classNames(form),
      flds: fields,
      tfi: state.firstInputAt ? state.firstInputAt - page.startedAt : null,
      dur: state.firstInputAt ? Date.now() - state.firstInputAt : null
    });

    log('form', status, fields.length + ' fields');
  }

  function ownerForm(el) {
    if (!el || !el.tagName) return null;
    if (el.tagName !== 'INPUT' && el.tagName !== 'SELECT' && el.tagName !== 'TEXTAREA') return null;
    return el.form || null;
  }

  function onInput(event) {
    interacted();
    if (!config.trackForms) return;

    var form = ownerForm(event.target);
    if (!form) return;

    var state = formState(form);
    var key = fieldKey(event.target);
    state.changes[key] = (state.changes[key] || 0) + 1;
    if (!state.firstInputAt) state.firstInputAt = Date.now();
  }

  function onFocusIn(event) {
    interacted();
    if (!config.trackForms) return;
    var form = ownerForm(event.target);
    if (!form) return;
    formState(form).focusStart[fieldKey(event.target)] = Date.now();
  }

  function onFocusOut(event) {
    if (!config.trackForms) return;
    var form = ownerForm(event.target);
    if (!form) return;

    var state = formState(form);
    var key = fieldKey(event.target);
    var started = state.focusStart[key];
    if (started) {
      state.focus[key] = (state.focus[key] || 0) + (Date.now() - started);
      delete state.focusStart[key];
    }
  }

  // Submit races the navigation it triggers, so this flushes immediately.
  function onSubmit(event) {
    if (!config.trackForms) return;
    var form = event.target;
    if (!form || form.tagName !== 'FORM') return;

    var state = formState(form);
    state.submitted = true;
    sendForm(state, 'submitted');
    flushNow();
  }

  function reportAbandonedForms() {
    if (!config.trackForms) return;
    for (var i = 0; i < forms.length; i++) {
      if (!forms[i].submitted) sendForm(forms[i], 'abandoned');
    }
  }

  // ------------------------------------------------------ SPA route change

  function onRouteChange() {
    var key = pageKey();
    if (page && page.key === key) return;

    var previousTitle = page ? page.title : null;
    finishPage();
    endPageview();
    startPageview(previousTitle ? location.href : document.referrer);
    flush(false);
  }

  function wrapHistory() {
    ['pushState', 'replaceState'].forEach(function (method) {
      var original = window.history[method];
      if (typeof original !== 'function') return;
      window.history[method] = function () {
        var result = original.apply(window.history, arguments);
        // Let the framework finish rendering so document.title is current.
        window.setTimeout(onRouteChange, 0);
        return result;
      };
    });

    window.addEventListener('popstate', function () {
      window.setTimeout(onRouteChange, 0);
    });

    if (config.hashMode) {
      window.addEventListener('hashchange', function () {
        window.setTimeout(onRouteChange, 0);
      });
    }
  }

  // ----------------------------------------------------------- page finish

  function finishPage() {
    var at = Date.now();
    var elapsed = Math.max(0, at - lastTickAt);
    lastTickAt = at;

    var active = isActive();
    session.dwell += elapsed;
    if (active) session.active += elapsed;
    if (page) {
      page.dwell += elapsed;
      if (active) page.active += elapsed;
    }

    refreshScroll();

    enqueue({
      n: 'end',
      pv: page ? page.seq : session.seq,
      d: session.dwell,
      am: session.active,
      pd: page ? page.dwell : 0,
      pa: page ? page.active : 0,
      sp: scrollMax.pct,
      spx: scrollMax.px
    });

    persist();
  }

  var finished = false;

  function onPageHide() {
    if (finished) return;
    finished = true;
    reportAbandonedForms();
    finishPage();
    endPageview();
    flushNow();
  }

  // ------------------------------------------------------------------ boot

  function bindEvents() {
    var passive = { passive: true, capture: true };

    document.addEventListener('mousedown', onMouseDown, true);
    document.addEventListener('click', onClick, true);
    document.addEventListener('auxclick', onMouseDown, true);
    document.addEventListener('keydown', onKeyDown, true);

    document.addEventListener('input', onInput, true);
    document.addEventListener('change', onInput, true);
    document.addEventListener('focusin', onFocusIn, true);
    document.addEventListener('focusout', onFocusOut, true);
    document.addEventListener('submit', onSubmit, true);

    window.addEventListener('scroll', refreshScroll, passive);
    window.addEventListener('resize', refreshScroll, passive);
    document.addEventListener('touchstart', interacted, passive);
    document.addEventListener('touchmove', interacted, passive);
    document.addEventListener('wheel', interacted, passive);
    document.addEventListener('mousemove', interacted, passive);

    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') {
        flushNow();
      } else {
        // A restored tab was not accruing active time; resume from now so the
        // hidden stretch is not retroactively counted as engagement.
        interacted();
        lastTickAt = Date.now();
      }
    });

    window.addEventListener('pagehide', onPageHide);
    window.addEventListener('beforeunload', onPageHide);
  }

  // Everything the browser will tell us about itself. Each reader is guarded
  // separately: these APIs are uneven across browsers and a missing one must
  // cost a null, not the whole payload.
  function media(query) {
    try {
      return window.matchMedia ? window.matchMedia(query).matches : null;
    } catch (e) {
      return null;
    }
  }

  function connection() {
    try {
      var c = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
      if (!c) return {};
      return {
        ct: c.effectiveType || null,
        dl: typeof c.downlink === 'number' ? c.downlink : null,
        rtt: typeof c.rtt === 'number' ? c.rtt : null,
        sd: typeof c.saveData === 'boolean' ? c.saveData : null
      };
    } catch (e) {
      return {};
    }
  }

  // The user agent string is frozen and being stripped of detail, so take the
  // structured version where it exists.
  function clientHints() {
    try {
      var d = navigator.userAgentData;
      if (!d) return {};
      var brands = (d.brands || [])
        .map(function (b) { return b.brand + ' ' + b.version; })
        .join(', ');
      return {
        plat: d.platform || null,
        mob: typeof d.mobile === 'boolean' ? d.mobile : null,
        brands: brands ? brands.slice(0, 255) : null
      };
    } catch (e) {
      return {};
    }
  }

  function orientation() {
    try {
      if (window.screen && window.screen.orientation && window.screen.orientation.type) {
        return window.screen.orientation.type;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  function languages() {
    try {
      var list = navigator.languages;
      return list && list.length ? list.join(',').slice(0, 255) : null;
    } catch (e) {
      return null;
    }
  }

  // Navigation Timing. Rounded to whole milliseconds: sub-millisecond precision
  // here is noise, and the raw values are high-resolution timers that have been
  // used for fingerprinting.
  function timings() {
    try {
      var nav = performance.getEntriesByType && performance.getEntriesByType('navigation')[0];
      if (!nav) return {};

      var ms = function (value) {
        return typeof value === 'number' && value > 0 ? Math.round(value) : null;
      };

      return {
        nt: nav.type || null,
        ttfb: ms(nav.responseStart),
        dci: ms(nav.domInteractive),
        dcl: ms(nav.domContentLoadedEventEnd),
        load: ms(nav.loadEventEnd),
        tb: typeof nav.transferSize === 'number' ? nav.transferSize : null
      };
    } catch (e) {
      return {};
    }
  }

  function paintTiming() {
    try {
      var entries = performance.getEntriesByType && performance.getEntriesByType('paint');
      if (!entries) return null;
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].name === 'first-contentful-paint') {
          return Math.round(entries[i].startTime);
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // Largest Contentful Paint is only final once the user interacts or the page
  // is hidden, so it is observed in the background and read at send time rather
  // than measured once at load.
  var largestPaint = null;

  function observeLargestPaint() {
    try {
      if (!window.PerformanceObserver) return;
      var observer = new PerformanceObserver(function (list) {
        var entries = list.getEntries();
        if (entries.length) {
          largestPaint = Math.round(entries[entries.length - 1].startTime);
        }
      });
      observer.observe({ type: 'largest-contentful-paint', buffered: true });
    } catch (e) {
      /* Unsupported; the column stays null. */
    }
  }

  var reportedTimings = false;

  function performanceSnapshot() {
    if (reportedTimings) return null;
    reportedTimings = true;

    var snapshot = timings();
    var fcp = paintTiming();
    if (fcp !== null) snapshot.fcp = fcp;
    return snapshot;
  }

  function start() {
    if (!resumed) {
      enqueue({
        n: 'init',
        ref: document.referrer || null,
        ua: navigator.userAgent || null,
        sw: window.screen ? window.screen.width : null,
        sh: window.screen ? window.screen.height : null,
        vw: window.innerWidth || null,
        vh: window.innerHeight || null,
        dpr: window.devicePixelRatio || null,
        lang: navigator.language || null,
        tz: timezone(),
        utm: utmParams(),
        bot: automation,
        hb: heartbeatMs,
        langs: languages(),
        hc: typeof navigator.hardwareConcurrency === 'number' ? navigator.hardwareConcurrency : null,
        dm: typeof navigator.deviceMemory === 'number' ? navigator.deviceMemory : null,
        mtp: typeof navigator.maxTouchPoints === 'number' ? navigator.maxTouchPoints : null,
        cd: window.screen ? window.screen.colorDepth : null,
        so: orientation(),
        ck: typeof navigator.cookieEnabled === 'boolean' ? navigator.cookieEnabled : null,
        dark: media('(prefers-color-scheme: dark)'),
        rm: media('(prefers-reduced-motion: reduce)'),
        conn: connection(),
        ch: clientHints()
      });
    }

    observeLargestPaint();
    startPageview(document.referrer);
    bindEvents();
    wrapHistory();
    wrapWindowOpen();
    schedule();
    flush(false);

    log('started', {
      site: config.site,
      session: session.token,
      resumed: !!resumed,
      automation: automation || 'none',
      heartbeatMs: heartbeatMs
    });
  }

  function timezone() {
    try {
      return window.Intl.DateTimeFormat().resolvedOptions().timeZone || null;
    } catch (e) {
      return null;
    }
  }

  function utmParams() {
    var out = {};
    var search = location.search || '';
    var names = ['source', 'medium', 'campaign', 'term', 'content'];
    for (var i = 0; i < names.length; i++) {
      var match = search.match(new RegExp('[?&]utm_' + names[i] + '=([^&]*)'));
      if (match) {
        try {
          out[names[i]] = decodeURIComponent(match[1].replace(/\+/g, ' ')).slice(0, 255);
        } catch (e) {
          out[names[i]] = match[1].slice(0, 255);
        }
      }
    }
    return out;
  }

  // Public surface for custom events, kept intentionally small.
  window.__webAnalytics = {
    version: '1.0.0',
    session: function () {
      return {
        token: session.token,
        visitor: visitorToken,
        seq: session.seq,
        automation: automation,
        heartbeatMs: heartbeatMs
      };
    },
    // What the tag has recorded about this visit so far. Read-only, and read by
    // the landing page to show a visitor their own data rather than describing
    // it — the shortest route to believing an analytics tool is watching it
    // watch you.
    state: function () {
      // Dwell is banked on the heartbeat, which backs off to fifteen seconds
      // once a visit runs long. Anything reading this wants the number now, so
      // the time since the last tick is added rather than waited for.
      var sinceTick = Math.max(0, Date.now() - lastTickAt);
      var activeNow = isActive();

      return {
        path: page ? page.path : location.pathname,
        title: page ? page.title : document.title,
        pageviews: session.seq,
        dwellMs: session.dwell + sinceTick,
        activeMs: session.active + (activeNow ? sinceTick : 0),
        pageDwellMs: page ? page.dwell + sinceTick : 0,
        scrollPct: scrollMax.pct,
        scrollPx: scrollMax.px,
        docHeight: scrollMax.docHeight,
        clicks: session.clicks || 0,
        outbound: session.outbound || 0,
        referrer: document.referrer || null,
        viewport: { w: window.innerWidth, h: window.innerHeight },
        screen: window.screen ? { w: window.screen.width, h: window.screen.height } : null,
        timezone: timezone(),
        language: navigator.language || null,
        connection: connection(),
        hints: clientHints(),
        automation: automation,
        ticks: session.ticks
      };
    },
    track: function (name, meta) {
      enqueue({
        n: 'click',
        pv: page ? page.seq : session.seq,
        k: 'custom',
        nm: String(name).slice(0, 255),
        tag: 'custom',
        cls: [],
        data: meta || {},
        sp: scrollMax.pct,
        ms: page ? Date.now() - page.startedAt : null
      });
      flush(false);
    },
    flush: flushNow
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})(window, document);
