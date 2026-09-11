defmodule WebAnalytics.Ingest.Processor do
  @moduledoc """
  Applies a normalised batch to Postgres.

  Events are folded into a single plan first, so a flush carrying 60 heartbeats
  for one session collapses into one pageview update and one session update
  rather than 60 round trips. Every write is an upsert keyed on a natural
  identifier, which makes retried or duplicated beacons idempotent.
  """

  import Ecto.Query

  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Event
  alias WebAnalytics.Tracking.FormCapture
  alias WebAnalytics.Tracking.Pageview
  alias WebAnalytics.Tracking.Session

  @doc "Applies one normalised batch. Returns `{:ok, session_id}` or `{:error, reason}`."
  def apply_batch(%{events: []}), do: {:ok, :noop}

  def apply_batch(batch) do
    plan = build_plan(batch)

    Repo.transaction(fn ->
      session_id = upsert_session(plan)
      plan = resolve_auto_pageviews(plan, session_id)
      pageview_ids = upsert_pageviews(plan, session_id)
      apply_pageview_metrics(plan, session_id, pageview_ids)
      insert_events(plan, session_id, pageview_ids)
      insert_forms(plan, session_id, pageview_ids)
      apply_session_metrics(plan, session_id)
      session_id
    end)
  end

  # -- planning ------------------------------------------------------------

  defp build_plan(batch) do
    base = %{
      site_id: batch.site_id,
      token: batch.token,
      visitor_token: batch.visitor_token,
      ip_hash: batch.ip_hash,
      project: Map.get(batch, :project),
      channel: Map.get(batch, :channel),
      location: Map.get(batch, :location),
      received_at: batch.received_at,
      init: nil,
      first_at: nil,
      last_at: nil,
      pageviews: %{},
      pv_order: [],
      auto_pageviews: [],
      pv_metrics: %{},
      clicks: [],
      forms: [],
      ended_at: nil,
      session: %{
        dwell_ms: 0,
        active_ms: 0,
        ticks: 0,
        active_ticks: 0,
        max_scroll_pct: 0,
        clicks: 0,
        outbound: 0,
        forms: 0,
        max_seq: 0,
        exit_path: nil,
        exit_title: nil
      }
    }

    Enum.reduce(batch.events, base, &apply_event/2)
  end

  defp apply_event(event, plan) do
    plan
    |> touch_times(event.at)
    |> merge_event(event)
  end

  defp touch_times(plan, at) do
    plan
    |> Map.update!(:first_at, fn
      nil -> at
      current -> if DateTime.compare(at, current) == :lt, do: at, else: current
    end)
    |> Map.update!(:last_at, fn
      nil -> at
      current -> if DateTime.compare(at, current) == :gt, do: at, else: current
    end)
  end

  defp merge_event(plan, %{kind: :init} = event) do
    %{plan | init: event}
  end

  defp merge_event(plan, %{kind: :pageview, seq: :auto} = event) do
    %{plan | auto_pageviews: plan.auto_pageviews ++ [event]}
  end

  defp merge_event(plan, %{kind: :pageview} = event) do
    seq = event.seq

    %{
      plan
      | pageviews: Map.put(plan.pageviews, seq, event),
        pv_order: if(seq in plan.pv_order, do: plan.pv_order, else: plan.pv_order ++ [seq]),
        session: %{
          plan.session
          | max_seq: max(plan.session.max_seq, seq),
            exit_path: event.path,
            exit_title: event.title
        }
    }
    |> update_pv_metrics(seq, fn metrics ->
      %{metrics | doc_height: event.doc_height || metrics.doc_height}
    end)
  end

  defp merge_event(plan, %{kind: :tick} = event) do
    session = plan.session

    plan
    |> Map.put(:session, %{
      session
      | dwell_ms: max(session.dwell_ms, event.session_dwell_ms || 0),
        active_ms: max(session.active_ms, event.session_active_ms || 0),
        ticks: session.ticks + 1,
        active_ticks: session.active_ticks + if(event.active, do: 1, else: 0),
        max_scroll_pct: max(session.max_scroll_pct, event.scroll_pct || 0),
        max_seq: max(session.max_seq, event.pageview_seq)
    })
    |> update_pv_metrics(event.pageview_seq, fn metrics ->
      %{
        metrics
        | dwell_ms: max(metrics.dwell_ms, event.pageview_dwell_ms || 0),
          active_ms: max(metrics.active_ms, event.pageview_active_ms || 0),
          ticks: metrics.ticks + 1,
          max_scroll_pct: max(metrics.max_scroll_pct, event.scroll_pct || 0),
          max_scroll_px: max(metrics.max_scroll_px, event.scroll_px || 0),
          doc_height: event.doc_height || metrics.doc_height,
          last_at: event.at
      }
    end)
  end

  defp merge_event(plan, %{kind: :click} = event) do
    session = plan.session
    seq = event.pageview_seq

    plan
    |> Map.put(:clicks, [event | plan.clicks])
    |> Map.put(:session, %{
      session
      | clicks: session.clicks + 1,
        outbound: session.outbound + if(event.outbound, do: 1, else: 0)
    })
    |> update_pv_metrics(seq, fn metrics -> %{metrics | clicks: metrics.clicks + 1} end)
  end

  defp merge_event(plan, %{kind: :form} = event) do
    session = plan.session

    plan
    |> Map.put(:forms, [event | plan.forms])
    |> Map.put(:session, %{session | forms: session.forms + 1})
  end

  defp merge_event(plan, %{kind: :end} = event) do
    session = plan.session

    plan
    |> Map.put(:ended_at, event.at)
    |> Map.put(:session, %{
      session
      | dwell_ms: max(session.dwell_ms, event.session_dwell_ms || 0),
        active_ms: max(session.active_ms, event.session_active_ms || 0),
        max_scroll_pct: max(session.max_scroll_pct, event.scroll_pct || 0)
    })
    |> update_pv_metrics(event.pageview_seq, fn metrics ->
      %{
        metrics
        | dwell_ms: max(metrics.dwell_ms, event.pageview_dwell_ms || 0),
          active_ms: max(metrics.active_ms, event.pageview_active_ms || 0),
          max_scroll_pct: max(metrics.max_scroll_pct, event.scroll_pct || 0),
          max_scroll_px: max(metrics.max_scroll_px, event.scroll_px || 0),
          exit: true,
          last_at: event.at
      }
    end)
  end

  defp update_pv_metrics(plan, nil, _fun), do: plan

  defp update_pv_metrics(plan, seq, fun) do
    metrics = Map.get(plan.pv_metrics, seq, empty_metrics())
    %{plan | pv_metrics: Map.put(plan.pv_metrics, seq, fun.(metrics))}
  end

  defp empty_metrics do
    %{
      dwell_ms: 0,
      active_ms: 0,
      ticks: 0,
      clicks: 0,
      max_scroll_pct: 0,
      max_scroll_px: 0,
      doc_height: nil,
      exit: false,
      last_at: nil
    }
  end

  # Assigns sequence numbers to pageviews the caller did not number, continuing
  # from whatever the session already has and chaining each one's `from_*` to the
  # page before it. Runs inside the write transaction, so two beacons racing on
  # the same session cannot both claim the same sequence — the unique index on
  # (session_id, seq) is the backstop.
  defp resolve_auto_pageviews(%{auto_pageviews: []} = plan, _session_id), do: plan

  defp resolve_auto_pageviews(plan, session_id) do
    previous = last_pageview(session_id)

    {pageviews, order, _last} =
      Enum.reduce(plan.auto_pageviews, {plan.pageviews, plan.pv_order, previous}, fn event,
                                                                                     {pvs, order,
                                                                                      prev} ->
        seq = (prev && prev.seq) |> Kernel.||(0) |> Kernel.+(1)

        resolved = %{
          event
          | seq: seq,
            from_path: event.from_path || (prev && prev.path),
            from_title: event.from_title || (prev && prev.title)
        }

        {
          Map.put(pvs, seq, resolved),
          order ++ [seq],
          %{seq: seq, path: event.path, title: event.title}
        }
      end)

    highest = order |> Enum.max(fn -> 0 end)

    %{
      plan
      | pageviews: pageviews,
        pv_order: order,
        auto_pageviews: [],
        session: %{
          plan.session
          | max_seq: max(plan.session.max_seq, highest),
            exit_path: latest_path(pageviews, order) || plan.session.exit_path,
            exit_title: latest_title(pageviews, order) || plan.session.exit_title
        }
    }
  end

  defp last_pageview(session_id) do
    Repo.one(
      from p in Pageview,
        where: p.session_id == ^session_id,
        order_by: [desc: p.seq],
        limit: 1,
        select: %{seq: p.seq, path: p.path, title: p.title}
    )
  end

  defp latest_path(pageviews, order) do
    case List.last(order) do
      nil -> nil
      seq -> pageviews |> Map.get(seq, %{}) |> Map.get(:path)
    end
  end

  defp latest_title(pageviews, order) do
    case List.last(order) do
      nil -> nil
      seq -> pageviews |> Map.get(seq, %{}) |> Map.get(:title)
    end
  end

  # -- session -------------------------------------------------------------

  defp upsert_session(plan) do
    now = DateTime.utc_now()
    started_at = plan.first_at || now
    last_seen_at = plan.last_at || now
    init = plan.init || %{}
    entry = Map.get(plan.pageviews, 1)

    entry_attrs =
      %{
        site_id: plan.site_id,
        token: plan.token,
        started_at: started_at,
        last_seen_at: last_seen_at,
        inserted_at: now,
        updated_at: now
      }
      |> put_unless_nil(:visitor_token, plan.visitor_token)
      |> put_unless_nil(:ip_hash, plan.ip_hash)
      |> put_unless_nil(:project, plan.project)
      |> put_unless_nil(:channel, plan.channel)
      |> Map.merge(location_attrs(plan.location))
      |> put_unless_nil(:entry_path, entry && entry.path)
      |> put_unless_nil(:entry_title, entry && entry.title)
      |> Map.merge(init_attrs(init))

    {_count, [%{id: id}]} =
      Repo.insert_all(Session, [entry_attrs],
        conflict_target: [:site_id, :token],
        on_conflict: session_on_conflict(),
        returning: [:id]
      )

    id
  end

  @init_fields ~w(referrer referrer_host utm_source utm_medium utm_campaign utm_term
                  utm_content screen_w screen_h viewport_w viewport_h device_pixel_ratio
                  language timezone browser browser_version os device_type bot_ua
                  crawler crawler_kind crawler_name client_signal heartbeat_ms)a

  # Nils are dropped rather than written. `insert_all` bypasses schema defaults,
  # so an explicit nil would hit the NOT NULL on `bot_ua`; omitting the column
  # lets Postgres apply its default, and the `EXCLUDED.*` references in the
  # conflict clause still resolve against that default.
  # A session's location is resolved once and then left alone: the COALESCE in
  # the conflict clause keeps whatever the first beacon established, so a later
  # beacon arriving through a different path cannot relocate a visit mid-visit.
  defp location_attrs(nil), do: %{}

  defp location_attrs(location) do
    %{
      country_code: location[:country_code],
      country: location[:country],
      region: location[:region],
      region_code: location[:region_code],
      county: location[:county],
      city: location[:city],
      latitude: location[:latitude],
      longitude: location[:longitude],
      accuracy_km: location[:accuracy_km],
      geo_source: location[:source]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp init_attrs(init) do
    @init_fields
    |> Enum.flat_map(fn field ->
      case Map.get(init, field) do
        nil -> []
        value -> [{field, value}]
      end
    end)
    |> Map.new()
  end

  # Identity fields are only filled in where still blank, so a late `init` from
  # a resumed tab can complete a session without clobbering what it already has.
  defp session_on_conflict do
    from(s in Session,
      update: [
        set: [
          last_seen_at: fragment("GREATEST(EXCLUDED.last_seen_at, ?)", s.last_seen_at),
          visitor_token: fragment("COALESCE(?, EXCLUDED.visitor_token)", s.visitor_token),
          ip_hash: fragment("COALESCE(?, EXCLUDED.ip_hash)", s.ip_hash),
          project: fragment("COALESCE(?, EXCLUDED.project)", s.project),
          channel: fragment("COALESCE(?, EXCLUDED.channel)", s.channel),
          country_code: fragment("COALESCE(?, EXCLUDED.country_code)", s.country_code),
          country: fragment("COALESCE(?, EXCLUDED.country)", s.country),
          region: fragment("COALESCE(?, EXCLUDED.region)", s.region),
          region_code: fragment("COALESCE(?, EXCLUDED.region_code)", s.region_code),
          county: fragment("COALESCE(?, EXCLUDED.county)", s.county),
          city: fragment("COALESCE(?, EXCLUDED.city)", s.city),
          latitude: fragment("COALESCE(?, EXCLUDED.latitude)", s.latitude),
          longitude: fragment("COALESCE(?, EXCLUDED.longitude)", s.longitude),
          accuracy_km: fragment("COALESCE(?, EXCLUDED.accuracy_km)", s.accuracy_km),
          geo_source: fragment("COALESCE(?, EXCLUDED.geo_source)", s.geo_source),
          entry_path: fragment("COALESCE(?, EXCLUDED.entry_path)", s.entry_path),
          entry_title: fragment("COALESCE(?, EXCLUDED.entry_title)", s.entry_title),
          referrer: fragment("COALESCE(?, EXCLUDED.referrer)", s.referrer),
          referrer_host: fragment("COALESCE(?, EXCLUDED.referrer_host)", s.referrer_host),
          utm_source: fragment("COALESCE(?, EXCLUDED.utm_source)", s.utm_source),
          utm_medium: fragment("COALESCE(?, EXCLUDED.utm_medium)", s.utm_medium),
          utm_campaign: fragment("COALESCE(?, EXCLUDED.utm_campaign)", s.utm_campaign),
          utm_term: fragment("COALESCE(?, EXCLUDED.utm_term)", s.utm_term),
          utm_content: fragment("COALESCE(?, EXCLUDED.utm_content)", s.utm_content),
          screen_w: fragment("COALESCE(?, EXCLUDED.screen_w)", s.screen_w),
          screen_h: fragment("COALESCE(?, EXCLUDED.screen_h)", s.screen_h),
          viewport_w: fragment("COALESCE(EXCLUDED.viewport_w, ?)", s.viewport_w),
          viewport_h: fragment("COALESCE(EXCLUDED.viewport_h, ?)", s.viewport_h),
          device_pixel_ratio:
            fragment("COALESCE(?, EXCLUDED.device_pixel_ratio)", s.device_pixel_ratio),
          language: fragment("COALESCE(?, EXCLUDED.language)", s.language),
          timezone: fragment("COALESCE(?, EXCLUDED.timezone)", s.timezone),
          browser: fragment("COALESCE(?, EXCLUDED.browser)", s.browser),
          browser_version: fragment("COALESCE(?, EXCLUDED.browser_version)", s.browser_version),
          os: fragment("COALESCE(?, EXCLUDED.os)", s.os),
          device_type: fragment("COALESCE(?, EXCLUDED.device_type)", s.device_type),
          bot_ua: fragment("(? OR EXCLUDED.bot_ua)", s.bot_ua),
          crawler: fragment("(? OR EXCLUDED.crawler)", s.crawler),
          crawler_kind: fragment("COALESCE(?, EXCLUDED.crawler_kind)", s.crawler_kind),
          crawler_name: fragment("COALESCE(?, EXCLUDED.crawler_name)", s.crawler_name),
          client_signal: fragment("COALESCE(?, EXCLUDED.client_signal)", s.client_signal),
          heartbeat_ms: fragment("COALESCE(EXCLUDED.heartbeat_ms, ?)", s.heartbeat_ms),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  defp apply_session_metrics(plan, session_id) do
    session = plan.session
    last_seen = plan.last_at || DateTime.utc_now()

    sets = [
      dwell_ms: dynamic([s], fragment("GREATEST(?, ?)", s.dwell_ms, ^session.dwell_ms)),
      active_ms: dynamic([s], fragment("GREATEST(?, ?)", s.active_ms, ^session.active_ms)),
      max_scroll_pct:
        dynamic([s], fragment("GREATEST(?, ?)", s.max_scroll_pct, ^session.max_scroll_pct)),
      pageview_count:
        dynamic([s], fragment("GREATEST(?, ?)", s.pageview_count, ^session.max_seq)),
      last_seen_at:
        dynamic(
          [s],
          fragment("GREATEST(?, ?)", s.last_seen_at, type(^last_seen, :utc_datetime_usec))
        ),
      updated_at: dynamic([_s], type(^DateTime.utc_now(), :utc_datetime_usec))
    ]

    sets = maybe_set(sets, :exit_path, session.exit_path)
    sets = maybe_set(sets, :exit_title, session.exit_title)
    sets = maybe_set(sets, :ended_at, plan.ended_at)

    # Re-running anomaly classification is cheap, and any new activity can flip
    # a session's verdict, so clear the stamp whenever a session moves.
    sets = Keyword.put(sets, :classified_at, dynamic([_s], type(^nil, :utc_datetime_usec)))

    Repo.update_all(
      from(s in Session, where: s.id == ^session_id),
      set: sets,
      inc: [
        tick_count: session.ticks,
        active_tick_count: session.active_ticks,
        click_count: session.clicks,
        outbound_count: session.outbound,
        form_count: session.forms
      ]
    )
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp maybe_set(sets, _key, nil), do: sets
  defp maybe_set(sets, key, value), do: Keyword.put(sets, key, value)

  # -- pageviews -----------------------------------------------------------

  defp upsert_pageviews(%{pv_order: []}, _session_id), do: %{}

  defp upsert_pageviews(plan, session_id) do
    now = DateTime.utc_now()

    entries =
      Enum.map(plan.pv_order, fn seq ->
        pv = Map.fetch!(plan.pageviews, seq)

        %{
          site_id: plan.site_id,
          session_id: session_id,
          seq: seq,
          path: pv.path,
          title: pv.title,
          url: pv.url,
          query: pv.query,
          hash: pv.hash,
          referrer: pv.referrer,
          referrer_host: pv.referrer_host,
          entered_at: pv.at,
          doc_height: pv.doc_height,
          viewport_h: pv.viewport_h,
          from_path: pv.from_path,
          from_title: pv.from_title,
          entrance: seq == 1,
          exit: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, rows} =
      Repo.insert_all(Pageview, entries,
        conflict_target: [:session_id, :seq],
        on_conflict: pageview_on_conflict(),
        returning: [:id, :seq]
      )

    link_previous_pageviews(plan, session_id)

    Map.new(rows, fn row -> {row.seq, row.id} end)
  end

  defp pageview_on_conflict do
    from(p in Pageview,
      update: [
        set: [
          title: fragment("COALESCE(EXCLUDED.title, ?)", p.title),
          url: fragment("COALESCE(EXCLUDED.url, ?)", p.url),
          doc_height: fragment("COALESCE(EXCLUDED.doc_height, ?)", p.doc_height),
          viewport_h: fragment("COALESCE(EXCLUDED.viewport_h, ?)", p.viewport_h),
          from_path: fragment("COALESCE(?, EXCLUDED.from_path)", p.from_path),
          from_title: fragment("COALESCE(?, EXCLUDED.from_title)", p.from_title),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # Closes out the previous hop: the arrival of pageview N is the only reliable
  # signal that pageview N-1 ended, and it supplies that hop's destination for
  # both the path and title flow views.
  defp link_previous_pageviews(plan, session_id) do
    Enum.each(plan.pv_order, fn seq ->
      if seq > 1 do
        pv = Map.fetch!(plan.pageviews, seq)

        Repo.update_all(
          from(p in Pageview, where: p.session_id == ^session_id and p.seq == ^(seq - 1)),
          set: [
            to_path: pv.path,
            to_title: pv.title,
            exit: false,
            updated_at: DateTime.utc_now()
          ],
          inc: []
        )

        Repo.update_all(
          from(p in Pageview,
            where: p.session_id == ^session_id and p.seq == ^(seq - 1) and is_nil(p.left_at)
          ),
          set: [left_at: pv.at]
        )
      end
    end)
  end

  defp apply_pageview_metrics(plan, session_id, pageview_ids) do
    plan.pv_metrics
    |> Enum.reject(fn {_seq, metrics} -> empty_metrics?(metrics) end)
    |> Enum.each(fn {seq, metrics} ->
      query =
        case Map.fetch(pageview_ids, seq) do
          {:ok, id} -> from(p in Pageview, where: p.id == ^id)
          :error -> from(p in Pageview, where: p.session_id == ^session_id and p.seq == ^seq)
        end

      sets = [
        dwell_ms: dynamic([p], fragment("GREATEST(?, ?)", p.dwell_ms, ^metrics.dwell_ms)),
        active_ms: dynamic([p], fragment("GREATEST(?, ?)", p.active_ms, ^metrics.active_ms)),
        max_scroll_pct:
          dynamic([p], fragment("GREATEST(?, ?)", p.max_scroll_pct, ^metrics.max_scroll_pct)),
        max_scroll_px:
          dynamic([p], fragment("GREATEST(?, ?)", p.max_scroll_px, ^metrics.max_scroll_px)),
        updated_at: dynamic([_p], type(^DateTime.utc_now(), :utc_datetime_usec))
      ]

      sets =
        if metrics.doc_height do
          Keyword.put(sets, :doc_height, metrics.doc_height)
        else
          sets
        end

      sets =
        if metrics.last_at do
          Keyword.put(
            sets,
            :left_at,
            dynamic(
              [p],
              fragment(
                "GREATEST(COALESCE(?, ?), ?)",
                p.left_at,
                type(^metrics.last_at, :utc_datetime_usec),
                type(^metrics.last_at, :utc_datetime_usec)
              )
            )
          )
        else
          sets
        end

      Repo.update_all(query,
        set: sets,
        inc: [tick_count: metrics.ticks, click_count: metrics.clicks]
      )
    end)
  end

  defp empty_metrics?(metrics) do
    metrics.ticks == 0 and metrics.clicks == 0 and metrics.dwell_ms == 0 and
      metrics.max_scroll_pct == 0 and metrics.max_scroll_px == 0 and
      is_nil(metrics.doc_height) and is_nil(metrics.last_at)
  end

  # -- events and forms ----------------------------------------------------

  defp insert_events(%{clicks: []}, _session_id, _ids), do: :ok

  defp insert_events(plan, session_id, pageview_ids) do
    resolver = pageview_resolver(plan, session_id, pageview_ids)
    now = DateTime.utc_now()

    entries =
      plan.clicks
      |> Enum.reverse()
      |> Enum.map(fn click ->
        pv = resolver.(click.pageview_seq)

        %{
          site_id: plan.site_id,
          session_id: session_id,
          pageview_id: pv && pv.id,
          type: click.type,
          name: click.name,
          occurred_at: click.at,
          path: pv && pv.path,
          title: pv && pv.title,
          tag: click.tag,
          el_id: click.el_id,
          classes: click.classes,
          class_raw: click.class_raw,
          el_name: click.el_name,
          el_role: click.el_role,
          el_type: click.el_type,
          text: click.text,
          selector: click.selector,
          data_attrs: click.data_attrs,
          href: click.href,
          href_host: click.href_host,
          href_path: click.href_path,
          outbound: click.outbound,
          new_tab: click.new_tab,
          trigger: click.trigger,
          viewport_x: click.viewport_x,
          viewport_y: click.viewport_y,
          page_x: click.page_x,
          page_y: click.page_y,
          scroll_pct: click.scroll_pct,
          ms_since_pageview: click.ms_since_pageview,
          meta: click.meta,
          inserted_at: now
        }
      end)

    Repo.insert_all(Event, entries)
    :ok
  end

  defp insert_forms(%{forms: []}, _session_id, _ids), do: :ok

  defp insert_forms(plan, session_id, pageview_ids) do
    resolver = pageview_resolver(plan, session_id, pageview_ids)
    now = DateTime.utc_now()

    entries =
      plan.forms
      |> Enum.reverse()
      |> Enum.map(fn form ->
        pv = resolver.(form.pageview_seq)

        %{
          site_id: plan.site_id,
          session_id: session_id,
          pageview_id: pv && pv.id,
          status: form.status,
          occurred_at: form.at,
          path: pv && pv.path,
          title: pv && pv.title,
          form_id: form.form_id,
          form_name: form.form_name,
          form_action: form.form_action,
          form_method: form.form_method,
          form_selector: form.form_selector,
          form_classes: form.form_classes,
          field_count: form.field_count,
          filled_count: form.filled_count,
          time_to_first_input_ms: form.time_to_first_input_ms,
          duration_ms: form.duration_ms,
          fields: form.fields,
          data: form.data,
          inserted_at: now
        }
      end)

    Repo.insert_all(FormCapture, entries)
    :ok
  end

  # Clicks can reference a pageview opened in an earlier batch, so anything not
  # written by this flush is looked up once and memoised for the rest of it.
  defp pageview_resolver(plan, session_id, pageview_ids) do
    needed =
      (plan.clicks ++ plan.forms)
      |> Enum.map(& &1.pageview_seq)
      |> Enum.reject(&(is_nil(&1) or &1 == :auto))
      |> Enum.uniq()

    known =
      plan.pv_order
      |> Enum.flat_map(fn seq ->
        case Map.fetch(pageview_ids, seq) do
          {:ok, id} ->
            pv = Map.fetch!(plan.pageviews, seq)
            [{seq, %{id: id, path: pv.path, title: pv.title}}]

          :error ->
            []
        end
      end)
      |> Map.new()

    missing = Enum.reject(needed, &Map.has_key?(known, &1))

    fetched =
      if missing == [] do
        %{}
      else
        from(p in Pageview,
          where: p.session_id == ^session_id and p.seq in ^missing,
          select: %{seq: p.seq, id: p.id, path: p.path, title: p.title}
        )
        |> Repo.all()
        |> Map.new(fn row -> {row.seq, %{id: row.id, path: row.path, title: row.title}} end)
      end

    lookup = Map.merge(fetched, known)

    # An event that names no pageview belongs to whatever page the session is on
    # — which is what a caller means when it reports "a tool was called" without
    # also telling us where.
    latest =
      case lookup |> Map.keys() |> Enum.max(fn -> nil end) do
        nil -> latest_pageview_row(session_id)
        seq -> Map.get(lookup, seq)
      end

    fn
      nil -> latest
      seq -> Map.get(lookup, seq) || latest
    end
  end

  defp latest_pageview_row(session_id) do
    Repo.one(
      from p in Pageview,
        where: p.session_id == ^session_id,
        order_by: [desc: p.seq],
        limit: 1,
        select: %{id: p.id, path: p.path, title: p.title}
    )
  end
end
