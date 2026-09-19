defmodule WebAnalytics.TagCoverageTest do
  @moduledoc """
  What the browser tag missed.

  Only answerable because a server-side plug reports the same pageviews the tag
  does: where both reported one they merge into a single row, and where only the
  server did, the row is missing everything a browser has to supply.
  """

  use WebAnalytics.DataCase, async: true

  import WebAnalytics.Fixtures

  alias WebAnalytics.Analytics
  alias WebAnalytics.Ingest

  setup do
    site = site_fixture()

    # Seen by the tag: a viewport, and heartbeats afterwards.
    submit(site, [
      init_event(),
      pageview_event(1, "/", %{"vh" => 900, "dh" => 4200}),
      tick_event(1, %{"d" => 20_000, "sp" => 70})
    ])

    # An agent, reported only by the plug: no viewport, no heartbeat, because
    # nothing ran in a browser.
    submit(
      site,
      [
        init_event(%{"ua" => "ClaudeBot/1.0 (+https://anthropic.com/claudebot)"}),
        pageview_event(1, "/llms.txt", %{"title" => nil}),
        pageview_event(2, "/docs", %{"title" => nil})
      ],
      token: "agent-visit"
    )

    # A person whose JavaScript never ran. This is the interesting one: not a
    # bot, and still invisible to the tag.
    submit(
      site,
      [
        init_event(%{"ua" => "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/120 Safari/537"}),
        pageview_event(1, "/pricing", %{"title" => nil})
      ],
      token: "no-js-visit"
    )

    {:ok, site: site, filters: Analytics.filters(site.id, %{"range" => "24h"})}
  end

  describe "tag_coverage/1" do
    test "counts what the tag saw against everything recorded", %{filters: f} do
      coverage = Analytics.tag_coverage(f)

      assert coverage.pageviews == 4
      assert coverage.tagged == 1
      assert coverage.untagged == 3
      assert coverage.coverage == 25.0
    end

    test "separates automated misses from the ones worth worrying about", %{filters: f} do
      coverage = Analytics.tag_coverage(f)

      # A crawler missing the tag is expected and is the reason the plug exists.
      assert coverage.untagged_crawler == 2

      # A person missing it is a finding: a blocked script, or an untagged page.
      assert coverage.untagged_human == 1
    end

    test "reports coverage of non-automated traffic separately", %{filters: f} do
      coverage = Analytics.tag_coverage(f)

      # Two non-bot pageviews, one of which the tag saw.
      assert coverage.human_pageviews == 2
      assert coverage.human_coverage == 50.0
    end

    test "counts crawlers even though every other report hides them", %{site: site} do
      # The default filters exclude crawlers. A report about what the tag misses
      # that hid the largest thing it misses would be worse than no report.
      filters = Analytics.filters(site.id, %{"range" => "24h", "crawlers" => "exclude"})

      assert Analytics.tag_coverage(filters).untagged_crawler == 2
    end
  end

  describe "untagged_pages/2" do
    test "lists the pages the tag never reported", %{filters: f} do
      paths = Analytics.untagged_pages(f) |> Enum.map(& &1.name)

      assert "/llms.txt" in paths
      assert "/docs" in paths
      assert "/pricing" in paths
      refute "/" in paths, "the tag reported the home page"
    end

    test "splits each page by whether the reader was automated", %{filters: f} do
      pages = Analytics.untagged_pages(f)

      assert %{crawler: 1, human: 0} = Enum.find(pages, &(&1.name == "/llms.txt"))
      assert %{crawler: 0, human: 1} = Enum.find(pages, &(&1.name == "/pricing"))
    end
  end

  describe "untagged_clients/2" do
    test "says what was reading the pages the tag missed", %{filters: f} do
      clients = Analytics.untagged_clients(f)

      assert %{count: 2} = Enum.find(clients, &(&1.name == "ClaudeBot"))
      assert %{count: 1, crawler: false} = Enum.find(clients, &is_nil(&1.name))
    end
  end

  describe "a site the plug is not installed on" do
    test "reports full coverage rather than an alarming zero", %{site: site} do
      other = site_fixture()

      submit(other, [
        init_event(),
        pageview_event(1, "/", %{"vh" => 900}),
        tick_event(1, %{"d" => 5_000})
      ])

      coverage = Analytics.tag_coverage(Analytics.filters(other.id, %{"range" => "24h"}))

      assert coverage.coverage == 100.0
      assert coverage.untagged == 0
      assert Analytics.untagged_pages(Analytics.filters(other.id, %{"range" => "24h"})) == []

      # And the first site is untouched by the second.
      assert Analytics.tag_coverage(Analytics.filters(site.id, %{"range" => "24h"})).untagged == 3
    end
  end

  defp submit(site, events, opts \\ []) do
    {:ok, _} =
      Ingest.submit_sync(site, payload(site, events, opts), received_at: DateTime.utc_now())
  end
end
