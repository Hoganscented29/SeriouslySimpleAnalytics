defmodule WebAnalytics.Ingest.Ping do
  @moduledoc """
  Turns the one-URL event API's parameters into an ingest batch.

  Shared by the HTTP endpoint (`GET /api/ping`) and the MCP server's
  `track_event` tool, so an event means exactly the same thing whichever way it
  arrived: the same aliases, the same reserved names, the same automatic
  sessions. Two copies of these rules would drift, and an agent switching from
  one to the other would see its reports change shape for no visible reason.
  """

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
               email contact user user_id userid
               c city cc county s_p state province region n nation country)

  # How long consecutive pings from the same caller are treated as one session
  # when no session id is supplied. Thirty minutes is the convention analytics
  # has used for inactivity windows for decades.
  @session_window_seconds 1_800

  @doc "Parameter names with a fixed meaning, which are never kept as attributes."
  def reserved, do: @reserved

  @doc """
  Records one ping.

  `params` uses the API's own names — string keys, exactly as they would arrive
  in a query string or JSON body. Options: `:ip` (the caller's address, used
  only to hash and mask), `:headers` (for the location fallback) and
  `:received_at`.

  Returns `{:ok, site}`, or `:unknown_account`. The HTTP endpoint deliberately
  answers both the same way; the distinction is for callers that already prove
  they own the account.
  """
  def submit(params, opts \\ []) when is_map(params) do
    received_at = Keyword.get(opts, :received_at, DateTime.utc_now())
    ip = Keyword.get(opts, :ip)
    headers = Keyword.get(opts, :headers, [])

    case Sites.fetch_site_by_key(account_id(params)) do
      nil ->
        :unknown_account

      site ->
        ip_hash = Ingest.hash_ip(ip, site)

        Ingest.submit(site, payload(params, received_at, session_token(params, site, ip_hash)),
          received_at: received_at,
          user_id: user_id(params),
          user_traits: user_traits(params),
          ip_hash: ip_hash,
          ip_masked: Ingest.mask_ip(ip),
          location: location(params, headers, ip),
          project: param(params, ~w(project app)),
          channel: param(params, ~w(type channel)) || "ai",
          agent_name: param(params, ~w(name agent ai)),
          contact_email: param(params, ~w(email contact))
        )

        {:ok, site}
    end
  end

  # -- user ----------------------------------------------------------------

  # The caller's own ID for who this ping is about: an account, a customer, a
  # mailbox. Accepted as a number as well as a string, because a JSON body
  # carries ids as numbers far more often than not, and param/2 — built for
  # query strings — would drop `"user": 42` without a word.
  #
  # `visitor` is the older name for the same idea and still counts, so a tool
  # already sending it shows up by user without changing anything.
  defp user_id(params) do
    Enum.find_value(~w(user user_id userid visitor), fn key ->
      case Map.get(params, key) do
        value when is_integer(value) -> Integer.to_string(value)
        value when is_binary(value) -> blank_to_nil(value)
        _ -> nil
      end
    end)
  end

  # Every other identifier, by prefix: user_domain, user_address, user_plan.
  # One convention rather than a fixed list, because what identifies a user is
  # the caller's business — an email provider has an account, a domain and an
  # address; a marketplace has a seller and a wallet.
  #
  # They stay on the event as ordinary attributes too. This copy is what lets
  # the dashboard show them beside the user without reading every event.
  defp user_traits(params) do
    params
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, "user_") and key not in @reserved and
        (is_binary(value) or is_number(value) or is_boolean(value))
    end)
    |> Map.new(fn {key, value} ->
      {String.replace_prefix(key, "user_", ""), to_string(value)}
    end)
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # -- location ------------------------------------------------------------

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
  defp location(params, headers, ip) do
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
      Ingest.locate(headers, ip)
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
      # A user id is the best visitor identity a ping can have: it is what makes
      # "visitors" count people rather than sessions for a tool that says who
      # it is acting for.
      "v" => param(params, ~w(visitor v)) || user_id(params),
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
    |> Enum.reject(fn {key, value} -> key in @reserved or is_nil(value) end)
    |> Enum.take(20)
    |> Map.new(fn {key, value} -> {to_string(key), attribute_value(value)} end)
  end

  # A query string only ever carries strings, but a JSON body carries whatever
  # the caller put in it. to_string/1 has no clause for a map or a list, so
  # "meta": {"repo": "x"} raised — and the whole ping was lost with a 500, not
  # just the field that could not be stored. An agent posting structured
  # context would have been silently dropping every event it sent.
  #
  # Nested values are kept as their JSON rather than thrown away, capped so one
  # large blob cannot bloat a row. They never become metrics — a key is a
  # metric only when its values are plain numbers — which is correct: there is
  # nothing to sum in an object.
  defp attribute_value(value) when is_binary(value), do: value
  defp attribute_value(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp attribute_value(value) when is_map(value) or is_list(value) do
    value |> Jason.encode!() |> String.slice(0, 1_000)
  end

  defp attribute_value(value), do: inspect(value)

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

  # A user id comes first. A backend reporting for many users sends every ping
  # from one address, and grouping by address would fold all of them into a
  # single session — one "user" doing everything at once.
  defp derived_token(params, site, ip_hash) do
    project = param(params, ~w(project app)) || "-"
    who = user_id(params) || param(params, ~w(visitor v)) || ip_hash || "anon"
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
end
