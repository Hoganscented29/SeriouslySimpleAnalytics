defmodule WebAnalyticsWeb.TrackerController do
  @moduledoc """
  Serves the tracker script.

  The file is embedded at compile time and marked as an external resource, so
  editing it recompiles this module and dev reloading picks it up immediately.
  """
  use WebAnalyticsWeb, :controller

  # Deliberately not under priv/static: this is a source file compiled into the
  # module, not an asset for Plug.Static to serve. Keeping it out of the static
  # root also keeps it out of `mix phx.digest`, so its URL never gains a hash —
  # which matters when the URL is pasted into other people's HTML.
  @tracker_path [__DIR__, "..", "..", "..", "priv", "tracker", "wa.js"]
                |> Path.join()
                |> Path.expand()

  @external_resource @tracker_path

  @tracker File.read!(@tracker_path)
  @etag :md5 |> :crypto.hash(@tracker) |> Base.encode16(case: :lower)

  # The landing page's live panel. Served the same way and for the same reason:
  # it is a source file, not an asset, and it reads the tracker's own state.
  @proof_path [__DIR__, "..", "..", "..", "priv", "tracker", "live-proof.js"]
              |> Path.join()
              |> Path.expand()

  @external_resource @proof_path

  @proof File.read!(@proof_path)
  @proof_etag :md5 |> :crypto.hash(@proof) |> Base.encode16(case: :lower)

  # Short enough that a fix reaches visitors within the hour, long enough that
  # repeat visitors are not re-downloading it on every pageview.
  @max_age 3600

  def script(conn, _params) do
    conn = put_resp_header(conn, "etag", ~s("#{@etag}"))

    if stale?(conn) do
      conn
      |> put_resp_content_type("application/javascript")
      |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
      |> send_resp(200, @tracker)
    else
      send_resp(conn, 304, "")
    end
  end

  def proof(conn, _params) do
    conn = put_resp_header(conn, "etag", ~s("#{@proof_etag}"))

    if stale?(conn) do
      conn
      |> put_resp_content_type("application/javascript")
      |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
      |> send_resp(200, @proof)
    else
      send_resp(conn, 304, "")
    end
  end

  defp stale?(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.all?(fn value -> String.trim(value, ~s(")) != @etag end)
  end
end
