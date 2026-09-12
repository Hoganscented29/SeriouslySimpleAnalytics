defmodule WebAnalyticsWeb.CrawlerReportTest do
  # Not async: the plug submits through the global ingest buffer.
  use WebAnalyticsWeb.ConnCase, async: false

  import Ecto.Query
  import WebAnalytics.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias WebAnalytics.Ingest.Collector
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Session

  setup do
    Sandbox.allow(Repo, self(), Process.whereis(Collector))
    Collector.reset()

    site = site_fixture(%{key: "self-site"})
    original = Application.get_env(:web_analytics, :self_site_key)
    Application.put_env(:web_analytics, :self_site_key, site.key)
    on_exit(fn -> Application.put_env(:web_analytics, :self_site_key, original) end)

    %{site: site}
  end

  defp visit(conn, user_agent, path \\ "/") do
    conn |> put_req_header("user-agent", user_agent) |> get(path)
    Collector.flush_sync()
  end

  defp sessions(site) do
    Repo.all(from s in Session, where: s.site_id == ^site.id)
  end

  test "records a crawler the browser tag can never see", %{conn: conn, site: site} do
    visit(conn, "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)")

    assert [session] = sessions(site)
    assert session.crawler
    assert session.crawler_name == "ClaudeBot"
    assert session.crawler_kind == "ai"
    # Says where the record came from: the server saw it, not the tag.
    assert session.client_signal == "server"
  end

  test "a crawl is one session, not one per page", %{conn: conn, site: site} do
    ua = "Mozilla/5.0 AppleWebKit/537.36; compatible; GPTBot/1.2; +https://openai.com/gptbot"

    for path <- ["/", "/claude-bot-analytics", "/gptbot-analytics"], do: visit(conn, ua, path)

    # Grouped into a half-hour window, which is what makes the pages and flow
    # reports mean anything for a crawl.
    assert [session] = sessions(site)
    assert session.pageview_count == 3
  end

  test "two different crawlers are two sessions", %{conn: conn, site: site} do
    visit(conn, "Mozilla/5.0 (compatible; ClaudeBot/1.0)")
    visit(conn, "Mozilla/5.0 (compatible; PerplexityBot/1.0)")

    names = sessions(site) |> Enum.map(& &1.crawler_name) |> Enum.sort()
    assert names == ["ClaudeBot", "PerplexityBot"]
  end

  test "an ordinary browser is left entirely alone", %{conn: conn, site: site} do
    visit(
      conn,
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
        "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
    )

    # A human's visit is the tag's job. Recording it here as well would double
    # every pageview on this deployment's own account.
    assert sessions(site) == []
  end

  test "records nothing when self-tracking is not configured", %{conn: conn, site: site} do
    Application.put_env(:web_analytics, :self_site_key, nil)

    visit(conn, "Mozilla/5.0 (compatible; ClaudeBot/1.0)")

    assert sessions(site) == []
  end

  test "a page still renders when the account key names nothing", %{conn: conn} do
    Application.put_env(:web_analytics, :self_site_key, "acct_does_not_exist")

    conn =
      conn |> put_req_header("user-agent", "Mozilla/5.0 (compatible; ClaudeBot/1.0)") |> get("/")

    # Telemetry must never be the reason a page fails.
    assert html_response(conn, 200) =~ "SeriouslySimpleAnalytics"
  end

  test "a request with no user agent renders and records nothing", %{conn: conn, site: site} do
    assert conn |> get("/") |> html_response(200)
    Collector.flush_sync()

    assert sessions(site) == []
  end
end
