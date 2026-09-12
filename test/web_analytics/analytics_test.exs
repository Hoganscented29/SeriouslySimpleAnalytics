defmodule WebAnalytics.AnalyticsTest do
  use WebAnalytics.DataCase, async: true

  import WebAnalytics.Fixtures

  alias WebAnalytics.Analytics
  alias WebAnalytics.Analytics.AnomalyWorker
  alias WebAnalytics.Ingest
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Session

  setup do
    site = site_fixture()

    # A clean human visit across three pages.
    submit(site, [
      init_event(),
      pageview_event(1, "/", %{"title" => "Home"}),
      tick_event(1, %{"d" => 20_000, "am" => 18_000, "sp" => 80}),
      click_event(%{"id" => "cta", "cls" => ["btn", "primary"]}),
      pageview_event(2, "/pricing", %{"title" => "Pricing", "fp" => "/", "ft" => "Home"}),
      tick_event(2, %{"d" => 40_000, "am" => 35_000, "sp" => 60}),
      click_event(%{
        "pv" => 2,
        "k" => "outbound",
        "out" => 1,
        "id" => "gh",
        "cls" => ["btn"],
        "href" => "https://github.com/x",
        "trig" => "mousedown"
      })
    ])

    # A crawler.
    submit(site, [
      init_event(%{"ua" => "Mozilla/5.0 (compatible; GPTBot/1.1; +https://openai.com/gptbot)"}),
      pageview_event(1, "/", %{"title" => "Home"}),
      tick_event(1, %{"d" => 3_000, "am" => 0, "a" => 0})
    ])

    # A dwell anomaly: a tab left open all day with no attention.
    submit(site, [
      init_event(),
      pageview_event(1, "/docs", %{"title" => "Docs"}),
      %{"n" => "end", "t" => 1_000_000, "pv" => 1, "d" => 20 * 3_600_000, "am" => 0, "sp" => 0}
    ])

    AnomalyWorker.classify_all()

    %{site: site}
  end

  defp submit(site, events) do
    {:ok, _} = Ingest.submit_sync(site, payload(site, events), received_at: DateTime.utc_now())
  end

  defp filters(site, opts \\ %{}) do
    Analytics.filters(site.id, Map.merge(%{range: "30d"}, opts))
  end

  describe "active_now/3" do
    test "counts off the clock, not off the selected range", %{site: site} do
      # The setup's visits are all just-now. Reading a window that ended years
      # ago must not empty the live panel: "active" is a fact about the clock,
      # and a panel that went blank because someone changed the range above it
      # would be reporting on the filter rather than on the traffic.
      last_year = %{
        filters(site)
        | from: ~U[2020-01-01 00:00:00.000000Z],
          to: ~U[2020-01-02 00:00:00.000000Z]
      }

      # The range genuinely excludes everything, or this proves nothing.
      assert Analytics.overview(last_year).sessions == 0

      live = Analytics.active_now(last_year)

      assert live.sessions > 0
      assert live.live_sessions > 0
    end

    test "separates the last thirty seconds from the last thirty minutes", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/older"),
        tick_event(1, %{"d" => 5_000})
      ])

      [older | _] =
        Repo.all(from s in Session, where: s.site_id == ^site.id, order_by: [desc: s.id])

      at = DateTime.add(DateTime.utc_now(), -10, :minute)

      Repo.update_all(from(s in Session, where: s.id == ^older.id),
        set: [last_seen_at: at, started_at: at]
      )

      live = Analytics.active_now(filters(site))

      # Still active, not still live: ten minutes is inside the half hour and
      # well outside the thirty seconds.
      assert live.sessions > live.live_sessions
      assert Enum.any?(live.sessions_list, &(&1.id == older.id))
    end
  end

  describe "the clicks report" do
    test "the default grouping shows a click nobody named", %{site: site} do
      # `name` comes from an opt-in data-wa-name attribute that real pages do
      # not carry, and this grouping filtered on it being present — so the
      # default view of the Clicks tab was empty on sites where every click had
      # been recorded, tag, text, href and all.
      rows = Analytics.clicks(filters(site), :name, 20)

      assert rows != []
      assert Enum.all?(rows, &is_binary(&1.name))
      refute Enum.any?(rows, &(&1.name == ""))
    end

    test "an explicit name still wins over the fallbacks", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/named"),
        click_event(%{"id" => "ignored-id", "nm" => "Checkout button", "txt" => "Buy"}),
        tick_event(1, %{"d" => 20_000})
      ])

      names = Analytics.clicks(filters(site), :name, 20) |> Enum.map(& &1.name)

      assert "Checkout button" in names
      refute "ignored-id" in names
    end

    test "every labelling is available, and each says what it groups on", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/labels"),
        click_event(%{
          "id" => "buy",
          "cls" => ["btn", "btn-lg"],
          "sel" => "main>button#buy",
          "txt" => "Buy now"
        }),
        tick_event(1, %{"d" => 20_000})
      ])

      f = filters(site)
      by = fn group -> f |> Analytics.clicks(group, 20) |> Enum.map(& &1.name) end

      # Which one is useful depends on the markup, so all four have to work
      # rather than the reader discovering three empty lists one at a time.
      assert "buy" in by.(:id)
      assert "btn-lg" in by.(:class)
      assert "main>button#buy" in by.(:selector)
      assert "Buy now" in by.(:text)
    end

    test "a custom event is not a click and stays out of the report", %{site: site} do
      rows = Analytics.clicks(filters(site), :tag, 20)

      # The :class grouping always excluded them; the others did not, so the
      # same tab disagreed with itself depending on how it was grouped.
      refute Enum.any?(rows, &(&1.name == "custom"))
    end
  end

  describe "page flow" do
    test "derives the previous page when the client never sent one", %{site: site} do
      # Three pages, no `fp` on any of them: a restored tab, a browser refusing
      # storage, a first load after the tag was added, or anything reported
      # through the ping API. This was most of the traffic, and the diagram was
      # built only from the pageviews that happened to arrive with one.
      submit(site, [
        init_event(),
        pageview_event(1, "/a"),
        pageview_event(2, "/b"),
        pageview_event(3, "/c"),
        tick_event(3, %{"d" => 30_000})
      ])

      routes = filters(site) |> Analytics.flow(50) |> Enum.map(&{&1.from, &1.to})

      assert {"/a", "/b"} in routes
      assert {"/b", "/c"} in routes
    end

    test "says how much of the graph it is showing", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/a"),
        pageview_event(2, "/b"),
        pageview_event(3, "/c"),
        tick_event(3, %{"d" => 30_000})
      ])

      wide = Analytics.flow_coverage(filters(site), 50)
      narrow = Analytics.flow_coverage(filters(site), 1)

      # The totals do not move with the limit; only what is shown does.
      assert wide.routes == narrow.routes
      assert wide.hops == narrow.hops
      assert narrow.routes_shown == 1
      assert narrow.hops_shown < wide.hops_shown
      assert wide.routes_shown == wide.routes
      assert wide.hops_shown == wide.hops
    end

    test "counts the single-page visits that explain a thin diagram" do
      site = site_fixture(%{key: "coverage"})
      f = Analytics.filters(site.id, %{range: "30d"})

      for path <- ["/one", "/two", "/three"] do
        {:ok, _} =
          Ingest.submit_sync(
            site,
            payload(
              site,
              [init_event(), pageview_event(1, path), tick_event(1, %{"d" => 20_000})],
              token: "single#{path}"
            ),
            received_at: DateTime.utc_now()
          )
      end

      coverage = Analytics.flow_coverage(f, 18)

      # Three visits, no routes: a single-page visit has no transition in it,
      # whatever the tag does. This is the number that explains almost every
      # thin flow diagram, and the one nobody thinks to look up.
      assert coverage.sessions == 3
      assert coverage.single_page_sessions == 3
      assert coverage.routes == 0
      assert coverage.hops == 0
    end

    test "reports three-step journeys, not just pairs", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/teams"),
        pageview_event(2, "/pricing"),
        pageview_event(3, "/checkout"),
        tick_event(3, %{"d" => 40_000})
      ])

      journeys =
        filters(site) |> Analytics.journeys(20) |> Enum.map(&{&1.first, &1.second, &1.third})

      # A pair says which page follows which. Three says the route.
      assert {"/teams", "/pricing", "/checkout"} in journeys
    end

    test "a two-page visit produces no three-step journey", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/one"),
        pageview_event(2, "/two"),
        tick_event(2, %{"d" => 20_000})
      ])

      refute filters(site)
             |> Analytics.journeys(20)
             |> Enum.any?(&(&1.first == "/one" or &1.third == "/two"))
    end

    test "a reload in the middle does not become its own route", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/a"),
        pageview_event(2, "/b"),
        pageview_event(3, "/b"),
        pageview_event(4, "/c"),
        tick_event(4, %{"d" => 40_000})
      ])

      journeys = filters(site) |> Analytics.journeys(20)

      refute Enum.any?(journeys, &(&1.first == &1.second or &1.second == &1.third))
    end

    test "does not invent a transition into the first page of a visit", %{site: site} do
      submit(site, [init_event(), pageview_event(1, "/only"), tick_event(1, %{"d" => 20_000})])

      refute filters(site) |> Analytics.flow(50) |> Enum.any?(&(&1.to == "/only"))
    end

    test "keeps a reload out of the diagram", %{site: site} do
      submit(site, [
        init_event(),
        pageview_event(1, "/same"),
        pageview_event(2, "/same"),
        tick_event(2, %{"d" => 20_000})
      ])

      # A real pageview, and a loop on the diagram says nothing about a route.
      refute filters(site) |> Analytics.flow(50) |> Enum.any?(&(&1.from == &1.to))
    end

    test "falls back to the client's value when the row before is not here", %{site: site} do
      # A visit whose opening pageviews never reached us: seq 9 is the first row
      # held, so there is nothing behind it to look at.
      submit(site, [
        init_event(),
        pageview_event(9, "/deep", %{"fp" => "/came-from"}),
        tick_event(9, %{"d" => 30_000})
      ])

      routes = filters(site) |> Analytics.flow(50) |> Enum.map(&{&1.from, &1.to})

      assert {"/came-from", "/deep"} in routes
    end
  end

  describe "excluding sessions one row at a time" do
    test "unticking one row removes one row, not every row sharing its origin",
         %{site: site} do
      # The bug this replaced: the row checkbox toggled the origin, and on real
      # traffic every session shares one, so unticking one unticked all of them.
      sessions = Repo.all(from s in Session, where: s.site_id == ^site.id, order_by: s.id)
      Repo.update_all(from(s in Session, where: s.site_id == ^site.id), set: [ip_hash: "same"])

      visible = Enum.filter(sessions, &(not &1.anomalous and not &1.crawler))
      assert length(visible) >= 1

      before = Analytics.overview(filters(site)).sessions
      one = hd(visible)

      after_one = Analytics.overview(filters(site, %{exclude_sessions: [one.id]})).sessions

      assert after_one == before - 1
    end

    test "the sessions table answers to the same filters as the numbers above it",
         %{site: site} do
      # It used to build its own query and apply only the anomaly and crawler
      # toggles, so dragging the session-length slider changed every figure on
      # the page except the list of rows being filtered.
      wide = Analytics.recent_sessions(filters(site))
      narrow = Analytics.recent_sessions(filters(site, %{dwell_max: 1}))

      assert wide != []
      assert narrow == []
    end

    test "a row struck out by hand stays listed, so it can be put back", %{site: site} do
      [one | _] =
        Repo.all(from s in Session, where: not s.anomalous and not s.crawler, order_by: s.id)

      listed =
        filters(site, %{exclude_sessions: [one.id]})
        |> Analytics.recent_sessions()
        |> Enum.map(& &1.id)

      # Excluded from the report, still on the screen: this list is the only
      # place the checkbox can be unticked again.
      assert one.id in listed
      assert Analytics.overview(filters(site, %{exclude_sessions: [one.id]})).sessions == 0
    end

    test "the live panel hides a struck-out session, and stops counting it",
         %{site: site} do
      [one | _] =
        Repo.all(from s in Session, where: not s.anomalous and not s.crawler, order_by: s.id)

      now = DateTime.utc_now()

      Repo.update_all(from(s in Session, where: s.id == ^one.id),
        set: [started_at: now, last_seen_at: now]
      )

      before = Analytics.active_now(filters(site), now)
      assert Enum.any?(before.sessions_list, &(&1.id == one.id))

      after_exclusion = Analytics.active_now(filters(site, %{exclude_sessions: [one.id]}), now)

      # "Who is here right now" should not include a visit you have decided is
      # not traffic — in the list or in the number above it.
      refute Enum.any?(after_exclusion.sessions_list, &(&1.id == one.id))
      assert after_exclusion.sessions == before.sessions - 1
    end

    test "ids arrive from a query string, so strings and rubbish are handled", %{site: site} do
      assert filters(site, %{exclude_sessions: ["12", 34]}).exclude_sessions == [12, 34]
      assert filters(site, %{exclude_sessions: ["banana", "-1", "0", nil]}).exclude_sessions == []
    end

    test "reaches pageviews as well as the session list", %{site: site} do
      [session | _] =
        Repo.all(from s in Session, where: like(s.entry_path, "/"), order_by: s.id)

      paths =
        filters(site, %{exclude_sessions: [session.id]})
        |> Analytics.pages()
        |> Enum.map(& &1.name)

      refute "/pricing" in paths
    end
  end

  describe "origins" do
    setup %{site: site} do
      # Set directly, because the hash comes off the request address and a
      # submit in a test does not carry one. One on the visit that shows up by
      # default, one on the anomaly, so both halves of this screen have data.
      sessions = Repo.all(from s in Session, where: s.site_id == ^site.id, order_by: s.id)
      visible = Enum.find(sessions, &(not &1.anomalous and not &1.crawler))
      odd = Enum.find(sessions, & &1.anomalous)

      Repo.update_all(from(s in Session, where: s.id == ^visible.id), set: [ip_hash: "aaa111"])
      Repo.update_all(from(s in Session, where: s.id == ^odd.id), set: [ip_hash: "bbb222"])

      %{visible: "aaa111", odd_origin: "bbb222"}
    end

    test "groups sessions by origin without hiding the anomalous ones", %{site: site} do
      rows = Analytics.origins(filters(site))

      # The anomaly filter is off for this list on purpose: the anomalous count
      # is the reason a row gets suggested, so hiding it would hide the reason.
      assert Enum.any?(rows, &(&1.anomalous > 0))
      assert Enum.all?(rows, &is_binary(&1.ip_hash))
    end

    test "excluding an origin removes its sessions everywhere", %{site: site, visible: visible} do
      before = Analytics.overview(filters(site)).sessions
      after_exclusion = Analytics.overview(filters(site, %{exclude_origins: [visible]})).sessions

      assert after_exclusion == before - 1
    end

    test "a session with no origin survives the filter", %{site: site, visible: visible} do
      # A visit that arrived with no resolvable address has no hash at all, and
      # `not in` against NULL yields NULL in SQL — which would drop it.
      submit(site, [
        init_event(),
        pageview_event(1, "/no-origin"),
        tick_event(1, %{"d" => 30_000, "am" => 20_000})
      ])

      paths =
        filters(site, %{exclude_origins: [visible]})
        |> Analytics.pages()
        |> Enum.map(& &1.name)

      assert "/no-origin" in paths
      refute "/pricing" in paths
    end

    test "suggests an origin whose sessions are mostly junk", %{site: site} do
      # Six sessions from one place, four of them classified anomalous.
      for i <- 1..6 do
        submit(site, [
          init_event(),
          pageview_event(1, "/spray-#{i}"),
          tick_event(1, %{"d" => 1_000, "am" => 0, "a" => 0})
        ])
      end

      sprayed =
        Repo.all(from s in Session, where: like(s.entry_path, "/spray-%"), select: s.id)

      Repo.update_all(from(s in Session, where: s.id in ^sprayed), set: [ip_hash: "ccc333"])

      Repo.update_all(from(s in Session, where: s.id in ^Enum.take(sprayed, 4)),
        set: [anomalous: true]
      )

      row = Analytics.origins(filters(site)) |> Enum.find(&(&1.ip_hash == "ccc333"))

      assert row.suggested
      assert row.reason =~ "junk"
    end

    test "does not suggest an ordinary origin", %{site: site, visible: visible} do
      row = Analytics.origins(filters(site)) |> Enum.find(&(&1.ip_hash == visible))

      refute row.suggested
      assert row.reason == nil
    end
  end

  describe "the session-length range" do
    # The setup's clean visit dwells 40s (bucket 4, "2-5m" has ceiling 300s, so
    # 40s lands in bucket 2, "10s-1m"). The anomaly is 20 hours, the crawler 3s.
    test "everything is included by default", %{site: site} do
      f = filters(site)

      refute Analytics.dwell_filtered?(f)
      assert Analytics.overview(f).sessions == 1
    end

    test "a floor drops the visits below it", %{site: site} do
      # Nothing in the setup dwells longer than a minute except the anomaly,
      # which the default filter already hides.
      above_a_minute = filters(site, %{dwell_min: 3})

      assert Analytics.dwell_filtered?(above_a_minute)
      assert Analytics.overview(above_a_minute).sessions == 0

      # And the same range keeps it once the short visit is inside.
      assert Analytics.overview(filters(site, %{dwell_min: 2})).sessions == 1
    end

    test "a ceiling drops the visits above it", %{site: site} do
      under_ten_seconds = filters(site, %{dwell_max: 1})

      assert Analytics.dwell_filtered?(under_ten_seconds)
      assert Analytics.overview(under_ten_seconds).sessions == 0
    end

    test "handles dragged past each other read as a range, not an empty set", %{site: site} do
      swapped = filters(site, %{dwell_min: 5, dwell_max: 1})

      assert swapped.dwell_min == 1
      assert swapped.dwell_max == 5
    end

    test "the top bucket has no ceiling, so the longest visits stay in", %{site: site} do
      top = filters(site, %{dwell_min: 8})

      assert top.dwell_to_ms == nil

      # The twenty hour session is the only thing up there, and it is only
      # visible with the anomaly filter off.
      shown = filters(site, %{dwell_min: 8, exclude_anomalies: false})
      assert Analytics.overview(shown).sessions == 1
    end

    test "out-of-range and unparseable values fall back rather than crashing", %{site: site} do
      assert filters(site, %{dwell_min: -4, dwell_max: 99}).dwell_min == 0
      assert filters(site, %{dwell_min: -4, dwell_max: 99}).dwell_max == 8
      assert filters(site, %{dwell_min: "3"}).dwell_min == 3
      assert filters(site, %{dwell_min: "banana"}).dwell_min == 0
    end

    test "reaches pageviews and events too, not just the session list", %{site: site} do
      # One filter, applied everywhere: a range that excludes a session must
      # also exclude its pages, or the tabs disagree with each other.
      wide = filters(site)
      narrow = filters(site, %{dwell_max: 1})

      assert Analytics.pages(wide) != []
      assert Analytics.pages(narrow) == []
    end
  end

  describe "the live series" do
    test "keeps every minute of the window, including the quiet ones", %{site: site} do
      series = Analytics.active_now(filters(site)).series

      # Thirty buckets whatever the traffic: a chart that returned only the
      # minutes with data would draw two visits an hour apart side by side and
      # call it a busy half hour.
      assert length(series) == 30
      assert Enum.all?(series, &is_integer(&1.sessions))

      minutes =
        series
        |> Enum.map(& &1.at)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> DateTime.diff(b, a) end)

      assert Enum.all?(minutes, &(&1 == 60))
    end

    test "counts a session in every minute it spanned", %{site: site} do
      submit(site, [init_event(), pageview_event(1, "/long")])

      [long | _] =
        Repo.all(from s in Session, where: s.site_id == ^site.id, order_by: [desc: s.id])

      now = DateTime.utc_now()

      # One visit, still open, that started ten minutes ago.
      Repo.update_all(from(s in Session, where: s.id == ^long.id),
        set: [started_at: DateTime.add(now, -10, :minute), last_seen_at: now]
      )

      series = Analytics.active_now(filters(site), now).series
      covered = Enum.count(series, &(&1.sessions > 0))

      # Bucketing on last_seen_at alone would put it in one bucket and draw the
      # ten minutes it was actually being read as empty.
      assert covered >= 10
    end

    test "an account with no traffic still gets a full, flat window" do
      site = site_fixture(%{key: "quiet-live"})
      series = Analytics.active_now(Analytics.filters(site.id, %{range: "30d"})).series

      assert length(series) == 30
      assert Enum.all?(series, &(&1.sessions == 0))
    end
  end

  describe "bounce rate" do
    test "counts a visit that did not last ten seconds, however many pages", %{site: site} do
      # Two pages in four seconds is someone who arrived, saw the wrong thing
      # and left. Counting pages instead of time would score this a success.
      submit(site, [
        init_event(),
        pageview_event(1, "/", %{"title" => "Home"}),
        pageview_event(2, "/pricing", %{"title" => "Pricing", "fp" => "/", "ft" => "Home"}),
        tick_event(2, %{"d" => 4_000, "am" => 4_000})
      ])

      overview = Analytics.overview(filters(site))

      assert overview.sessions == 2
      assert overview.bounce_rate == 50.0
    end

    test "a single page held for a long time is not a bounce", %{site: site} do
      # The point of counting time rather than pages: someone who reads one
      # long answer and leaves got what they came for. A pageview-count rule
      # calls that a bounce.
      submit(site, [
        init_event(),
        pageview_event(1, "/docs", %{"title" => "Docs"}),
        tick_event(1, %{"d" => 90_000, "am" => 80_000})
      ])

      overview = Analytics.overview(filters(site))

      assert overview.sessions == 2
      assert overview.bounce_rate == 0.0
    end
  end

  test "hides crawlers and anomalies from the overview by default", %{site: site} do
    overview = Analytics.overview(filters(site))

    assert overview.sessions == 1
    assert overview.crawler_sessions == 1
    assert overview.excluded_sessions == 1
  end

  test "the crawler toggle reveals only crawlers", %{site: site} do
    overview = Analytics.overview(filters(site, %{exclude_crawlers: false}))
    assert overview.sessions == 2
  end

  test "the anomaly toggle reveals only anomalies", %{site: site} do
    overview = Analytics.overview(filters(site, %{exclude_anomalies: false}))
    assert overview.sessions == 2
  end

  test "both toggles together reveal everything", %{site: site} do
    overview =
      Analytics.overview(filters(site, %{exclude_crawlers: false, exclude_anomalies: false}))

    assert overview.sessions == 3
  end

  test "the filters apply to pages, clicks and flow, not just sessions", %{site: site} do
    clean = filters(site)
    all = filters(site, %{exclude_crawlers: false, exclude_anomalies: false})

    # The crawler and the idle tab each add a pageview that must stay hidden.
    assert Enum.sum(Enum.map(Analytics.pages(clean), & &1.views)) == 2
    assert Enum.sum(Enum.map(Analytics.pages(all), & &1.views)) == 4

    assert Analytics.clicks(clean, :id) |> length() == 2
    assert Analytics.flow(clean) == [%{from: "/", to: "/pricing", count: 1, sessions: 1}]
  end

  test "groups pages and flow by title when asked", %{site: site} do
    f = filters(site, %{group_by: :title})

    assert [%{from: "Home", to: "Pricing"}] = Analytics.flow(f)
    assert Enum.map(Analytics.pages(f), & &1.name) |> Enum.sort() == ["Home", "Pricing"]
  end

  test "segregates clicks by id and by class", %{site: site} do
    f = filters(site)

    by_id = Map.new(Analytics.clicks(f, :id), &{&1.name, &1.count})
    assert by_id == %{"cta" => 1, "gh" => 1}

    by_class = Map.new(Analytics.clicks(f, :class), &{&1.name, &1.count})
    assert by_class == %{"btn" => 2, "primary" => 1}
  end

  test "reports outbound destinations and how they were caught", %{site: site} do
    assert [link] = Analytics.outbound_links(filters(site))

    assert link.host == "github.com"
    assert link.count == 1
    assert link.mousedown == 1
  end

  test "the crawler report ignores the crawler filter", %{site: site} do
    # Otherwise the report would be empty exactly when it is needed.
    for f <- [filters(site), filters(site, %{exclude_crawlers: false})] do
      overview = Analytics.crawler_overview(f)
      assert overview.sessions == 1
      assert overview.human_sessions == 2

      assert [%{name: "GPTBot", kind: "ai", count: 1}] = Analytics.crawlers_by_name(f)
      assert [%{name: "ai", count: 1}] = Analytics.crawlers_by_kind(f)
      assert [%{name: "/", count: 1}] = Analytics.crawler_pages(f)
    end
  end

  test "the anomaly breakdown excludes crawlers so nothing is counted twice", %{site: site} do
    reasons = Analytics.anomaly_breakdown(filters(site))
    assert "extreme_dwell" in Enum.map(reasons, & &1.reason)

    crawler = Repo.one!(from s in Session, where: s.crawler, select: s)
    refute crawler.anomalous
  end

  describe "the filters are a web-analytics concern" do
    setup %{site: site} do
      # A tool reporting its own usage through the ping API: no dwell, no
      # heartbeats, and honest enough to declare itself automated.
      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [init_event(%{"bot" => "agent"}), pageview_event(1, "/agent-screen")],
            token: "ai-1"
          ),
          received_at: DateTime.utc_now(),
          channel: "ai",
          project: "my-agent"
        )

      AnomalyWorker.classify_all()
      :ok
    end

    test "an AI tool's own telemetry is never hidden by the crawler filter", %{site: site} do
      f = Analytics.filters(site.id, %{range: "30d"})

      # The crawler filter is on by default and this session is flagged as a
      # crawler, but it is not web traffic, so it must still be reported.
      session = Repo.one!(from s in Session, where: s.token == "ai-1")
      assert session.crawler
      assert session.channel == "ai"

      assert Enum.any?(Analytics.pages(f), &(&1.name == "/agent-screen"))
    end

    test "an AI tool's own telemetry is never hidden by the dwell filter", %{site: _site} do
      session = Repo.one!(from s in Session, where: s.token == "ai-1")

      # Zero dwell and zero heartbeats is the shape of a ping, not an anomaly.
      assert session.dwell_ms == 0
      assert session.tick_count == 0
      refute session.anomalous
      assert session.anomaly_reasons == []
    end

    test "web crawlers are still filtered out of web reports", %{site: site} do
      f = Analytics.filters(site.id, %{range: "30d"})

      # The GPTBot session from the outer setup is web traffic and stays hidden.
      # It shares the "/" path with the clean session, so the check is that its
      # view is not counted rather than that the path is absent.
      assert %{views: 1} = Enum.find(Analytics.pages(f), &(&1.name == "/"))
      assert Analytics.overview(f).crawler_sessions == 1
    end

    test "the crawler report covers site crawlers, not an account's own tools", %{site: site} do
      f = Analytics.filters(site.id, %{range: "30d"})

      names = Analytics.crawlers_by_name(f) |> Enum.map(& &1.name)
      assert "GPTBot" in names
      refute "Reported by client" in names
    end
  end

  test "records the heartbeat resolution each session was tracked at", %{site: site} do
    submit(site, [
      init_event(%{"ua" => "Mozilla/5.0 (compatible; ClaudeBot/1.0)", "hb" => 10_000}),
      pageview_event(1, "/")
    ])

    bot = Repo.one!(from s in Session, where: s.crawler_name == "ClaudeBot")
    assert bot.heartbeat_ms == 10_000
    assert bot.crawler_kind == "ai"

    _ = site
  end

  test "navigation summary reports what surrounds a page", %{site: site} do
    summary = Analytics.navigation_summary(filters(site), "/pricing")

    assert summary.totals.views == 1
    assert summary.totals.exits == 1
    assert [%{name: "/", count: 1}] = summary.before
    assert summary.next == []
  end

  test "scroll and dwell distributions bucket without crashing", %{site: site} do
    scroll = Analytics.scroll_distribution(filters(site))
    assert length(scroll) == 10

    # Every bar is captioned. The histogram component reads `:label`, so a bucket
    # without one renders an empty span and the chart becomes ten unnamed bars.
    assert Enum.all?(scroll, &is_binary(&1.label))
    assert Enum.map(scroll, & &1.label) |> Enum.take(3) == ["0-9%", "10-19%", "20-29%"]

    # `LEAST(pct/10, 9)` files 100% with 90-99, so the last bucket really does
    # span eleven points and its caption has to say so.
    assert List.last(scroll).label == "90-100%"
    assert List.last(scroll).to == 100

    buckets = Analytics.dwell_distribution(filters(site))

    assert length(buckets) == 9
    # Nothing below five seconds is subdivided.
    assert List.first(buckets).label == "0-5s"
    assert Enum.map(buckets, & &1.label) |> Enum.take(4) == ["0-5s", "5-10s", "10s-1m", "1-2m"]
    assert List.last(buckets).label == "1h+"
    assert Analytics.timeseries(filters(site)) != []
  end

  describe "event flow" do
    setup do
      site = site_fixture(%{key: "evflow"})

      # One run, in order: started, two tools, completed.
      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [
            init_event(),
            pageview_event(1, "/"),
            %{
              "n" => "event",
              "t" => 1_000_000,
              "pv" => 1,
              "name" => "run_started",
              "data" => %{}
            },
            %{
              "n" => "event",
              "t" => 1_000_100,
              "pv" => 1,
              "name" => "tool_called",
              "data" => %{"tool" => "search"}
            },
            %{
              "n" => "event",
              "t" => 1_000_200,
              "pv" => 1,
              "name" => "tool_called",
              "data" => %{"tool" => "read"}
            },
            %{
              "n" => "event",
              "t" => 1_000_300,
              "pv" => 1,
              "name" => "run_completed",
              "data" => %{"outcome" => "success"}
            }
          ]),
          received_at: DateTime.utc_now()
        )

      %{site: site, f: Analytics.filters(site.id, %{range: "24h"})}
    end

    test "pairs consecutive events within a session", %{f: f} do
      pairs = Analytics.event_flow(f) |> Enum.map(&{&1.from, &1.to, &1.count})

      assert {"run_started", "tool_called", 1} in pairs
      assert {"tool_called", "tool_called", 1} in pairs
      assert {"tool_called", "run_completed", 1} in pairs
    end

    test "does not pair across sessions", %{site: site, f: f} do
      # A second run's first event must not follow the first run's last one.
      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [
            init_event(),
            pageview_event(1, "/"),
            %{"n" => "event", "t" => 1_000_000, "pv" => 1, "name" => "run_started", "data" => %{}}
          ]),
          received_at: DateTime.utc_now()
        )

      pairs = Analytics.event_flow(f) |> Enum.map(&{&1.from, &1.to})

      refute {"run_completed", "run_started"} in pairs
    end

    test "entries are what a session opens with, exits what it stops at", %{f: f} do
      assert [%{name: "run_started", count: 1}] = Analytics.event_entries(f)
      assert [%{name: "run_completed", count: 1}] = Analytics.event_exits(f)
    end

    test "a sequence comes back in order, with attributes", %{f: f} do
      assert [%{events: events}] = Analytics.event_sequences(f, "tool_called")

      assert Enum.map(events, & &1.name) ==
               ~w(run_started tool_called tool_called run_completed)

      assert Enum.at(events, 1).attrs == %{"tool" => "search"}
    end

    test "a session with one event produces no transitions", %{f: f} do
      # It is still an entry and an exit, which is the honest reading.
      assert Analytics.event_flow(f) != []
      assert length(Analytics.event_entries(f)) == 1
    end
  end

  describe "domains" do
    setup do
      site = site_fixture(%{key: "domains"})

      for {host, count} <- [{"www.example.com", 3}, {"app.example.com", 1}] do
        for _ <- 1..count do
          {:ok, _} =
            Ingest.submit_sync(
              site,
              payload(site, [
                init_event(),
                pageview_event(1, "/", %{"url" => "https://#{host}/"})
              ]),
              received_at: DateTime.utc_now()
            )
        end
      end

      %{site: site, f: Analytics.filters(site.id, %{range: "24h"})}
    end

    test "lists every host the tag was deployed on, busiest first", %{f: f} do
      assert [%{name: "www.example.com", count: 3}, %{name: "app.example.com", count: 1}] =
               Analytics.domains(f)
    end

    test "filtering by host narrows every report to that domain", %{site: site} do
      f = Analytics.filters(site.id, %{range: "24h", host: "app.example.com"})

      assert Analytics.overview(f).sessions == 1
      assert Analytics.domains(f) |> length() == 2, "the picker still lists all of them"
    end

    test "an unknown host matches nothing rather than everything", %{site: site} do
      f = Analytics.filters(site.id, %{range: "24h", host: "nope.example.com"})

      assert Analytics.overview(f).sessions == 0
    end
  end
end
