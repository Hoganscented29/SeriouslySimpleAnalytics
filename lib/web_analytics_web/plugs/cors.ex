defmodule WebAnalyticsWeb.Plugs.Cors do
  @moduledoc """
  Opens the tracker script and the collect endpoint to any origin.

  Both are public by design: the script is served to every visitor of every
  tracked site, and the collector accepts anonymous beacons. Neither reads
  cookies or returns data, so a wildcard origin grants nothing that a plain
  HTTP client could not already do.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      methods: Keyword.get(opts, :methods, "POST, GET, OPTIONS"),
      headers: Keyword.get(opts, :headers, "content-type"),
      expose: Keyword.get(opts, :expose)
    }
  end

  @impl true
  def call(conn, opts) do
    conn
    |> put_resp_header("access-control-allow-origin", origin(conn))
    |> put_resp_header("access-control-allow-methods", opts.methods)
    |> put_resp_header("access-control-allow-headers", opts.headers)
    |> put_resp_header("access-control-max-age", "86400")
    |> expose(opts.expose)
    |> handle_preflight()
  end

  defp expose(conn, nil), do: conn
  defp expose(conn, headers), do: put_resp_header(conn, "access-control-expose-headers", headers)

  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] when origin != "" -> origin
      _ -> "*"
    end
  end

  defp handle_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end

  defp handle_preflight(conn), do: conn
end
