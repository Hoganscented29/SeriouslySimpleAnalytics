# SeriouslySimpleAnalytics

Analytics for AI tools and websites. An AI tool reports usage by fetching one
URL; a website drops in one script tag. Self-hosted, no cookies, no raw IP
addresses stored, no dependency to add on the client side.

```bash
mix setup
mix geoip.download            # optional: city-level location data
mix run priv/repo/seeds.exs   # optional: demo traffic
mix phx.server
```

Landing page at <http://localhost:4001>, dashboard at `/dashboard`, a tracked
demo site at `/demo`, and the machine-readable integration guide at `/llms.txt`.

## Two ways in

**An AI tool, agent, CLI or job** reports by fetching one URL:

```
GET /api/ping?uid=ACCOUNT_ID&type=ai&project=my-agent&event=run_completed
```

No SDK, no API key exchange, no JSON body. Returns `204` — fire and forget.
Undocumented query parameters are kept as event attributes, so
`&tool=search&latency_ms=420&outcome=success` needs no schema change. Pass
`sid=` to group pings into one run or conversation; `event=page_view` with a
`path` is recorded as a real pageview so it lands in the pages and flow reports.

The complete contract lives at `/llms.txt`, written for an AI to read and
integrate from unattended — including the rules about what must never be sent
(no prompts, no completions, no credentials, no personal data). Parameters go in
a URL, and URLs end up in proxy logs.

**A website** drops in one tag:

```html
<script src="https://analytics.example.com/wa.js" data-site="ACCOUNT_ID" defer></script>
```

That is the whole integration. Nothing else needs tagging.

## What it captures

**Pageviews and flow.** Every pageview records its path *and* its title, plus the
hop that produced it. The dashboard groups flow by either — path answers "which
URL", title answers "which content" — and the two diverge as soon as one template
serves many URLs. Hops are denormalised onto each pageview row, so the whole
transition graph is one grouped scan rather than a self-join over ordered
sessions. Works on plain multi-page sites and on SPAs (`pushState`, `popstate`,
and optionally `hashchange`).

**Engagement heartbeats.** A beacon every second for the first 400 seconds of a
visit, then every 15. Elapsed time is measured rather than assumed, because
browsers throttle timers in background tabs — a "1 second" tick can arrive a
minute late, and that minute is real dwell even though none of it was active.
Dwell and active time are tracked separately: active seconds require the tab to
be visible *and* the visitor to have interacted recently.

**Max scroll depth.** Per pageview, as a percentage and in pixels. The furthest
point reached, not the current position, and it never decreases.

**Clicks on links and buttons.** Auto-detected by walking up from the event
target to the nearest interactive ancestor. Element id and classes are stored as
first-class fields — classes as a Postgres array with a GIN index — so clicks can
be segregated by id, by any single class, by text, by selector or by tag without
any tagging work on your side.

**Off-site clicks, on `mousedown`.** Registered and sent immediately, before the
browser starts tearing the page down — waiting for the `click` event loses them.
Covers anchors, buttons whose `formaction` or enclosing form points off-site,
`data-href`, `mailto:`, `tel:`, downloads, middle-clicks, keyboard activation,
and scripted `window.open`. The subsequent `click` on the same element is
suppressed so one interaction is not counted twice.

**Forms.** Every field, on submit *and* on abandonment, with per-field label,
type, value, edit count and focus time. Submissions race the navigation they
trigger, so they are flushed immediately.

**Location** — city, state/province and country. See below.

**Custom events** from anywhere — the ping endpoint above, or
`window.__webAnalytics.track('signed_up', {plan: 'pro'})` in a browser. Grouped
by name in the dashboard, and separable by project.

## Where visitors are

Every session is resolved to a city, a state or province, and a country. Three
sources are tried, in descending order of precision:

1. **CDN headers.** If the request came through Cloudflare, Vercel, CloudFront
   or Netlify, the edge already resolved the location closer to the visitor and
   with better data than this server has. Reading it costs nothing.
2. **A local GeoIP database.** City-level, offline, no rate limit, and no third
   party ever sees your visitors' addresses. `mix geoip.download` fetches
   DB-IP's IP-to-City Lite — free, monthly, CC BY 4.0, no account needed. Any
   MaxMind-format `.mmdb` works, including GeoLite2.
3. **The browser's time zone.** Country only, *never* a city: a zone named
   `America/Los_Angeles` names the zone's reference city, not the visitor's.
   This is what makes a deployment with no database and no CDN still useful.

The `Locations` tab groups by country, state/province or city, and says plainly
how much traffic could be placed and by which resolver — a country-level guess
from a time zone is a different thing from a city-level fix, and a dashboard
that presented them identically would be overstating what it knows.

The reader for the `.mmdb` format is written from scratch in
`lib/web_analytics/geo/mmdb.ex` rather than pulled in as a dependency, since the
project rule is not to add any. The whole file is held as one binary and read
with `binary_part/3`, which returns sub-binaries sharing the original's memory;
a lookup is arithmetic over shared memory, around 20µs, with no file I/O and no
process to serialise through.

The database file is ~120MB and reissued monthly, so it is gitignored rather
than committed. Without it the app runs exactly as before.

**Resolution happens at ingest, in the request that carries the address, and the
address is never stored** — only the city, region and country it resolved to.
That ordering is the point: the raw IP exists in memory for the length of one
lookup and is then gone.

A session's location is fixed by its first beacon. A visitor moving between
networks mid-visit does not relocate the whole session.

## Following a path

Anywhere a page appears in the `Flow` tab it can be clicked to drill into it:
both ends of every transition, the nodes of the flow diagram, the entry and exit
lists, and the neighbours inside a navigation summary. Clicking a neighbour
re-centres the summary on it, so you can walk a route hop by hop rather than
reading the whole graph at once. The selection lives in the URL, so a particular
path through the site is a link you can send someone.

## The two filters

Reports are clean by default, and each filter has its own toggle and its own
report. Neither ever deletes anything — sessions are labelled, and the dashboard
decides what to show.

**Crawlers** are filtered out and reported separately. They are not malformed
data — a visit from an AI crawler is a real, interesting event — they are just a
different kind of visitor. The `Crawlers` tab breaks them down by bot and by kind
(AI, search, link preview, SEO, headless, automation, monitor, HTTP client).
Detection is server-side from the user agent, plus what the tracker can see that
a user agent cannot: `navigator.webdriver`, PhantomJS globals, and a missing
plugin *and* language list. Both halves of that last check are required — plenty
of real mobile browsers report no plugins, but every real browser reports a
language.

**Dwell-time anomalies** are filtered out and explained in the `Sessions` tab.
Rule checks catch shapes that are impossible for a human: a dozen pages in two
seconds, twelve hours parked on one tab, a hundred heartbeats with no scroll,
click or focus. On top sits a distribution check — dwell is log-normal in
practice, so the baseline uses the median and *median absolute deviation* of
`ln(dwell)` rather than mean and standard deviation, because those two statistics
are themselves wrecked by the outliers being looked for.

The axes are independent: crawlers are never also classified as anomalies.
Otherwise every bot would be counted twice, and un-hiding crawler traffic would
leave it hidden behind the other filter.

## Crawlers are sampled at 10 seconds

A crawler sweeping a thousand pages would otherwise generate a thousand beacons a
second between them — a self-inflicted denial of service on your own collector —
and nobody needs per-second engagement data for a bot. So when the tracker
detects an automated client it drops its own heartbeat from 1s to 10s. The
detailed window stays the same 400 seconds of wall-clock time; a human is sampled
across it every second and a crawler every ten. The resolution each session was
tracked at is stored on the session and shown in the crawler report.

A false positive costs a coarser heartbeat and a row in the crawler report —
never a dropped visit.

## Privacy

- **No cookies.** Tokens live in `localStorage` and `sessionStorage`.
- **No raw IPs.** Addresses are salted and hashed with a per-day, per-site key,
  truncated to 32 hex characters, and used only to group obvious duplicates
  during anomaly scoring. They stop being linkable after a day. Geolocation
  resolves from the address in-request and keeps only the resulting place name;
  the session schema has nowhere to put an address.
- **No location permission prompt.** Nothing uses the browser Geolocation API,
  so visitors are never asked, and nothing finer than a city is ever recorded.
- **Passwords are never stored.** The tracker masks `type="password"` in the
  browser, so values never leave the page. Fields whose name, id or autocomplete
  hint looks like a card number, CVV, SSN, IBAN or PIN are masked the same way.
  The server drops password values again on arrival, so stale or tampered-with
  snippets cannot get around it.
- `data-wa-ignore` on any element, form or field excludes it entirely.

Both masks are opt-out — `data-capture-passwords="true"` and
`data-capture-sensitive="true"` — because "save all form data" sometimes means
all of it. Turning either on writes plaintext credentials or card numbers into
your database. Think about it first.

## Snippet options

| Attribute | Default | Meaning |
| --- | --- | --- |
| `data-site` | *required* | Site key |
| `data-api` | script origin + `/api/v1/collect` | Collector endpoint |
| `data-heartbeat-ms` | `1000` | Heartbeat for human visitors |
| `data-crawler-heartbeat-ms` | `10000` | Heartbeat once automation is detected |
| `data-fast-ticks` | `400` | Detailed window, in heartbeats (400 × 1s = 400s) |
| `data-slow-ms` | `15000` | Heartbeat after the detailed window |
| `data-idle-ms` | `30000` | Silence before a visitor counts as idle |
| `data-session-timeout-min` | `30` | Inactivity before a new session starts |
| `data-clicks` / `data-forms` / `data-scroll` / `data-outbound` | `true` | Feature switches |
| `data-capture-passwords` | `false` | Store password values |
| `data-capture-sensitive` | `false` | Store card/SSN-shaped values |
| `data-hash-mode` | `false` | Treat `#fragment` as the route |
| `data-debug` | `false` | Log every beacon to the console |

Custom events: `window.__webAnalytics.track('signed_up', { plan: 'pro' })`.

## How it holds up

The tracker beacons once a second per visitor, so writing straight through would
put one transaction per visitor per second on Postgres. Beacons are buffered and
consecutive ones from the same session are merged, so a flush does one
transaction per session rather than one per beacon — sixty heartbeats collapse
into a single pageview update and a single session update. Flushes are serial and
the next is only scheduled once the previous finishes, so a slow database
throttles the loop instead of stacking timers.

Everything arriving at `/api/v1/collect` is attacker-controlled: the endpoint is
unauthenticated by design and the tracker runs in the visitor's browser. Every
type is coerced, every string truncated to its column width, every collection
size capped, and malformed events are dropped individually rather than failing
the batch. Client clocks are not trusted — event times are anchored to server
receive time and offset by the client-reported delta, clamped to a sane window.
Unknown site keys get exactly the same empty 204 as real ones, so the endpoint
cannot be used to enumerate them.

Beacons are posted as `text/plain`, which keeps them CORS *simple requests* — no
preflight round trip when one is racing a page teardown.

## Layout

```
lib/web_analytics/
  ingest/            normalizer (validation boundary), collector (buffer),
                     processor (writes), crawler + user_agent (classification)
  geo/               mmdb reader, CDN headers, country + time-zone tables
  geo.ex             the resolver that picks between them
  analytics/         anomaly rules and the background classifier
  analytics.ex       every dashboard query
lib/web_analytics_web/
  controllers/       ping endpoint, collect endpoint, tracker delivery,
                     landing page + llms.txt, demo site
  live/              dashboard
priv/tracker/wa.js   the tracker (compiled into TrackerController)
priv/geoip/          GeoIP database (gitignored; mix geoip.download)
priv/docs/llms.txt   the integration guide, rendered with real URLs at /llms.txt
```

`priv/tracker/wa.js` is deliberately outside `priv/static`: it is a source file
embedded at compile time, not an asset, which keeps its URL stable and free of a
digest hash — it gets pasted into other people's HTML.

Run `mix precommit` before committing.
