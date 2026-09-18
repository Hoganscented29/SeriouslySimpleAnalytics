defmodule WebAnalyticsWeb.PingController do
  @moduledoc """
  The one-URL event API.

      GET /api/ping?uid=ACCOUNT&type=ai&project=my-tool&event=page_view

  Built for things that are not browsers: an AI tool reporting its own usage, a
  CLI, a cron job, a shell script, a Lambda. A GET with query parameters is the
  lowest bar there is — anything that can make an HTTP request can call it, with
  no JSON body to assemble, no SDK, and no auth handshake beyond the account id
  that is public anyway.

  Extra query parameters beyond the documented ones are kept as event
  attributes, so callers can attach their own dimensions without asking for
  schema changes.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalytics.Ingest.Ping
  alias WebAnalyticsWeb.ClientIP

  # A 1x1 transparent GIF, for callers that can only embed an image.
  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  # What a ping means lives in WebAnalytics.Ingest.Ping, shared with the MCP
  # server's track_event tool. This module is only the HTTP shape around it.
  def ping(conn, params) do
    Ping.submit(params, ip: ClientIP.get(conn), headers: conn.req_headers)
    respond(conn, params)
  end

  # -- response ------------------------------------------------------------

  # Same empty answer for a real account and an unknown one, so the endpoint
  # cannot be used to test whether an account id exists.
  defp respond(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store, no-cache, must-revalidate")

    case params["format"] do
      "gif" ->
        conn |> put_resp_content_type("image/gif") |> send_resp(200, @pixel)

      "json" ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))

      _ ->
        send_resp(conn, 204, "")
    end
  end
end
