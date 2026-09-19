defmodule WebAnalyticsWeb.MCPController do
  @moduledoc """
  The MCP server's Streamable HTTP transport, at `/mcp`.

  One POST per JSON-RPC message, answered with `application/json`. There is no
  server-to-client stream to open: every tool here finishes in one request, and
  the server keeps no session, so a GET or DELETE on the endpoint is answered
  with 405 as both protocol eras allow.

  Origins are all accepted, deliberately. The rule that servers validate
  `Origin` exists to stop DNS rebinding against servers on a private network,
  which reach things only the visitor's browser can. This one is on the public
  internet, reads no cookies, and unlocks nothing without a key the calling page
  would have to already hold — a hostile page gets exactly what curl gets.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalytics.ApiKeys
  alias WebAnalyticsWeb.ClientIP
  alias WebAnalyticsWeb.MCP.Server

  @auth_path Path.expand("../../../priv/mcp/mcp-registry-auth", __DIR__)
  @external_resource @auth_path
  @registry_auth (case File.read(@auth_path) do
                    {:ok, contents} -> String.trim(contents)
                    {:error, _} -> nil
                  end)

  def handle(conn, _params) do
    ctx = context(conn)

    case conn.body_params do
      # JSON-RPC batches existed only in 2025-03-26. Each message is handled on
      # its own and the answers are returned together, notifications omitted.
      %{"_json" => messages} when is_list(messages) and messages != [] ->
        replies =
          messages
          |> Enum.map(&Server.handle(&1, ctx))
          |> Enum.flat_map(fn
            {_status, nil} -> []
            {_status, body} -> [body]
          end)

        if replies == [], do: send_resp(conn, 202, ""), else: reply(conn, 200, replies)

      message when is_map(message) and map_size(message) > 0 ->
        case Server.handle(message, ctx) do
          {status, nil} -> send_resp(conn, status, "")
          {status, body} -> reply(conn, status, body)
        end

      _ ->
        reply(
          conn,
          400,
          Server.error(nil, -32700, "Parse error: expected a JSON-RPC message body")
        )
    end
  end

  # A person who opens the endpoint in a browser gets the page about it; a
  # client asking for a server-to-client stream gets told there is none.
  def stream(conn, _params) do
    if conn.method == "GET" and html?(conn) do
      redirect(conn, to: ~p"/analytics-mcp-server")
    else
      conn
      |> put_resp_header("allow", "POST, OPTIONS")
      |> reply(
        405,
        Server.error(nil, -32000, "Method not allowed: POST JSON-RPC messages to this endpoint")
      )
    end
  end

  def options(conn, _params), do: send_resp(conn, 204, "")

  def registry_auth(conn, _params) do
    case @registry_auth do
      nil ->
        send_resp(conn, 404, "")

      proof ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, proof)
    end
  end

  defp context(conn) do
    {auth, site} = authenticate(conn)

    %{
      base_url: conn |> url(~p"/") |> String.trim_trailing("/"),
      ip: ClientIP.get(conn),
      headers: conn.req_headers,
      auth: auth,
      site: site
    }
  end

  defp authenticate(conn) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> String.trim(token)
        ["bearer " <> token | _] -> String.trim(token)
        _ -> conn |> get_req_header("x-api-key") |> List.first()
      end

    case token do
      nil ->
        {:none, nil}

      "" ->
        {:none, nil}

      token ->
        case ApiKeys.authenticate(token) do
          {:ok, site} -> {:valid, site}
          :error -> {:invalid, nil}
        end
    end
  end

  defp html?(conn) do
    conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
