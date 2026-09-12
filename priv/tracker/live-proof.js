// The landing pages' small behaviours: the "your visit, as recorded" panel, and
// the copy buttons on the prompts.
//
// Reads the tag's own state rather than measuring anything itself: the claim is
// that the tag records this, so the panel has to show what the tag holds, not a
// second implementation that happens to agree with it.
(function () {
  'use strict';

  var FIELDS = [
    'wa-dwell', 'wa-active', 'wa-scroll', 'wa-clicks',
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

  function render() {
    var api = window.__webAnalytics;
    if (!api || typeof api.state !== 'function') return;

    var s;
    try {
      s = api.state();
    } catch (e) {
      return;
    }

    set('wa-dwell', duration(s.dwellMs));
    set('wa-active', duration(s.activeMs));
    set('wa-scroll', (s.scrollPct || 0) + '%');
    set('wa-clicks', String(s.clicks || 0));
    set('wa-path', s.path);
    set('wa-viewport', s.viewport ? s.viewport.w + '×' + s.viewport.h : null);
    set('wa-tz', s.timezone);

    var conn = s.connection || {};
    set('wa-conn', conn.ct ? conn.ct + (conn.rtt ? ' · ' + conn.rtt + 'ms' : '') : 'unknown');

    var hints = s.hints || {};
    set('wa-plat', hints.plat || s.language || 'unknown');
  }

  // Coalesced to one render per frame: scroll and pointer events fire far faster
  // than anything here changes, and re-reading the tag on each of them would
  // spend the frame budget to draw the same numbers.
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
      window.addEventListener(events[i], scheduleRender, { passive: true, capture: true });
    }

    document.addEventListener('visibilitychange', scheduleRender);
  }

  function startWhenReady(attempt) {
    // The tag is deferred, so the panel may run first. Retry briefly rather
    // than binding to a load event the tag does not publish.
    if (window.__webAnalytics && window.__webAnalytics.state) {
      render();
      watchInteraction();
      // Dwell and engaged time advance on their own, so they still need a
      // clock — just a faster one than the second they used to wait for.
      setInterval(render, 250);
      return;
    }

    if (attempt < 40) {
      setTimeout(function () { startWhenReady(attempt + 1); }, 250);
      return;
    }

    // The tag is cached for an hour, so a visitor who was here before it last
    // changed can be running a copy with no state() on it. Say that, rather
    // than leaving a row of dashes that reads as a broken page.
    var note = el('wa-stale');
    if (note) note.hidden = false;
  }

  if (FIELDS.some(el)) startWhenReady(0);
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
