defmodule WebAnalyticsWeb.CollectController do
  @moduledoc """
  The beacon endpoint.

  Unauthenticated and deliberately uninformative: every request gets the same
  empty 204 whether the site key was real, unknown or missing. Responding
  differently would turn this into an oracle for enumerating site keys, and the
  browser has nothing useful to do with the answer either way.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalytics.Ingest
  alias WebAnalytics.Sites

  def create(conn, params) do
    received_at = DateTime.utc_now()

    case Sites.fetch_site_by_key(params["k"]) do
      nil ->
        accepted(conn)

      site ->
        ip = client_ip(conn)

        Ingest.submit(site, params,
          received_at: received_at,
          ip_hash: Ingest.hash_ip(ip, site),
          location: Ingest.locate(conn.req_headers, ip)
        )

        accepted(conn)
    end
  end

  def options(conn, _params), do: send_resp(conn, 204, "")

  defp accepted(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(204, "")
  end

  # `x-forwarded-for` is client-controlled and only trusted when the deployment
  # says it sits behind a proxy that overwrites it. The value is never stored
  # raw — it is salted and hashed — so a spoofed header costs nothing beyond a
  # slightly noisier anomaly signal.
  defp client_ip(conn) do
    if Application.get_env(:web_analytics, :trust_proxy_headers, false) do
      case get_req_header(conn, "x-forwarded-for") do
        [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
        [] -> remote_ip(conn)
      end
    else
      remote_ip(conn)
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: nil}), do: nil
  defp remote_ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
