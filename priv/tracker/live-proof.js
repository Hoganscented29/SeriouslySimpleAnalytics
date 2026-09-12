// Drives the "your visit, as recorded" panel on the landing page.
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

  function startWhenReady(attempt) {
    // The tag is deferred, so the panel may run first. Retry briefly rather
    // than binding to a load event the tag does not publish.
    if (window.__webAnalytics && window.__webAnalytics.state) {
      render();
      setInterval(render, 1000);
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
