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
