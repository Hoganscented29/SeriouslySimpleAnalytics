defmodule WebAnalyticsWeb.DashboardLiveTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WebAnalytics.Fixtures

  alias WebAnalytics.Analytics.AnomalyWorker
  alias WebAnalytics.Geo
  alias WebAnalytics.Ingest

  setup do
    site = site_fixture(%{key: "dash", name: "Dashboard Site"})

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

  test "clicks can be segregated by id or class", %{conn: conn} do
    {:ok, live, html} = live(conn, ~p"/dashboard?site=dash&range=30d&tab=clicks&clicks=id")

    assert html =~ "Clicks by id"
    assert html =~ "hero-cta"

    live |> element(~s|button[phx-value-clicks="class"]|) |> render_click()

    html = render(live)
    assert html =~ "Clicks by class"
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

  test "offers a setup path when no sites exist", %{conn: conn} do
    for site <- WebAnalytics.Sites.list_sites(), do: WebAnalytics.Sites.delete_site(site)

    {:ok, _live, html} = live(conn, ~p"/dashboard")
    assert html =~ "No sites yet"
  end
end
