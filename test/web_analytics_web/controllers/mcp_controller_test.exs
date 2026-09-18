defmodule WebAnalyticsWeb.MCPControllerTest do
  # Not async: tracking lends the global ingest buffer this test's connection,
  # and account creation shares the global rate limiter.
  use WebAnalyticsWeb.ConnCase, async: false

  import Ecto.Query
  import WebAnalytics.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias WebAnalytics.ApiKeys
  alias WebAnalytics.Ingest
  alias WebAnalytics.Ingest.Collector
  alias WebAnalytics.RateLimiter
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Session
  alias WebAnalyticsWeb.MCP.Server
  alias WebAnalyticsWeb.MCP.Tools

  @modern "2026-07-28"

  setup do
    Sandbox.allow(Repo, self(), Process.whereis(Collector))
    Collector.reset()
    RateLimiter.reset()

    site = site_fixture(%{key: "acct_mcp", name: "MCP Site"})
    {:ok, token, _key} = ApiKeys.create(site, "test")
    %{site: site, token: token}
  end

  defp rpc(conn, method, params \\ %{}, opts \\ []) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(~p"/mcp", Jason.encode!(Keyword.get(opts, :body, body)))
  end

  defp modern(params \\ %{}) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end

  defp call_tool(conn, name, arguments, opts \\ []) do
    conn
    |> rpc("tools/call", %{"name" => name, "arguments" => arguments}, opts)
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp bearer(token), do: [headers: [{"authorization", "Bearer " <> token}]]

  describe "the handshake era" do
    test "initialize negotiates the client's version and describes the server", %{conn: conn} do
      result =
        conn
        |> rpc("initialize", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        })
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"]["name"] == "seriouslysimpleanalytics"
      assert result["serverInfo"]["version"] == Server.version()
      assert Map.keys(result["capabilities"]) |> Enum.sort() == ["prompts", "resources", "tools"]
      assert result["instructions"] =~ "API key"
      # resultType belongs to the stateless era only.
      refute Map.has_key?(result, "resultType")
    end

    test "an unknown version is answered with the newest handshake version", %{conn: conn} do
      result =
        conn
        |> rpc("initialize", %{"protocolVersion" => "1999-01-01", "capabilities" => %{}})
        |> json_response(200)

      assert result["result"]["protocolVersion"] == "2025-11-25"
    end

    test "notifications are accepted with an empty 202", %{conn: conn} do
      conn =
        rpc(conn, "notifications/initialized", %{},
          body: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
        )

      assert response(conn, 202) == ""
    end

    test "ping answers, and an unknown method is a JSON-RPC error", %{conn: conn} do
      assert conn |> rpc("ping") |> json_response(200) |> Map.fetch!("result") == %{}

      error = build_conn() |> rpc("nope/nope") |> json_response(200)
      assert error["error"]["code"] == -32601
    end

    test "a batch gets one answer per request and none per notification", %{conn: conn} do
      replies =
        conn
        |> rpc("ignored", %{},
          body: [
            %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
            %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
            %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
          ]
        )
        |> json_response(200)

      assert Enum.map(replies, & &1["id"]) == [1, 2]
    end

    test "a garbage protocol header is refused", %{conn: conn} do
      conn = rpc(conn, "tools/list", %{}, headers: [{"mcp-protocol-version", "banana"}])
      assert json_response(conn, 400)["error"]["code"] == -32600
    end
  end

  describe "the stateless era (2026-07-28)" do
    test "server/discover lists versions, capabilities and identity", %{conn: conn} do
      result =
        conn
        |> rpc("server/discover", modern(),
          headers: [{"mcp-protocol-version", @modern}, {"mcp-method", "server/discover"}]
        )
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["resultType"] == "complete"
      assert @modern in result["supportedVersions"]
      assert "2025-06-18" in result["supportedVersions"]
      assert result["cacheScope"] == "public"
      assert result["ttlMs"] > 0

      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] ==
               "seriouslysimpleanalytics"
    end

    test "lists are cacheable and complete", %{conn: conn} do
      result = conn |> rpc("tools/list", modern()) |> json_response(200) |> Map.fetch!("result")

      assert result["resultType"] == "complete"
      assert result["cacheScope"] == "public"
      assert length(result["tools"]) == length(Tools.definitions())
    end

    test "an unsupported version is refused with the versions that are", %{conn: conn} do
      params =
        put_in(modern(), ["_meta", "io.modelcontextprotocol/protocolVersion"], "2099-01-01")

      body = conn |> rpc("tools/list", params) |> json_response(400)

      assert body["error"]["code"] == -32022
      assert body["error"]["data"]["requested"] == "2099-01-01"
      assert @modern in body["error"]["data"]["supported"]
    end

    test "headers that disagree with the body are refused", %{conn: conn} do
      body =
        conn
        |> rpc("tools/list", modern(), headers: [{"mcp-method", "tools/call"}])
        |> json_response(400)

      assert body["error"]["code"] == -32020

      body =
        build_conn()
        |> rpc("tools/list", modern(), headers: [{"mcp-protocol-version", "2025-06-18"}])
        |> json_response(400)

      assert body["error"]["code"] == -32020
    end

    test "an unknown method is a 404, and initialize no longer exists", %{conn: conn} do
      assert conn
             |> rpc("initialize", modern())
             |> json_response(404)
             |> get_in(["error", "code"]) ==
               -32601
    end

    test "tool calls work the same", %{conn: conn, token: token} do
      result =
        conn
        |> rpc(
          "tools/call",
          modern(%{"name" => "get_account", "arguments" => %{}}),
          bearer(token)
        )
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["resultType"] == "complete"
      assert result["structuredContent"]["account_id"] == "acct_mcp"
    end
  end

  describe "tools" do
    test "every tool has a name, title, description, schema and annotations" do
      tools = Tools.definitions()
      names = Enum.map(tools, & &1["name"])

      assert names == Enum.uniq(names)

      for tool <- tools do
        assert tool["name"] =~ ~r/^[a-z_]+$/
        assert is_binary(tool["title"])
        assert String.length(tool["description"]) > 60
        assert tool["inputSchema"]["type"] == "object"
        assert is_boolean(tool["annotations"]["readOnlyHint"])
      end
    end

    test "track_event records through the same path as the event API", %{conn: conn, site: site} do
      result =
        call_tool(conn, "track_event", %{
          "account_id" => site.key,
          "event" => "pr_merged",
          "project" => "marketplace",
          "session_id" => "mcp-run-1",
          "user" => "seller_9",
          "user_identifiers" => %{"wallet" => "wal_3f"},
          "attributes" => %{"sats" => 1500, "repo" => "x", "name" => "would rename the tool"},
          "country" => "US"
        })

      Collector.flush_sync()

      refute result["isError"]
      assert result["structuredContent"]["ignored_attributes"] == ["name"]

      session = Repo.one(from s in Session, where: s.token == "mcp-run-1", preload: :events)
      assert session.project == "marketplace"
      assert session.user_id == "seller_9"
      assert session.user_traits == %{"wallet" => "wal_3f"}
      assert session.country_code == "US"
      assert [event] = session.events
      assert event.name == "pr_merged"
      assert event.data_attrs == %{"sats" => "1500", "repo" => "x", "user_wallet" => "wal_3f"}
    end

    test "track_event does not reveal whether an account exists", %{conn: conn} do
      result = call_tool(conn, "track_event", %{"account_id" => "acct_nope", "event" => "x"})

      refute result["isError"]
      assert result["structuredContent"]["accepted"] == true
    end

    test "reading needs a key, and says how to get one", %{conn: conn} do
      result = call_tool(conn, "get_analytics_overview", %{})

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "getting-started"

      result =
        call_tool(build_conn(), "get_analytics_overview", %{}, bearer("ssa_not-a-real-key"))

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "not valid"
    end

    test "a key reads its own account and nobody else's", %{conn: conn, site: site, token: token} do
      other = site_fixture(%{key: "acct_other"})

      for {s, path} <- [{site, "/mine"}, {other, "/theirs"}] do
        {:ok, _} =
          Ingest.submit_sync(s, payload(s, [init_event(), pageview_event(1, path)]),
            received_at: DateTime.utc_now()
          )
      end

      result = call_tool(conn, "get_top_pages", %{"range" => "24h"}, bearer(token))

      refute result["isError"]
      paths = Enum.map(result["structuredContent"]["pages"], & &1["name"])
      assert "/mine" in paths
      refute "/theirs" in paths
    end

    test "every reading tool answers with JSON on an account with data", %{
      conn: conn,
      site: site,
      token: token
    } do
      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [
            init_event(),
            pageview_event(1, "/", %{"title" => "Home"}),
            tick_event(1, %{"d" => 30_000, "am" => 25_000, "sp" => 75}),
            click_event(%{"id" => "cta"}),
            pageview_event(2, "/pricing", %{"title" => "Pricing", "fp" => "/", "ft" => "Home"}),
            %{
              "n" => "event",
              "t" => 1_000_000,
              "name" => "purchase",
              "data" => %{"usd" => "19.99"}
            }
          ]),
          received_at: DateTime.utc_now(),
          user_id: "acct_42"
        )

      reading =
        Enum.reject(
          Tools.definitions(),
          &(&1["name"] in ~w(create_analytics_account track_event))
        )

      for %{"name" => name} <- reading do
        args =
          case name do
            "get_user_activity" -> %{"user" => "acct_42", "range" => "all"}
            "get_events" -> %{"event" => "purchase"}
            "get_metrics" -> %{"key" => "usd"}
            _ -> %{}
          end

        result = call_tool(build_conn(), name, args, bearer(token))
        refute result["isError"], "#{name} failed: #{inspect(result)}"
        assert is_map(result["structuredContent"]), name
      end

      activity =
        call_tool(
          conn,
          "get_user_activity",
          %{"user" => "acct_42", "range" => "all"},
          bearer(token)
        )

      assert [%{"key" => "usd", "sum" => 19.99}] = activity["structuredContent"]["metrics"]
    end

    test "create_analytics_account returns an account ID and a working API key", %{conn: conn} do
      result = call_tool(conn, "create_analytics_account", %{"project" => "new-agent"})

      refute result["isError"]
      data = result["structuredContent"]
      assert data["uid"] =~ ~r/^acct_/
      assert data["claim_url"] =~ "/users/log-in/"
      assert {:ok, site} = ApiKeys.authenticate(data["api_key"])
      assert site.key == data["uid"]
    end

    test "get_integration_guide fills in the account", %{conn: conn} do
      result =
        call_tool(conn, "get_integration_guide", %{
          "account_id" => "acct_mcp",
          "kind" => "website"
        })

      assert result["structuredContent"]["website_script_tag"] =~ ~s(data-site="acct_mcp")
      refute Map.has_key?(result["structuredContent"], "event_api_url")
    end

    test "an unknown tool is invalid params", %{conn: conn} do
      body =
        conn |> rpc("tools/call", %{"name" => "nope", "arguments" => %{}}) |> json_response(200)

      assert body["error"]["code"] == -32602
    end
  end

  describe "resources and prompts" do
    test "llms.txt is readable as a resource", %{conn: conn} do
      [resource] =
        conn |> rpc("resources/list") |> json_response(200) |> get_in(["result", "resources"])

      [contents] =
        build_conn()
        |> rpc("resources/read", %{"uri" => resource["uri"]})
        |> json_response(200)
        |> get_in(["result", "contents"])

      assert contents["text"] =~ "## The whole API"
    end

    test "prompts render", %{conn: conn} do
      names =
        conn
        |> rpc("prompts/list")
        |> json_response(200)
        |> get_in(["result", "prompts"])
        |> Enum.map(& &1["name"])

      assert names == ["add_analytics", "analytics_report"]

      [message] =
        build_conn()
        |> rpc("prompts/get", %{
          "name" => "add_analytics",
          "arguments" => %{"account_id" => "acct_mcp"}
        })
        |> json_response(200)
        |> get_in(["result", "messages"])

      assert message["content"]["text"] =~ "acct_mcp"
    end
  end

  describe "HTTP" do
    test "a browser opening the endpoint is sent to the page about it", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/html") |> get(~p"/mcp")
      assert redirected_to(conn) == ~p"/analytics-mcp-server"
    end

    test "there is no stream to open and no session to end", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/event-stream") |> get(~p"/mcp")
      assert conn.status == 405

      assert build_conn() |> delete(~p"/mcp") |> Map.fetch!(:status) == 405
    end

    test "is reachable cross-origin with MCP headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://inspector.example")
        |> options(~p"/mcp")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://inspector.example"]
      [allowed] = get_resp_header(conn, "access-control-allow-headers")
      assert allowed =~ "authorization"
      assert allowed =~ "mcp-protocol-version"
    end

    test "an empty body is a parse error", %{conn: conn} do
      conn = conn |> put_req_header("content-type", "application/json") |> post(~p"/mcp", "")
      assert json_response(conn, 400)["error"]["code"] == -32700
    end
  end
end
