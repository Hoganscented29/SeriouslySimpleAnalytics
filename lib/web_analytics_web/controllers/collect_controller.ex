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
  alias WebAnalyticsWeb.ClientIP

  def create(conn, params) do
    received_at = DateTime.utc_now()

    case Sites.fetch_site_by_key(params["k"]) do
      nil ->
        accepted(conn)

      site ->
        ip = ClientIP.get(conn)

        Ingest.submit(site, params,
          received_at: received_at,
          ip_hash: Ingest.hash_ip(ip, site),
          ip_masked: Ingest.mask_ip(ip),
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
end
