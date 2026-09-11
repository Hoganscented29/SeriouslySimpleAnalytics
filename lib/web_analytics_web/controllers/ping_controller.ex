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

  alias WebAnalytics.Geo
  alias WebAnalytics.Geo.Countries
  alias WebAnalytics.Ingest
  alias WebAnalytics.Sites

  # Names that mean "someone looked at something", which are recorded as real
  # pageviews so they land in the pages and flow reports rather than only in the
  # event list.
  @pageview_events ~w(page_view pageview pv view screen screen_view)

  @reserved ~w(uid id site u type channel project app event name sid session path page
               title ref referrer visitor v format bot agent ai tz timezone
               email contact
               c city cc county s_p state province region n nation country)

  # A 1x1 transparent GIF, for callers that can only embed an image.
  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  # How long consecutive pings from the same caller are treated as one session
  # when no session id is supplied. Thirty minutes is the convention analytics
  # has used for inactivity windows for decades.
  @session_window_seconds 1_800

  def ping(conn, params) do
    received_at = DateTime.utc_now()

    case Sites.fetch_site_by_key(account_id(params)) do
      nil ->
        respond(conn, params)

      site ->
        ip = client_ip(conn)
        ip_hash = Ingest.hash_ip(ip, site)

        Ingest.submit(site, payload(params, received_at, session_token(params, site, ip_hash)),
          received_at: received_at,
          ip_hash: ip_hash,
          location: location(params, conn, ip),
          project: param(params, ~w(project app)),
          channel: param(params, ~w(type channel)) || "ai",
          agent_name: param(params, ~w(name agent ai)),
          contact_email: param(params, ~w(email contact))
        )

        respond(conn, params)
    end
  end

  # -- location ------------------------------------------------------------

  @doc false
  # A caller's own location parameters always win over anything this server
  # could work out.
  #
  # That is not a preference, it is the only correct answer for this endpoint:
  # a ping arrives from wherever the tool runs — a laptop, a container, a
  # serverless region three countries away — so its source address says where
  # the *software* is, not where its user is. Resolving the address would
  # produce a confident, wrong answer. Falling back to it at all is only
  # reasonable for the browser tracker, where the connection really is the
  # visitor's.
  defp location(params, conn, ip) do
    supplied = %{
      city: param(params, ~w(c city)),
      county: param(params, ~w(cc county)),
      region: param(params, ~w(s_p state province region)),
      country: param(params, ~w(n nation country))
    }

    if Enum.any?(Map.values(supplied), &is_binary/1) do
      code = Countries.code_for(supplied.country)

      %{
        Geo.empty()
        | city: supplied.city,
          county: supplied.county,
          region: supplied.region,
          country: Countries.name(code) || supplied.country,
          country_code: code,
          source: "client"
      }
    else
      Ingest.locate(conn.req_headers, ip)
    end
  end

  # -- payload -------------------------------------------------------------

  defp payload(params, received_at, token) do
    # `name` is deliberately NOT an alias for `event` any more. It now identifies
    # the AI tool doing the reporting, and one parameter cannot mean two things:
    # a caller sending name=Claude would otherwise have silently renamed its
    # event instead of identifying itself.
    event_name = param(params, ~w(event)) || "ping"
    path = param(params, ~w(path page))
    now = DateTime.to_unix(received_at, :millisecond)

    %{
      "k" => account_id(params),
      "s" => token,
      "v" => param(params, ~w(visitor v)),
      "t" => now,
      "e" => [init_event(params, now) | [body_event(event_name, path, params, now)]]
    }
  end

  # The caller's user agent is deliberately *not* forwarded for classification.
  # A ping is a tool reporting its own usage, and most such callers are a script
  # or an HTTP library — classifying them by user agent would file every one as
  # a crawler and quietly filter the owner's own telemetry out of their own
  # reports. Only an explicit `bot=` marks a ping as automated.
  defp init_event(params, now) do
    %{
      "n" => "init",
      "t" => now,
      "ref" => param(params, ~w(ref referrer)),
      "bot" => param(params, ~w(bot agent)),
      "tz" => param(params, ~w(tz timezone)),
      "hb" => 10_000
    }
  end

  # `event=page_view` with a path is a real pageview; everything else is a
  # named event. That mapping is documented, so a caller gets pages and flow
  # reporting by naming the event the obvious thing rather than by learning a
  # second parameter.
  defp body_event(event_name, path, params, now) do
    if String.downcase(event_name) in @pageview_events and path do
      # No `seq` and no `from`: the server continues the session's sequence and
      # links this page to the one before it, which is what builds the flow
      # graph without the caller having to track any of it.
      %{
        "n" => "pv",
        "t" => now,
        "path" => path,
        "title" => param(params, ~w(title)),
        "ref" => param(params, ~w(ref referrer))
      }
    else
      # No `pv` either: the event attaches to whatever page the session is on.
      %{
        "n" => "event",
        "t" => now,
        "name" => event_name,
        "text" => param(params, ~w(title)),
        "data" => extras(params)
      }
    end
  end

  # Anything the caller invented, kept as attributes.
  defp extras(params) do
    params
    |> Enum.reject(fn {key, _value} -> key in @reserved end)
    |> Enum.take(20)
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  @doc false
  # A session id from the caller is authoritative. Without one, pings are grouped
  # by who and what they came from within a rolling half-hour, so that a tool
  # that never passes `sid` still produces sessions — and therefore page flow —
  # rather than a pile of one-event sessions that no report can connect.
  #
  # The window tumbles rather than sliding, so a long run can straddle a boundary
  # and split in two. That is the price of deriving a session without a lookup on
  # every ping; `sid` is there for callers that need exactness.
  defp session_token(params, site, ip_hash) do
    case param(params, ~w(sid session)) do
      nil -> derived_token(params, site, ip_hash)
      explicit -> explicit
    end
  end

  defp derived_token(params, site, ip_hash) do
    project = param(params, ~w(project app)) || "-"
    who = param(params, ~w(visitor v)) || ip_hash || "anon"
    window = div(System.system_time(:second), @session_window_seconds)

    digest =
      :sha256
      |> :crypto.hash([site.key, "|", project, "|", who, "|", Integer.to_string(window)])
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 22)

    "auto-" <> digest
  end

  defp account_id(params), do: param(params, ~w(uid id site u))

  defp param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end
    end)
  end

  # -- response ------------------------------------------------------------

  # Same empty answer for a real account and an unknown one, so the endpoint
  # cannot be used to test whether an account id exists.
  defp respond(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store, no-cache, must-revalidate")

    case param(params, ~w(format)) do
      "gif" ->
        conn |> put_resp_content_type("image/gif") |> send_resp(200, @pixel)

      "json" ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))

      _ ->
        send_resp(conn, 204, "")
    end
  end

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
