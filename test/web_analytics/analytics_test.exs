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

    test "an AI tool's own telemetry is never hidden by the dwell filter", %{site: site} do
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
    assert length(Analytics.scroll_distribution(filters(site))) == 10
    buckets = Analytics.dwell_distribution(filters(site))

    assert length(buckets) == 9
    # Nothing below five seconds is subdivided.
    assert List.first(buckets).label == "0-5s"
    assert Enum.map(buckets, & &1.label) |> Enum.take(4) == ["0-5s", "5-10s", "10s-1m", "1-2m"]
    assert List.last(buckets).label == "1h+"
    assert Analytics.timeseries(filters(site)) != []
  end
end
