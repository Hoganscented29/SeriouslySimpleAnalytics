defmodule WebAnalyticsWeb.CollectControllerTest do
  # Not async: the ingest buffer is a single global process, and these tests
  # lend it their sandbox connection.
  use WebAnalyticsWeb.ConnCase, async: false

  import Ecto.Query
  import WebAnalytics.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias WebAnalytics.Ingest.Collector
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Session

  setup do
    Sandbox.allow(Repo, self(), Process.whereis(Collector))
    # Anything a previous test left queued would be written against rows this
    # test's transaction never had.
    Collector.reset()
    %{site: site_fixture()}
  end

  defp post_beacon(conn, body) do
    conn
    |> put_req_header("content-type", "text/plain;charset=UTF-8")
    |> post(~p"/api/v1/collect", Jason.encode!(body))
  end

  test "accepts a beacon posted as text/plain and writes it", %{conn: conn, site: site} do
    body =
      payload(site, [init_event(), pageview_event(1, "/landing"), tick_event(1)],
        token: "beacon-1"
      )

    conn = post_beacon(conn, body)

    assert response(conn, 204)
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    Collector.flush_sync()

    session = Repo.one!(from s in Session, where: s.token == "beacon-1")
    assert session.entry_path == "/landing"
    assert session.tick_count == 1
    assert session.browser == "Chrome"
  end

  test "classifies a crawler beacon on the way in", %{conn: conn, site: site} do
    body =
      payload(
        site,
        [
          init_event(%{
            "ua" => "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)",
            "hb" => 10_000
          }),
          pageview_event(1, "/")
        ],
        token: "beacon-bot"
      )

    assert response(post_beacon(conn, body), 204)
    Collector.flush_sync()

    session = Repo.one!(from s in Session, where: s.token == "beacon-bot")
    assert session.crawler
    assert session.crawler_kind == "ai"
    assert session.crawler_name == "ClaudeBot"
    assert session.heartbeat_ms == 10_000
  end

  test "trusts a client that reports itself as automated", %{conn: conn, site: site} do
    body =
      payload(site, [init_event(%{"bot" => "webdriver"}), pageview_event(1, "/")],
        token: "beacon-wd"
      )

    assert response(post_beacon(conn, body), 204)
    Collector.flush_sync()

    session = Repo.one!(from s in Session, where: s.token == "beacon-wd")
    assert session.crawler
    assert session.crawler_kind == "automation"
    assert session.client_signal == "webdriver"
  end

  describe "behind a reverse proxy" do
    setup do
      original = Application.get_env(:web_analytics, :trust_proxy_headers)
      on_exit(fn -> Application.put_env(:web_analytics, :trust_proxy_headers, original) end)
      :ok
    end

    test "records the forwarded address when the deployment trusts the proxy",
         %{conn: conn, site: site} do
      Application.put_env(:web_analytics, :trust_proxy_headers, true)

      conn
      |> put_req_header("x-forwarded-for", "203.0.113.42")
      |> post_beacon(payload(site, [init_event(), pageview_event(1, "/")], token: "fwd-on"))
      |> response(204)

      Collector.flush_sync()

      session = Repo.one!(from s in Session, where: s.token == "fwd-on")

      # Without this, every visitor behind the proxy is the loopback address:
      # one origin for the whole site and no city on any session.
      assert session.ip_masked == "203.•••.•••.42"
    end

    test "ignores the header when the deployment does not", %{conn: conn, site: site} do
      Application.put_env(:web_analytics, :trust_proxy_headers, false)

      conn
      |> put_req_header("x-forwarded-for", "203.0.113.42")
      |> post_beacon(payload(site, [init_event(), pageview_event(1, "/")], token: "fwd-off"))
      |> response(204)

      Collector.flush_sync()

      session = Repo.one!(from s in Session, where: s.token == "fwd-off")

      # A deployment reachable directly must not believe a header the client
      # sets, so the socket address wins.
      refute session.ip_masked == "203.•••.•••.42"
    end

    test "takes the first entry, which the proxy must therefore overwrite",
         %{conn: conn, site: site} do
      Application.put_env(:web_analytics, :trust_proxy_headers, true)

      conn
      |> put_req_header("x-forwarded-for", "203.0.113.42, 10.0.0.1")
      |> post_beacon(payload(site, [init_event(), pageview_event(1, "/")], token: "fwd-chain"))
      |> response(204)

      Collector.flush_sync()

      session = Repo.one!(from s in Session, where: s.token == "fwd-chain")

      # This is why deploy/setup.sh sets the header to $remote_addr rather than
      # $proxy_add_x_forwarded_for: appending would put the client's own claim
      # first, and the client's claim would win.
      assert session.ip_masked == "203.•••.•••.42"
    end
  end

  test "answers unknown site keys exactly like known ones", %{conn: conn, site: site} do
    unknown = post_beacon(conn, %{"k" => "no-such-site", "s" => "x", "e" => []})
    known = post_beacon(build_conn(), payload(site, [], token: "beacon-2"))

    # Identical responses, so the endpoint cannot be used to enumerate site keys.
    assert response(unknown, 204) == response(known, 204)
    assert Repo.aggregate(from(s in Session, where: s.token == "x"), :count) == 0
  end

  test "shrugs off malformed and hostile bodies", %{conn: conn} do
    for body <- ["not json at all", "[]", "null", "", "{\"k\":123}"] do
      response =
        conn
        |> put_req_header("content-type", "text/plain;charset=UTF-8")
        |> post(~p"/api/v1/collect", body)

      assert response(response, 204)
    end
  end

  test "still accepts a normal application/json post", %{conn: conn, site: site} do
    conn =
      post(
        conn,
        ~p"/api/v1/collect",
        payload(site, [pageview_event(1, "/json")], token: "beacon-json")
      )

    assert response(conn, 204)
    Collector.flush_sync()
    assert Repo.exists?(from s in Session, where: s.token == "beacon-json")
  end

  test "returns permissive CORS headers so cross-origin beacons work", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://tracked-site.example")
      |> put_req_header("content-type", "text/plain")
      |> post(~p"/api/v1/collect", "{}")

    assert get_resp_header(conn, "access-control-allow-origin") == [
             "https://tracked-site.example"
           ]

    assert get_resp_header(conn, "access-control-allow-methods") == ["POST, GET, OPTIONS"]
  end

  test "answers a preflight without reaching the controller", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://tracked-site.example")
      |> options(~p"/api/v1/collect")

    assert response(conn, 204)
    assert get_resp_header(conn, "access-control-allow-headers") == ["content-type"]
  end
end
