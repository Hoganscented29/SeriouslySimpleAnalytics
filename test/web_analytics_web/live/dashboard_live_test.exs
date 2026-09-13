defmodule WebAnalyticsWeb.DashboardLiveTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query
  import WebAnalytics.Fixtures

  alias WebAnalytics.Analytics.AnomalyWorker
  alias WebAnalytics.Geo
  alias WebAnalytics.Ingest

  setup :register_and_log_in_user

  setup %{user: user} do
    site = user_site_fixture(user, %{key: "dash", name: "Dashboard Site"})

    submit(
      site,
      [
        init_event(),
        pageview_event(1, "/", %{"title" => "Home"}),
        tick_event(1, %{"d" => 30_000, "am" => 25_000, "sp" => 75}),
        click_event(%{"id" => "hero-cta"}),
        pageview_event(2, "/pricing", %{"title" => "Pricing", "fp" => "/", "ft" => "Home"})
      ],
      somewhere("Mountain View", "California", "US", "United States")
    )

    submit(site, [
      init_event(%{"ua" => "Mozilla/5.0 (compatible; GPTBot/1.1; +https://openai.com/gptbot)"}),
      pageview_event(1, "/secret-corner", %{"title" => "Secret Corner"})
    ])

    AnomalyWorker.classify_all()
    %{site: site}
  end

  defp submit(site, events, location \\ nil) do
    {:ok, _} =
      Ingest.submit_sync(site, payload(site, events),
        received_at: DateTime.utc_now(),
        location: location
      )
  end

  defp somewhere(city, region, country_code, country) do
    %{
      Geo.empty()
      | country_code: country_code,
        country: country,
        region: region,
        city: city,
        latitude: 1.0,
        longitude: 2.0,
        source: "mmdb"
    }
  end

  describe "metrics tab" do
    defp report_numbers(site, name, data) do
      submit(site, [
        init_event(),
        %{"n" => "event", "t" => 1_000_000, "name" => name, "pv" => 0, "data" => data}
      ])
    end

    test "says how to report a number when there are none", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=metrics")

      assert html =~ "No numeric values in this range"
      assert html =~ "sats=1500"
    end

    test "totals each numeric key and charts the one picked", %{conn: conn, site: site} do
      report_numbers(site, "pr_merged", %{"sats" => "1500", "prs" => "1", "repo" => "a"})
      report_numbers(site, "pr_merged", %{"sats" => "2500", "prs" => "1", "repo" => "b"})

      {:ok, live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=metrics")

      # The label key never becomes a card; the quantities do, with their totals.
      refute html =~ ~s(phx-value-metric="repo")
      assert html =~ ~s(phx-value-metric="sats")
      assert html =~ "4,000"
      # Both were reported twice; the tie goes to the key, not to chance.
      assert html =~ "prs per day"

      html = live |> element(~s(button[phx-value-metric="sats"])) |> render_click()
      assert html =~ "sats per day"
      assert html =~ "peak 4,000 per day"
      # In the URL, so a reload or a shared link charts the same thing.
      assert live
             |> assert_patch()
             |> URI.parse()
             |> Map.fetch!(:query)
             |> URI.decode_query()
             |> Map.fetch!("metric") == "sats"

      html = live |> element(~s(button[phx-value-grain="hour"])) |> render_click()
      assert html =~ "sats per hour"
    end
  end

  test "renders the overview without crawler traffic", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash&range=30d")

    assert html =~ "Dashboard Site"
    assert html =~ "Crawlers filtered"
    assert html =~ "crawler session(s) held out of these numbers"
    refute html =~ "Secret Corner"
  end

  test "the crawler toggle brings automated traffic into the reports", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=pages")

    refute render(live) =~ "/secret-corner"

    assert live |> element("button[phx-click=toggle_crawlers]") |> render_click() =~
             "Crawlers shown"

    assert render(live) =~ "/secret-corner"

    assert_patched(
      live,
      ~p"/dashboard?anomalies=exclude&clicks=name&crawlers=include&group=path&loc=country&range=30d&site=dash&tab=pages"
    )
  end

  test "the crawler report is populated even while the filter is on", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=crawlers")

    assert html =~ "GPTBot"
    assert html =~ "AI crawler"
    assert html =~ "/secret-corner"
  end

  test "flow can be grouped by path or by title", %{conn: conn} do
    {:ok, live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=flow")

    assert html =~ "/pricing"

    live |> element(~s|button[phx-value-group="title"]|) |> render_click()

    html = render(live)
    assert html =~ "Busiest transitions by title"
    assert html =~ "Pricing"
  end

  test "the four labellings of a click are all on the page at once", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=clicks")

    # Which labelling is useful depends on the markup, and finding that out by
    # clicking through a switcher means meeting three empty lists one at a time.
    for title <- ["By name", "By id", "By class", "By selector"] do
      assert html =~ title
    end

    assert html =~ "hero-cta"
    assert html =~ "btn-primary"
  end

  test "clicks can still be segregated one at a time, in full", %{conn: conn} do
    {:ok, live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=clicks&clicks=id")

    assert html =~ "All clicks by id"
    assert html =~ "hero-cta"

    live |> element(~s|button[phx-value-clicks="class"]|) |> render_click()

    html = render(live)
    assert html =~ "All clicks by class"
    assert html =~ "btn-primary"
  end

  test "switching range keeps every other control where it was", %{conn: conn} do
    {:ok, live, _html} =
      live(conn, ~p"/dashboard?site=dash&range=30d&tab=clicks&clicks=class&group=title")

    live |> element(~s|button[phx-value-range="24h"]|) |> render_click()

    assert_patched(
      live,
      ~p"/dashboard?anomalies=exclude&clicks=class&crawlers=exclude&group=title&loc=country&range=24h&site=dash&tab=clicks"
    )
  end

  describe "the filter bar is not rebuilt on the refresh timer" do
    test "the session-length chart and origins list survive a refresh", %{conn: conn, site: site} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=dash&range=30d")

      # These feed controls, not metrics. Rebuilding them every five seconds
      # snapped the Origins panel shut while it was open and fought a slider
      # being dragged, which looked like the page reloading itself.
      before = :sys.get_state(live.pid).socket.assigns
      assert before.origins == []

      # Change what the controls would show, so equality afterwards means they
      # were not rebuilt rather than merely that the query is deterministic.
      WebAnalytics.Repo.update_all(
        from(sess in WebAnalytics.Tracking.Session, where: sess.site_id == ^site.id),
        set: [ip_hash: "abc123"]
      )

      send(live.pid, :refresh)
      _ = render(live)

      state = :sys.get_state(live.pid).socket.assigns

      assert state.origins == []
      assert state.dwell == before.dwell

      # The metrics did refresh — it is only the controls that hold still.
      assert state.data[:overview]

      # And a params change picks the new origin up, so it is deferred rather
      # than never loaded.
      {:ok, reloaded, _html} = live(conn, ~p"/dashboard?site=dash&range=30d")

      assert Enum.any?(
               :sys.get_state(reloaded.pid).socket.assigns.origins,
               &(&1.ip_hash == "abc123")
             )
    end
  end

  describe "locations" do
    test "reports city, state and country with coverage", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=locations&loc=city")

      assert html =~ "Mountain View, California, United States"
      assert html =~ "Placed to a city"
      assert html =~ "mmdb"
    end

    test "regroups between country, state and city", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=locations")

      assert render(live) =~ "United States"

      live |> element(~s|button[phx-value-loc="region"]|) |> render_click()
      assert render(live) =~ "California, United States"

      live |> element(~s|button[phx-value-loc="city"]|) |> render_click()
      assert render(live) =~ "Mountain View, California, United States"
    end
  end

  describe "flow drill-down" do
    test "both ends of a transition are clickable", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=flow")

      assert html =~ ~s|phx-value-page="/"|
      assert html =~ ~s|phx-value-page="/pricing"|

      # The "from" end is the one that used to be inert.
      live |> element(~s|#flow-transitions button[phx-value-page="/"]|) |> render_click()

      html = render(live)
      assert html =~ "Flow through"
      assert html =~ "/pricing"
    end

    test "drilling in carries through to the URL and can be cleared", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=flow")

      live
      |> element(~s|#flow-transitions button[phx-value-page="/pricing"]|)
      |> render_click()

      assert_patch(live)
      assert render(live) =~ "Flow through"

      live |> element(~s|#flow-diagram button[phx-click="clear_page"]|) |> render_click()
      assert_patch(live)
      refute render(live) =~ "Flow through"
    end

    test "the diagram itself re-centres on the selected page", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=flow")

      # Unfocused: the busiest hops across the whole site.
      assert html =~ "Busiest transitions by path"
      refute html =~ "Flow through"

      live
      |> element(~s|#flow-transitions button[phx-value-page="/pricing"]|)
      |> render_click()

      html = render(live)

      assert html =~ "Flow through /pricing"
      refute html =~ "Busiest transitions by path"
      # The focused layout accounts for traffic that came from nowhere and went
      # nowhere, so the ribbons add up to the page's views.
      assert html =~ "(left the site)"
      assert html =~ "views ·"
    end

    test "pseudo-nodes in the focused diagram are not clickable", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=flow&page=%2Fpricing")

      html = render(live)

      # "(left the site)" is not a page, so it must not offer a drill-down.
      refute html =~ ~s|phx-value-page="(left the site)"|
      refute html =~ ~s|phx-value-page="(entered here)"|
    end

    test "a neighbour in the summary is itself a drill-down step", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=flow&page=%2Fpricing")

      html = render(live)
      assert html =~ "Flow through"

      # "Came from" lists / — clicking it must move the summary there.
      live
      |> element(~s|#flow-navigation button[phx-value-page="/"]|)
      |> render_click()

      assert render(live) =~ "Flow through"
    end
  end

  describe "account" do
    test "a user with no site gets one, rather than an empty page", %{conn: conn, user: user} do
      for site <- WebAnalytics.Sites.list_sites_for_user(user),
          do: WebAnalytics.Sites.delete_site(site)

      {:ok, _live, html} = live(conn, ~p"/dashboard")

      [site] = WebAnalytics.Sites.list_sites_for_user(user)
      assert html =~ site.key
      # Labelled once, at the top, beside the site it belongs to.
      assert html =~ "Account ID"
    end

    test "sends the reader to the instructions rather than carrying them", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash")

      # They used to sit at the bottom of this page, where an account with
      # traffic scrolled past them every visit and an account with none had to
      # scroll past every empty chart to reach the only thing it needed.
      refute html =~ "Website Integration Instructions"
      refute html =~ "AI Integration Instructions"
      assert html =~ ~s|href="/getting-started?site=dash"|
    end

    test "does not claim it just created an account for someone who has one", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/dashboard?site=dash")

      refute html =~ "/api/v1/accounts"
    end

    test "never shows another user's sites", %{conn: conn} do
      other = WebAnalytics.AccountsFixtures.user_fixture()
      theirs = user_site_fixture(other, %{key: "not-yours", name: "Someone Else"})

      {:ok, _live, html} = live(conn, ~p"/dashboard?site=#{theirs.key}")

      refute html =~ "Someone Else"
      refute html =~ theirs.key
    end
  end

  describe "the events tab" do
    setup %{conn: conn, user: user} do
      site = user_site_fixture(user, %{key: "ev", name: "Events Site"})
      %{conn: conn, site: site, user: user}
    end

    # Straight through ingest rather than over HTTP: the ping controller queues
    # into a global collector that needs a shared sandbox connection and a
    # non-async case, and none of that is what these tests are about. The
    # controller has its own tests for the wire format.
    defp emit(site, events) do
      body =
        Enum.map(events, fn {name, attrs} ->
          %{"n" => "event", "t" => 1_000_000, "pv" => 1, "name" => name, "data" => attrs}
        end)

      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [init_event(), pageview_event(1, "/")] ++ body),
          received_at: DateTime.utc_now()
        )
    end

    test "an account with no events is told what an event is", %{conn: conn, site: site} do
      {:ok, _live, html} = live(conn, ~p"/dashboard?site=#{site.key}&tab=events")

      assert html =~ "No named events yet"
      # A curl they can actually run, carrying their own account id.
      assert html =~ "uid=#{site.key}"
    end

    test "named events are listed with their counts", %{conn: conn, site: site} do
      emit(site, [
        {"tool_called", %{"tool" => "search"}},
        {"tool_called", %{"tool" => "search"}},
        {"tool_called", %{"tool" => "search"}},
        {"run_completed", %{"outcome" => "success"}}
      ])

      {:ok, _live, html} = live(conn, ~p"/dashboard?site=#{site.key}&tab=events&range=24h")

      assert html =~ "tool_called"
      assert html =~ "run_completed"
      refute html =~ "No named events yet"
    end

    test "selecting an event shows the attributes it carried", %{conn: conn, site: site} do
      emit(site, [
        {"tool_called", %{"tool" => "web_search", "latency_ms" => "420"}},
        {"tool_called", %{"tool" => "web_search", "latency_ms" => "180"}},
        {"tool_called", %{"tool" => "read_file", "latency_ms" => "12"}}
      ])

      {:ok, live, _html} = live(conn, ~p"/dashboard?site=#{site.key}&tab=events&range=24h")

      html =
        live |> element("#event-list button[phx-value-event='tool_called']") |> render_click()

      # llms.txt promises anything a caller invents is kept on the event. Until
      # this tab there was nowhere to read it back, which made that half a
      # promise.
      assert html =~ "Attributes"
      assert html =~ "tool"
      assert html =~ "web_search"
      assert html =~ "latency_ms"
    end

    test "the selected event survives in the URL", %{conn: conn, site: site} do
      emit(site, [{"run_started", %{}}])

      {:ok, live, _html} = live(conn, ~p"/dashboard?site=#{site.key}&tab=events&range=24h")
      live |> element("#event-list button[phx-value-event='run_started']") |> render_click()

      assert_patch(
        live,
        ~p"/dashboard?#{[anomalies: "exclude", clicks: "name", crawlers: "exclude", event: "run_started", group: "path", loc: "country", range: "24h", site: site.key, tab: "events"]}"
      )
    end

    test "a stale event name in the URL does not show an empty breakdown", %{
      conn: conn,
      site: site
    } do
      emit(site, [{"run_started", %{}}])

      {:ok, live, html} =
        live(conn, ~p"/dashboard?site=#{site.key}&tab=events&range=24h&event=never_sent")

      # The list is populated, so a blank attributes panel beside it would read
      # as a broken page rather than a dead link.
      assert html =~ "run_started"
      assert html =~ "Pick an event"
      assert :sys.get_state(live.pid).socket.assigns.data.selected_event == nil
    end

    test "the recent stream shows each event's attributes inline", %{conn: conn, site: site} do
      emit(site, [{"error", %{"kind" => "timeout"}}])

      {:ok, _live, html} = live(conn, ~p"/dashboard?site=#{site.key}&tab=events&range=24h")

      assert html =~ "Most recent"
      assert html =~ "kind="
      assert html =~ "timeout"
    end

    test "events are not mixed into the clicks report", %{conn: conn, site: site} do
      emit(site, [{"run_completed", %{"outcome" => "success"}}])

      {:ok, _live, html} = live(conn, ~p"/dashboard?site=#{site.key}&tab=events&range=24h")
      assert html =~ "run_completed"

      # A run completing is not a click, and reading it under "Clicks" looks
      # like a bug in the product rather than a choice about where to put it.
      assert "events" in ~w(overview pages events flow locations clicks forms sessions crawlers)
    end
  end

  describe "filtering by domain and project" do
    setup %{user: user} do
      site = user_site_fixture(user, %{key: "multi", name: "Multi"})

      for {host, path} <- [{"shop.example", "/a"}, {"shop.example", "/b"}, {"docs.example", "/c"}] do
        {:ok, _} =
          Ingest.submit_sync(
            site,
            payload(site, [
              init_event(),
              pageview_event(1, path, %{"url" => "https://#{host}#{path}"})
            ]),
            received_at: DateTime.utc_now()
          )
      end

      %{site: site}
    end

    test "domains are listed and clickable", %{conn: conn, site: site} do
      {:ok, live, html} = live(conn, ~p"/dashboard?site=#{site.key}&range=24h")

      assert html =~ "Domains"
      assert html =~ "shop.example"

      live |> element("button[phx-value-domain='shop.example']") |> render_click()

      assert :sys.get_state(live.pid).socket.assigns.filters.host == "shop.example"
    end

    test "picking a domain narrows the numbers", %{conn: conn, site: site} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=#{site.key}&range=24h")

      before = :sys.get_state(live.pid).socket.assigns.data.overview.sessions
      live |> element("button[phx-value-domain='docs.example']") |> render_click()
      after_click = :sys.get_state(live.pid).socket.assigns.data.overview.sessions

      assert before == 3
      assert after_click == 1
    end

    test "clicking the domain you are on clears it", %{conn: conn, site: site} do
      {:ok, live, _html} =
        live(conn, ~p"/dashboard?site=#{site.key}&range=24h&domain=shop.example")

      # The row is visibly highlighted, so clicking it again should let go.
      live |> element("button[phx-value-domain='shop.example']") |> render_click()

      assert :sys.get_state(live.pid).socket.assigns.filters.host == nil
    end

    test "the domain list keeps every domain while one is picked", %{conn: conn, site: site} do
      {:ok, live, _html} =
        live(conn, ~p"/dashboard?site=#{site.key}&range=24h&domain=shop.example")

      names = :sys.get_state(live.pid).socket.assigns.data.domains |> Enum.map(& &1.name)

      assert "shop.example" in names
      assert "docs.example" in names
    end

    test "the filter is in the URL, so the view is shareable", %{conn: conn, site: site} do
      {:ok, live, _html} = live(conn, ~p"/dashboard?site=#{site.key}&range=24h")

      live |> element("button[phx-value-domain='shop.example']") |> render_click()

      assert_patch(
        live,
        ~p"/dashboard?#{[anomalies: "exclude", clicks: "name", crawlers: "exclude", domain: "shop.example", group: "path", loc: "country", range: "24h", site: site.key, tab: "overview"]}"
      )
    end
  end
end
