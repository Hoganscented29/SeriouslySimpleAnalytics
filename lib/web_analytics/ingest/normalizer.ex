defmodule WebAnalytics.Ingest.Normalizer do
  @moduledoc """
  Turns a raw beacon payload into validated, bounded internal events.

  Everything arriving here is attacker-controlled: the tracker runs in the
  visitor's browser and the collect endpoint is unauthenticated by design. So
  this module coerces every type, truncates every string to its column width,
  caps collection sizes, and drops malformed events individually instead of
  failing the whole batch.
  """

  alias WebAnalytics.Geo
  alias WebAnalytics.Ingest.Crawler
  alias WebAnalytics.Ingest.UserAgent

  # varchar(255) columns; anything wider is stored in a :text column.
  @s 255
  @text 4096
  @body_text 2048

  @max_events 300
  @max_classes 30
  @max_data_attrs 20
  @max_form_fields 300
  @max_field_value 4096

  # Client clocks are not trusted. Event times are anchored to server receive
  # time and offset by the client-reported delta, clamped to a sane window.
  @min_skew_ms -300_000
  @max_skew_ms 60_000

  @kinds ~w(click outbound download mailto tel rage_click custom)
  @form_statuses ~w(submitted abandoned)

  @doc """
  Normalises `payload` for `site`.

  Returns `{:ok, batch}` or `{:error, reason}` when the payload carries no
  usable session token.
  """
  def normalize(site, payload, opts) when is_map(payload) do
    received_at = Keyword.get(opts, :received_at, DateTime.utc_now())
    ip_hash = Keyword.get(opts, :ip_hash)
    settings = Keyword.get(opts, :settings, %{})

    case token(payload) do
      nil ->
        {:error, :missing_session_token}

      token ->
        client_now = number(payload["t"])

        events =
          payload
          |> Map.get("e")
          |> List.wrap()
          |> Enum.take(@max_events)
          |> Enum.flat_map(&normalize_event(&1, received_at, client_now, settings))

        {:ok,
         %{
           site_id: site.id,
           token: token,
           visitor_token: string(payload["v"], @s),
           ip_hash: ip_hash,
           project: string(Keyword.get(opts, :project), @s),
           channel: string(Keyword.get(opts, :channel), @s) || "web",
           agent_name: string(Keyword.get(opts, :agent_name), @s),
           contact_email: string(Keyword.get(opts, :contact_email), @s),
           received_at: received_at,
           location: resolve_location(Keyword.get(opts, :location), events),
           events: events
         }}
    end
  end

  def normalize(_site, _payload, _opts), do: {:error, :invalid_payload}

  # The controller resolves location from headers and the client address, which
  # is everything it can see. The time zone only arrives inside the payload, so
  # the country-level fallback is applied here — and only when the better
  # sources came up empty.
  defp resolve_location(location, events) do
    location = location || Geo.empty()

    if location.country_code do
      location
    else
      case Enum.find(events, &(&1.kind == :init)) do
        %{timezone: zone} when is_binary(zone) ->
          fallback = Geo.resolve(timezone: zone)
          if fallback.country_code, do: fallback, else: location

        _ ->
          location
      end
    end
  end

  defp token(payload) do
    case string(payload["s"], @s) do
      nil -> nil
      "" -> nil
      token -> token
    end
  end

  # -- event dispatch ------------------------------------------------------

  defp normalize_event(%{"n" => name} = event, received_at, client_now, settings) do
    at = event_time(received_at, client_now, event["t"])

    case name do
      "init" -> [init_event(event, at)]
      "pv" -> wrap(pageview_event(event, at))
      "tick" -> wrap(tick_event(event, at))
      "click" -> wrap(click_event(event, at))
      "event" -> wrap(custom_event(event, at))
      "form" -> wrap(form_event(event, at, settings))
      "end" -> [end_event(event, at)]
      _ -> []
    end
  end

  defp normalize_event(_, _, _, _), do: []

  defp wrap(nil), do: []
  defp wrap(event), do: [event]

  defp event_time(received_at, client_now, event_t) do
    with true <- is_number(client_now),
         event_t when is_number(event_t) <- number(event_t) do
      skew =
        (event_t - client_now)
        |> round()
        |> max(@min_skew_ms)
        |> min(@max_skew_ms)

      DateTime.add(received_at, skew, :millisecond)
    else
      _ -> received_at
    end
  end

  # -- init ----------------------------------------------------------------

  defp init_event(event, at) do
    utm = if is_map(event["utm"]), do: event["utm"], else: %{}
    referrer = string(event["ref"], @text)
    user_agent = string(event["ua"], @text)
    ua = UserAgent.parse(user_agent)

    # The client reports what it could work out about itself; the user agent is
    # checked here regardless, so a crawler that stays quiet is still caught.
    client_signal = string(event["bot"], @s)
    crawler = Crawler.classify(user_agent, client_signal)

    %{
      kind: :init,
      at: at,
      referrer: referrer,
      referrer_host: host(referrer),
      utm_source: string(utm["source"], @s),
      utm_medium: string(utm["medium"], @s),
      utm_campaign: string(utm["campaign"], @s),
      utm_term: string(utm["term"], @s),
      utm_content: string(utm["content"], @s),
      screen_w: integer(event["sw"]),
      screen_h: integer(event["sh"]),
      viewport_w: integer(event["vw"]),
      viewport_h: integer(event["vh"]),
      device_pixel_ratio: float(event["dpr"]),
      language: string(event["lang"], @s),
      timezone: string(event["tz"], @s),
      browser: ua.browser,
      browser_version: string(ua.browser_version, @s),
      os: ua.os,
      device_type: ua.device_type,
      bot_ua: ua.bot,
      crawler: crawler.crawler,
      crawler_kind: crawler.kind,
      crawler_name: string(crawler.name, @s),
      client_signal: client_signal,
      heartbeat_ms: non_neg(event["hb"])
    }
  end

  # -- pageview ------------------------------------------------------------

  defp pageview_event(event, at) do
    with path when is_binary(path) <- string(event["path"], @s),
         seq when seq == :auto or (is_integer(seq) and seq > 0) <- pageview_seq(event) do
      referrer = string(event["ref"], @text)

      %{
        kind: :pageview,
        at: at,
        seq: seq,
        path: path,
        title: string(event["title"], @s),
        url: string(event["url"], @text),
        query: string(event["q"], @text),
        hash: string(event["h"], @s),
        referrer: referrer,
        referrer_host: host(referrer),
        viewport_h: integer(event["vh"]),
        doc_height: integer(event["dh"]),
        from_path: string(event["fp"], @s),
        from_title: string(event["ft"], @s)
      }
    else
      _ -> nil
    end
  end

  # A caller that omits `seq` is asking the server to sequence for it. That is
  # the normal case for anything that is not a browser: a tool pinging a URL has
  # no reasonable way to know it is on its own fourth page, and without a
  # sequence there is no flow graph at all.
  defp pageview_seq(event) do
    case integer(event["seq"]) do
      seq when is_integer(seq) and seq > 0 -> seq
      _ -> :auto
    end
  end

  # -- heartbeat -----------------------------------------------------------

  defp tick_event(event, at) do
    case integer(event["pv"]) do
      seq when is_integer(seq) and seq > 0 ->
        %{
          kind: :tick,
          at: at,
          pageview_seq: seq,
          index: integer(event["i"]) || 0,
          active: truthy(event["a"]),
          scroll_pct: percent(event["sp"]),
          scroll_px: non_neg(event["spx"]),
          doc_height: integer(event["dh"]),
          session_dwell_ms: non_neg(event["d"]),
          session_active_ms: non_neg(event["am"]),
          pageview_dwell_ms: non_neg(event["pd"]),
          pageview_active_ms: non_neg(event["pa"])
        }

      _ ->
        nil
    end
  end

  # -- clicks --------------------------------------------------------------

  defp click_event(event, at) do
    kind = string(event["k"], @s)
    type = if kind in @kinds, do: kind, else: "click"
    href = string(event["href"], @text)

    %{
      kind: :click,
      at: at,
      type: type,
      name: string(event["nm"], @s),
      pageview_seq: integer(event["pv"]),
      tag: event["tag"] |> string(@s) |> downcase(),
      el_id: string(event["id"], @s),
      classes: classes(event["cls"]),
      class_raw: string(event["clsr"], @text),
      el_name: string(event["ename"], @s),
      el_role: string(event["role"], @s),
      el_type: string(event["ety"], @s),
      text: string(event["txt"], @body_text),
      selector: string(event["sel"], @text),
      data_attrs: data_attrs(event["data"]),
      href: href,
      href_host: event["host"] |> string(@s) |> downcase() || host(href),
      href_path: string(event["hpath"], @text),
      outbound: truthy(event["out"]),
      new_tab: truthy(event["nt"]),
      trigger: string(event["trig"], @s),
      viewport_x: integer(event["vx"]),
      viewport_y: integer(event["vy"]),
      page_x: integer(event["px"]),
      page_y: integer(event["py"]),
      scroll_pct: percent(event["sp"]),
      ms_since_pageview: non_neg(event["ms"]),
      meta: %{}
    }
  end

  # A first-class custom event, for callers that are not a browser.
  #
  # It shares the click table because the shape is the same — a named thing that
  # happened on a page, with attributes — and giving it a separate table would
  # mean every query had to union the two. Only the entry point differs, so that
  # a server or an agent reporting "checkout_completed" does not have to dress it
  # up as a click.
  defp custom_event(event, at) do
    case string(event["name"] || event["nm"], @s) do
      nil ->
        nil

      name ->
        %{
          kind: :click,
          at: at,
          type: "custom",
          name: name,
          pageview_seq: integer(event["pv"]),
          tag: "custom",
          el_id: nil,
          classes: classes(event["cls"]),
          class_raw: nil,
          el_name: nil,
          el_role: nil,
          el_type: nil,
          text: string(event["text"] || event["txt"], @body_text),
          selector: nil,
          data_attrs: data_attrs(event["data"]),
          href: nil,
          href_host: nil,
          href_path: nil,
          outbound: false,
          new_tab: false,
          trigger: string(event["trig"], @s) || "custom",
          viewport_x: nil,
          viewport_y: nil,
          page_x: nil,
          page_y: nil,
          scroll_pct: percent(event["sp"]),
          ms_since_pageview: non_neg(event["ms"]),
          meta: %{}
        }
    end
  end

  # -- forms ---------------------------------------------------------------

  defp form_event(event, at, settings) do
    status = string(event["st"], @s)

    if status in @form_statuses do
      fields = form_fields(event["flds"], settings)

      %{
        kind: :form,
        at: at,
        status: status,
        pageview_seq: integer(event["pv"]),
        form_id: string(event["fid"], @s),
        form_name: string(event["fnm"], @s),
        form_action: string(event["act"], @text),
        form_method: event["mth"] |> string(@s) |> downcase(),
        form_selector: string(event["sel"], @text),
        form_classes: classes(event["cls"]),
        fields: fields,
        data: form_data(fields),
        field_count: length(fields),
        filled_count: Enum.count(fields, & &1["filled"]),
        time_to_first_input_ms: non_neg(event["tfi"]),
        duration_ms: non_neg(event["dur"])
      }
    end
  end

  defp form_fields(fields, settings) when is_list(fields) do
    keep_passwords = Map.get(settings, "capture_password_fields", false) == true

    fields
    |> Enum.take(@max_form_fields)
    |> Enum.flat_map(fn
      field when is_map(field) -> [form_field(field, keep_passwords)]
      _ -> []
    end)
  end

  defp form_fields(_, _), do: []

  defp form_field(field, keep_passwords) do
    type = field["type"] |> string(@s) |> downcase() || "text"
    client_masked = truthy(field["masked"])

    # The tracker masks sensitive inputs before they leave the page. Anything
    # still arriving as a password value is dropped here too unless the site
    # has explicitly opted in, so plaintext credentials are never persisted by
    # default even if the snippet is stale or tampered with.
    masked? = client_masked or (type == "password" and not keep_passwords)

    value =
      if masked? do
        nil
      else
        string(field["value"], @max_field_value)
      end

    %{
      "name" => string(field["name"], @s),
      "id" => string(field["id"], @s),
      "type" => type,
      "label" => string(field["label"], @body_text),
      "value" => value,
      "filled" => truthy(field["filled"]),
      "masked" => masked?,
      "changes" => non_neg(field["changes"]) || 0,
      "focus_ms" => non_neg(field["focus_ms"]) || 0
    }
  end

  defp form_data(fields) do
    fields
    |> Enum.reject(&(&1["masked"] or is_nil(&1["value"])))
    |> Enum.reduce(%{}, fn field, acc ->
      case field["name"] || field["id"] do
        nil -> acc
        key -> Map.put(acc, key, field["value"])
      end
    end)
  end

  # -- end -----------------------------------------------------------------

  defp end_event(event, at) do
    %{
      kind: :end,
      at: at,
      pageview_seq: integer(event["pv"]),
      session_dwell_ms: non_neg(event["d"]),
      session_active_ms: non_neg(event["am"]),
      pageview_dwell_ms: non_neg(event["pd"]),
      pageview_active_ms: non_neg(event["pa"]),
      scroll_pct: percent(event["sp"]),
      scroll_px: non_neg(event["spx"])
    }
  end

  # -- coercion helpers ----------------------------------------------------

  defp string(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > max -> String.slice(trimmed, 0, max)
      true -> trimmed
    end
  end

  defp string(value, max) when is_number(value), do: string(to_string(value), max)
  defp string(_, _), do: nil

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp number(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp integer(_), do: nil

  # Guards the DB against absurd client-reported durations while still allowing
  # genuinely long sessions through for the anomaly filter to judge.
  defp non_neg(value) do
    case integer(value) do
      nil -> nil
      parsed when parsed < 0 -> 0
      parsed -> min(parsed, 2_147_483_647)
    end
  end

  defp percent(value) do
    case integer(value) do
      nil -> nil
      parsed -> parsed |> max(0) |> min(100)
    end
  end

  defp float(value) do
    case number(value) do
      nil -> nil
      parsed -> parsed / 1
    end
  end

  defp truthy(true), do: true
  defp truthy(1), do: true
  defp truthy("1"), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp classes(values) when is_list(values) do
    values
    |> Enum.take(@max_classes)
    |> Enum.flat_map(fn value ->
      case string(value, @s) do
        nil -> []
        class -> [class]
      end
    end)
    |> Enum.uniq()
  end

  defp classes(_), do: []

  defp data_attrs(values) when is_map(values) do
    values
    |> Enum.take(@max_data_attrs)
    |> Enum.flat_map(fn {key, value} ->
      with key when is_binary(key) <- string(key, @s),
           value when is_binary(value) <- string(value, @body_text) do
        [{key, value}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp data_attrs(_), do: %{}

  defp host(nil), do: nil

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end
end
