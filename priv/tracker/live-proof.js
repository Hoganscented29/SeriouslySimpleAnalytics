// The landing pages' small behaviours: the "your visit, as recorded" panel, and
// the copy buttons on the prompts.
//
// Prefers the tag's own state, because the claim on the page is that the tag
// records this and the honest way to show that is to show what the tag holds.
// Falls back to measuring the same things here when the tag is not running —
// blocked by an extension, or an old copy cached from before it published a
// state() — so the panel is never a row of dashes. Everything it shows is a
// real property of this visit either way; nothing here is invented.
(function () {
  'use strict';

  var FIELDS = [
    'wa-dwell', 'wa-pageviews', 'wa-scroll', 'wa-clicks',
    'wa-path', 'wa-viewport', 'wa-tz', 'wa-conn', 'wa-plat'
  ];

  function el(id) {
    return document.getElementById(id);
  }

  function set(id, value) {
    var node = el(id);
    if (node && value != null && value !== '') node.textContent = value;
  }

  function duration(ms) {
    if (typeof ms !== 'number' || ms < 0) return null;
    var seconds = Math.floor(ms / 1000);
    if (seconds < 60) return seconds + 's';
    var minutes = Math.floor(seconds / 60);
    return minutes + 'm ' + (seconds % 60) + 's';
  }

  // ------------------------------------------------------------ measurement

  // Mirrors what the tag counts, deliberately: the tag records a click on
  // something a person can act on, not on any pixel of the page, and a panel
  // that disagreed with it would be showing a different number under the same
  // label.
  var INTERACTIVE = 'a, button, input, select, textarea, summary, label, [role="button"], [role="link"], [onclick]';

  var IDLE_MS = 30000;

  var local = {
    startedAt: Date.now(),
    activeMs: 0,
    lastSampleAt: Date.now(),
    lastInteractionAt: Date.now(),
    scrollPct: 0,
    clicks: 0,
    pageviews: countPageview()
  };

  // A session spans page loads, so the count has to outlive this one. Stored
  // rather than derived because there is nothing on a fresh document to derive
  // it from, and wrapped because a browser set to refuse storage throws on the
  // read rather than returning nothing.
  function countPageview() {
    try {
      var seen = parseInt(window.sessionStorage.getItem('wa-live-pv'), 10) || 0;
      var next = seen + 1;
      window.sessionStorage.setItem('wa-live-pv', String(next));
      return next;
    } catch (e) {
      return 1;
    }
  }

  function noteInteraction() {
    local.lastInteractionAt = Date.now();
  }

  function sampleActive() {
    var at = Date.now();
    // Measured rather than assumed, for the same reason the tag measures it:
    // a background tab's timers are throttled, so a "250ms" sample can arrive
    // much later and that time is real dwell even though none of it was active.
    var elapsed = Math.max(0, at - local.lastSampleAt);
    local.lastSampleAt = at;

    if (document.visibilityState !== 'hidden' && at - local.lastInteractionAt < IDLE_MS) {
      local.activeMs += elapsed;
    }
  }

  function sampleScroll() {
    var doc = document.documentElement;
    var body = document.body || {};
    var height = Math.max(
      doc.scrollHeight || 0, body.scrollHeight || 0,
      doc.offsetHeight || 0, body.offsetHeight || 0
    );
    var seen = (window.pageYOffset || doc.scrollTop || 0) + window.innerHeight;
    var pct = height > 0 ? Math.round(Math.min(100, (seen / height) * 100)) : 0;
    if (pct > local.scrollPct) local.scrollPct = pct;
  }

  function connection() {
    var c = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    if (!c) return {};
    return { ct: c.effectiveType || null, rtt: typeof c.rtt === 'number' ? c.rtt : null };
  }

  function platform() {
    var data = navigator.userAgentData;
    if (data && data.platform) return data.platform;
    return navigator.platform || navigator.language || null;
  }

  function timezone() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone;
    } catch (e) {
      return null;
    }
  }

  // The same shape the tag's state() returns, so render() does not care which
  // of the two it is looking at.
  function localState() {
    sampleActive();
    sampleScroll();

    return {
      path: location.pathname,
      pageviews: local.pageviews,
      dwellMs: Date.now() - local.startedAt,
      activeMs: local.activeMs,
      scrollPct: local.scrollPct,
      clicks: local.clicks,
      viewport: { w: window.innerWidth, h: window.innerHeight },
      timezone: timezone(),
      connection: connection(),
      hints: { plat: platform() },
      language: navigator.language || null
    };
  }

  var fallbackAnnounced = false;

  function readState() {
    var api = window.__webAnalytics;

    if (api && typeof api.state === 'function') {
      try {
        return api.state();
      } catch (e) {
        /* fall through and measure it here */
      }
    }

    // Say so once. A panel headed "this page is running the tag on you" that is
    // quietly measuring its own numbers instead would be making a claim it is
    // not keeping.
    if (!fallbackAnnounced) {
      fallbackAnnounced = true;
      var note = el('wa-fallback');
      if (note) note.hidden = false;
    }

    return localState();
  }

  // ---------------------------------------------------------------- render

  function render() {
    var s = readState();

    set('wa-dwell', duration(s.dwellMs));
    set('wa-pageviews', String(s.pageviews || 1));
    set('wa-scroll', (s.scrollPct || 0) + '%');
    set('wa-clicks', String(s.clicks || 0));
    set('wa-path', s.path);
    set('wa-viewport', s.viewport ? s.viewport.w + '\u00d7' + s.viewport.h : null);
    set('wa-tz', s.timezone);

    var conn = s.connection || {};
    set('wa-conn', conn.ct ? conn.ct + (conn.rtt ? ' \u00b7 ' + conn.rtt + 'ms' : '') : 'unknown');

    var hints = s.hints || {};
    set('wa-plat', hints.plat || s.language || 'unknown');
  }

  // Coalesced to one render per frame: scroll and pointer events fire far faster
  // than anything here changes, and re-reading on each of them would spend the
  // frame budget to draw the same numbers.
  var queued = false;

  function scheduleRender() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      render();
    });
  }

  function watchInteraction() {
    // Scroll depth and the click count change the moment the reader does
    // something, and waiting up to a second to show it makes a live panel look
    // like a static one.
    var events = ['scroll', 'click', 'keydown', 'pointerdown', 'pointermove', 'wheel', 'touchmove'];

    for (var i = 0; i < events.length; i++) {
      window.addEventListener(events[i], function (event) {
        noteInteraction();
        if (event.type === 'click') countClick(event);
        scheduleRender();
      }, { passive: true, capture: true });
    }

    document.addEventListener('visibilitychange', scheduleRender);
  }

  function countClick(event) {
    var target = event.target;
    if (!target || !target.closest) return;
    if (target.closest(INTERACTIVE)) local.clicks += 1;
  }

  // No waiting on the tag: both scripts are deferred and the tag comes first in
  // the document, so it is normally already here — and when it is not, the
  // panel has its own measurements and starts on the same frame regardless.
  if (FIELDS.some(el)) {
    render();
    watchInteraction();
    // Dwell and engaged time advance on their own, so they still need a clock.
    setInterval(render, 250);
  }
})();


// Copy buttons. Delegated from the document so a page can have several and the
// markup stays a button next to a <pre> rather than a component with a hook.
(function () {
  'use strict';

  document.addEventListener('click', function (event) {
    var button = event.target.closest && event.target.closest('[data-copy]');
    if (!button) return;

    var source = document.getElementById(button.getAttribute('data-copy'));
    if (!source) return;

    var text = source.innerText.trim();
    // Never leave the button unchanged: a press that does nothing visible reads
    // as a broken button, and the reader has no other way to tell.
    var flash = function (message) {
      var original = button.getAttribute('data-copy-label') || button.textContent;
      button.setAttribute('data-copy-label', original);
      button.textContent = message;
      setTimeout(function () { button.textContent = original; }, 2000);
    };

    var failed = function () {
      flash('Press ⌘C');
      var range = document.createRange();
      range.selectNodeContents(source);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    };

    var done = function () {
      flash('Copied');
    };

    // The older selection trick, used when the clipboard API is missing and
    // again when it refuses — it rejects on an unfocused document, which is not
    // a reason to leave the button silent.
    var fallback = function () {
      var area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();

      var copied = false;
      try { copied = document.execCommand('copy'); } catch (e) { copied = false; }
      document.body.removeChild(area);

      if (copied) done(); else failed();
    };

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fallback);
      return;
    }

    fallback();
  });
})();
