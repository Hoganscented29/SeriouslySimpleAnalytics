defmodule WebAnalyticsWeb.PingControllerTest do
  # Not async: these lend the global ingest buffer their sandbox connection.
  use WebAnalyticsWeb.ConnCase, async: false

  import Ecto.Query
  import WebAnalytics.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias WebAnalytics.Ingest.Collector
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Event
  alias WebAnalytics.Tracking.Pageview
  alias WebAnalytics.Tracking.Session

  setup do
    Sandbox.allow(Repo, self(), Process.whereis(Collector))
    # Anything a previous test left queued would be written against rows this
    # test's transaction never had.
    Collector.reset()
    %{site: site_fixture(%{key: "acct_test"})}
  end

  defp ping(conn, query) do
    conn = get(conn, "/api/ping?" <> URI.encode_query(query))
    Collector.flush_sync()
    conn
  end

  defp session(token), do: Repo.one(from s in Session, where: s.token == ^token)

  defp event_for(token) do
    Repo.one(
      from e in Event,
        join: s in assoc(e, :session),
        where: s.token == ^token
    )
  end

  test "records an event from a single GET", %{conn: conn, site: site} do
    conn =
      ping(conn, %{
        "uid" => site.key,
        "type" => "ai",
        "project" => "newAIWhoDis",
        "event" => "run_completed",
        "sid" => "run-1"
      })

    assert response(conn, 204)

    session = session("run-1")
    assert session.project == "newAIWhoDis"
    assert session.channel == "ai"
    # A tool reporting its own usage is not a crawler, so it must not be
    # filtered out of its owner's reports.
    refute session.crawler

    event = event_for("run-1")
    assert event.type == "custom"
    assert event.name == "run_completed"
  end

  test "keeps undocumented parameters as event attributes", %{conn: conn, site: site} do
    ping(conn, %{
      "uid" => site.key,
      "project" => "my-agent",
      "event" => "tool_called",
      "sid" => "run-2",
      "tool" => "web_search",
      "latency_ms" => "420",
      "outcome" => "success"
    })

    event = event_for("run-2")

    assert event.name == "tool_called"

    assert event.data_attrs == %{
             "tool" => "web_search",
             "latency_ms" => "420",
             "outcome" => "success"
           }
  end

  test "records page_view with a path as a real pageview", %{conn: conn, site: site} do
    ping(conn, %{
      "uid" => site.key,
      "project" => "my-agent",
      "event" => "page_view",
      "path" => "/chat",
      "title" => "Chat",
      "sid" => "run-3"
    })

    pageview =
      Repo.one(
        from p in Pageview,
          join: s in assoc(p, :session),
          where: s.token == "run-3"
      )

    assert pageview.path == "/chat"
    assert pageview.title == "Chat"
    assert session("run-3").pageview_count == 1
  end

  test "records page_view without a path as an ordinary named event", %{conn: conn, site: site} do
    ping(conn, %{"uid" => site.key, "event" => "page_view", "sid" => "run-4"})

    assert event_for("run-4").name == "page_view"
    assert session("run-4").pageview_count == 0
  end

  test "groups pings that share a session id", %{conn: conn, site: site} do
    for event <- ~w(run_started tool_called run_completed) do
      ping(conn, %{"uid" => site.key, "project" => "my-agent", "event" => event, "sid" => "run-5"})
    end

    names =
      Repo.all(
        from e in Event,
          join: s in assoc(e, :session),
          where: s.token == "run-5",
          select: e.name
      )

    assert Enum.sort(names) == ~w(run_completed run_started tool_called)
    assert Repo.aggregate(from(s in Session, where: s.token == "run-5"), :count) == 1
  end

  test "groups pings from the same caller when no session id is supplied", %{
    conn: conn,
    site: site
  } do
    for _ <- 1..3 do
      ping(conn, %{"uid" => site.key, "project" => "my-agent", "event" => "install"})
    end

    # Without this a tool that never passes `sid` produces a pile of one-event
    # sessions that no report can connect, and flow is impossible.
    sessions = Repo.all(from s in Session, where: like(s.token, "auto-%"))
    assert length(sessions) == 1
    assert hd(sessions).project == "my-agent"
  end

  test "keeps different projects in different derived sessions", %{conn: conn, site: site} do
    ping(conn, %{"uid" => site.key, "project" => "agent-a", "event" => "install"})
    ping(conn, %{"uid" => site.key, "project" => "agent-b", "event" => "install"})

    assert Repo.aggregate(from(s in Session, where: like(s.token, "auto-%")), :count) == 2
  end

  describe "location" do
    test "records the city, county, state and nation the caller supplies", %{
      conn: conn,
      site: site
    } do
      ping(conn, %{
        "uid" => site.key,
        "event" => "page_view",
        "sid" => "loc-1",
        "c" => "Austin",
        "cc" => "Travis",
        "s_p" => "Texas",
        "n" => "United States"
      })

      session = session("loc-1")

      assert session.city == "Austin"
      assert session.county == "Travis"
      assert session.region == "Texas"
      assert session.country == "United States"
      assert session.country_code == "US"
      assert session.geo_source == "client"
    end

    test "accepts a nation as a name, an alias or an ISO code", %{conn: conn, site: site} do
      for {value, token} <- [{"United States", "n-1"}, {"USA", "n-2"}, {"us", "n-3"}] do
        ping(conn, %{"uid" => site.key, "event" => "x", "sid" => token, "n" => value})
        assert session(token).country_code == "US", "#{value} should resolve to US"
      end
    end

    test "keeps an unrecognised nation verbatim rather than dropping it", %{
      conn: conn,
      site: site
    } do
      ping(conn, %{"uid" => site.key, "event" => "x", "sid" => "n-4", "n" => "Freedonia"})

      session = session("n-4")
      assert session.country == "Freedonia"
      assert session.country_code == nil
    end

    test "accepts the long-form aliases", %{conn: conn, site: site} do
      ping(conn, %{
        "uid" => site.key,
        "event" => "x",
        "sid" => "loc-2",
        "city" => "Lisbon",
        "county" => "Lisboa",
        "province" => "Lisboa",
        "country" => "Portugal"
      })

      session = session("loc-2")
      assert session.city == "Lisbon"
      assert session.county == "Lisboa"
      assert session.region == "Lisboa"
      assert session.country_code == "PT"
    end

    test "records a partial location rather than discarding it", %{conn: conn, site: site} do
      ping(conn, %{"uid" => site.key, "event" => "x", "sid" => "loc-3", "n" => "Japan"})

      session = session("loc-3")
      assert session.country == "Japan"
      assert session.city == nil
      assert session.geo_source == "client"
    end

    test "a supplied location wins over anything resolved from the connection", %{
      conn: conn,
      site: site
    } do
      # The ping arrives from this test's loopback address; the caller says its
      # user is in Texas. The caller is the only one who can know.
      ping(conn, %{
        "uid" => site.key,
        "event" => "x",
        "sid" => "loc-4",
        "c" => "Austin",
        "n" => "US"
      })

      assert session("loc-4").city == "Austin"
      assert session("loc-4").geo_source == "client"
    end

    test "falls back to resolving the connection when nothing is supplied", %{
      conn: conn,
      site: site
    } do
      ping(conn, %{"uid" => site.key, "event" => "x", "sid" => "loc-5"})

      # Loopback resolves to nothing, which is the honest answer.
      assert session("loc-5").geo_source == nil
      assert session("loc-5").city == nil
    end

    test "location parameters are not also stored as event attributes", %{
      conn: conn,
      site: site
    } do
      ping(conn, %{
        "uid" => site.key,
        "event" => "x",
        "sid" => "loc-6",
        "c" => "Austin",
        "cc" => "Travis",
        "s_p" => "Texas",
        "n" => "US",
        "tool" => "search"
      })

      assert event_for("loc-6").data_attrs == %{"tool" => "search"}
    end
  end

  describe "flow" do
    test "sequences pageviews and links them without the caller tracking anything", %{
      conn: conn,
      site: site
    } do
      for path <- ~w(/start /chat /result) do
        ping(conn, %{
          "uid" => site.key,
          "project" => "my-agent",
          "event" => "page_view",
          "path" => path,
          "sid" => "flow-1"
        })
      end

      pageviews =
        Repo.all(
          from p in Pageview,
            join: s in assoc(p, :session),
            where: s.token == "flow-1",
            order_by: p.seq,
            select: %{seq: p.seq, path: p.path, from: p.from_path, to: p.to_path}
        )

      assert [
               %{seq: 1, path: "/start", from: nil, to: "/chat"},
               %{seq: 2, path: "/chat", from: "/start", to: "/result"},
               %{seq: 3, path: "/result", from: "/chat", to: nil}
             ] = pageviews
    end

    test "attaches an event with no page to whatever page the session is on", %{
      conn: conn,
      site: site
    } do
      ping(conn, %{
        "uid" => site.key,
        "event" => "page_view",
        "path" => "/chat",
        "sid" => "flow-2"
      })

      ping(conn, %{"uid" => site.key, "event" => "tool_called", "sid" => "flow-2"})

      event =
        Repo.one(
          from e in Event,
            join: s in assoc(e, :session),
            where: s.token == "flow-2" and e.name == "tool_called"
        )

      assert event.path == "/chat"
    end

    test "builds a flow graph from pings", %{conn: conn, site: site} do
      for {sid, paths} <- [
            {"r1", ~w(/start /chat /result)},
            {"r2", ~w(/start /chat)},
            {"r3", ~w(/start /help)}
          ],
          path <- paths do
        ping(conn, %{
          "uid" => site.key,
          "project" => "my-agent",
          "event" => "page_view",
          "path" => path,
          "sid" => sid
        })
      end

      filters =
        WebAnalytics.Analytics.filters(site.id, %{range: "30d", project: "my-agent"})

      flow = WebAnalytics.Analytics.flow(filters)

      assert %{from: "/start", to: "/chat", count: 2} = Enum.find(flow, &(&1.to == "/chat"))
      assert %{from: "/chat", to: "/result", count: 1} = Enum.find(flow, &(&1.to == "/result"))
      assert %{from: "/start", to: "/help", count: 1} = Enum.find(flow, &(&1.to == "/help"))
    end
  end

  test "marks a ping as automated only when it says so", %{conn: conn, site: site} do
    ping(conn, %{"uid" => site.key, "event" => "fetch", "sid" => "crawl-1", "bot" => "agent"})

    session = session("crawl-1")
    assert session.crawler
    assert session.client_signal == "agent"
  end

  test "accepts the documented parameter aliases", %{conn: conn, site: site} do
    ping(conn, %{"id" => site.key, "name" => "aliased", "app" => "alt", "session" => "run-6"})

    assert event_for("run-6").name == "aliased"
    assert session("run-6").project == "alt"
  end

  test "defaults the event name and channel", %{conn: conn, site: site} do
    ping(conn, %{"uid" => site.key, "sid" => "run-7"})

    assert event_for("run-7").name == "ping"
    assert session("run-7").channel == "ai"
  end

  test "serves a pixel or JSON when asked", %{conn: conn, site: site} do
    gif = ping(conn, %{"uid" => site.key, "event" => "x", "format" => "gif"})
    assert response(gif, 200)
    assert response_content_type(gif, :gif) =~ "image/gif"

    json = ping(build_conn(), %{"uid" => site.key, "event" => "x", "format" => "json"})
    assert response(json, 200) =~ "ok"
  end

  test "answers an unknown account exactly like a real one", %{conn: conn, site: site} do
    unknown = ping(conn, %{"uid" => "no-such-account", "event" => "x", "sid" => "ghost"})
    known = ping(build_conn(), %{"uid" => site.key, "event" => "x", "sid" => "real"})

    assert response(unknown, 204) == response(known, 204)
    assert session("ghost") == nil
  end

  test "shrugs off a ping with no account id", %{conn: conn} do
    assert response(ping(conn, %{"event" => "x"}), 204)
  end

  test "accepts POST as well as GET", %{conn: conn, site: site} do
    conn =
      post(
        conn,
        "/api/ping?" <>
          URI.encode_query(%{"uid" => site.key, "event" => "posted", "sid" => "run-8"})
      )

    Collector.flush_sync()

    assert response(conn, 204)
    assert event_for("run-8").name == "posted"
  end

  test "is reachable cross-origin", %{conn: conn, site: site} do
    conn =
      conn
      |> put_req_header("origin", "https://my-agent.example")
      |> get("/api/ping?uid=#{site.key}&event=x")

    Collector.flush_sync()
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://my-agent.example"]
  end
end
