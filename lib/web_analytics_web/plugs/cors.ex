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
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", origin(conn))
    |> put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> handle_preflight()
  end

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
