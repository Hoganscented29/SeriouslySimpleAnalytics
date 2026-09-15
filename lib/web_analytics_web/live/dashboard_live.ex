defmodule WebAnalyticsWeb.DashboardLive do
  @moduledoc """
  The analytics dashboard.

  All view state lives in the query string, so any view — a range, a tab, the
  anomaly filter, a flow grouped by title — is a shareable URL rather than
  something the reader has to reconstruct by clicking.
  """
  use WebAnalyticsWeb, :live_view

  import WebAnalyticsWeb.DashboardComponents

  alias WebAnalytics.Analytics
  alias WebAnalytics.Analytics.Anomaly
  alias WebAnalytics.Geo
  alias WebAnalytics.Ingest.Crawler
  alias WebAnalytics.Sites

  @tabs ~w(live overview users pages events metrics flow locations clicks forms sessions anomalies crawlers)
  @click_groups ~w(name id class text selector tag)
  @location_levels ~w(country region county city)
  @flow_modes ~w(pages events)
  @refresh_ms 5_000

  # The live tab gets its own clock. The general refresh is for a page whose
  # numbers move slowly; this one is a question about the last thirty seconds,
  # and it runs on its own interval so it neither waits on that refresh nor
  # makes every other tab pay for a query it does not show.
  @live_ms 10_000

  @impl true
  def mount(params, _session, socket) do
    # The tracker beacons every second, so the dashboard refreshes on its own
    # rather than making the reader reload to see a visit in progress.
    if connected?(socket) do
      :timer.send_interval(@refresh_ms, self(), :refresh)
      :timer.send_interval(@live_ms, self(), :live_tick)
    end

    case socket.assigns.live_action do
      :admin -> mount_admin(params, socket)
      _ -> mount_own(socket)
    end
  end

  defp mount_own(socket) do
    user = socket.assigns.current_scope.user

    # Creating the first site here means a new account never lands on an empty
    # page asking it to make something before it can see its own ID.
    sites = Sites.ensure_site_for_user!(user)

    {:ok,
     socket
     |> assign(:sites, sites)
     |> assign(:page_title, "Analytics")
     |> assign(:viewing_as_admin, false)
     |> assign(:owner, nil)
     |> assign(:own_account, true)}
  end

  # The admin drill-down is its own live_action on its own route, rather than a
  # "may this user see other people's sites?" branch inside the ordinary one.
  # The route sits behind :require_admin, so the ownership rule on the normal
  # dashboard stays exactly as strict as it reads — there is no path through it
  # that returns a site the signed-in user does not own.
  defp mount_admin(%{"key" => key}, socket) do
    case Sites.fetch_site_by_key(key) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "No account with the ID #{key}.")
         |> push_navigate(to: ~p"/admin")}

      site ->
        {:ok,
         socket
         |> assign(:sites, [site])
         |> assign(:page_title, "#{site.name} — admin")
         |> assign(:viewing_as_admin, true)
         |> assign(:owner, owner_email(site))
         # An admin opening their own account through this route should not be
         # told it belongs to somebody else. A banner that is wrong about whose
         # data this is undermines the one job it has.
         |> assign(:own_account, site.user_id == socket.assigns.current_scope.user.id)}
    end
  end

  defp owner_email(%{user_id: nil}), do: nil

  defp owner_email(%{user_id: user_id}) do
    case WebAnalytics.Accounts.get_user(user_id) do
      nil -> nil
      user -> user.email
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    site = resolve_site(socket.assigns.sites, params["site"])

    socket =
      socket
      |> assign(:site, site)
      |> assign(:tab, tab(params["tab"]))
      |> assign(:click_group, click_group(params["clicks"]))
      |> assign(:location_level, location_level(params["loc"]))
      |> assign(:selected_page, params["page"])
      |> assign(:selected_event, params["event"])
      |> assign(:flow_mode, flow_mode(params["flow"]))
      |> assign(:metric, blank_to_nil(params["metric"]))
      |> assign(:grain, grain(params["grain"], params["range"]))
      |> assign(:user_sort, user_sort(params["usort"]))
      |> assign(:project, blank_to_nil(params["project"]))
      |> assign(:anomaly_labels, Anomaly.labels())
      |> assign(:crawler_labels, Crawler.labels())
      # DB-IP's Lite database is CC BY 4.0, which requires attribution wherever
      # its data is shown. Surfacing it here keeps a default deployment
      # compliant without the operator having to know that.
      |> assign(:geoip_loaded?, Geo.Database.loaded?())
      |> assign(:filters, build_filters(site, params))
      |> assign_new(:live, fn -> nil end)

    socket = socket |> load() |> load_controls()

    # Loaded on arrival as well as on the interval, so opening the tab shows
    # numbers rather than ten seconds of nothing.
    {:noreply, if(socket.assigns.tab == "live" and site, do: assign_live(socket), else: socket)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # Only while the tab is open: a timer that queries for a panel nobody is
  # looking at is load with no reader.
  def handle_info(:live_tick, %{assigns: %{tab: "live", site: site}} = socket)
      when not is_nil(site) do
    {:noreply, assign_live(socket)}
  end

  def handle_info(:live_tick, socket), do: {:noreply, socket}

  # Both handles come from one input event, so a drag of either sends the pair
  # and the server never has to guess which one moved.
  @impl true
  def handle_event("dwell_range", %{"dmin" => min, "dmax" => max}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"dmin" => min, "dmax" => max}))}
  end

  def handle_event("select_metric", %{"metric" => metric}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"metric" => metric}))}
  end

  def handle_event("grain", %{"grain" => grain}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"grain" => grain}))}
  end

  def handle_event("reset_dwell", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"dmin" => nil, "dmax" => nil}))}
  end

  # A toggle rather than two events: the same row both adds and removes, and
  # the list it is toggling against is the one already in the URL.
  def handle_event("toggle_origin", %{"origin" => origin}, socket) do
    current = socket.assigns.filters.exclude_origins

    next =
      if origin in current,
        do: List.delete(current, origin),
        else: [origin | current]

    {:noreply,
     push_patch(socket,
       to: path_for(socket, %{"noip" => if(next == [], do: nil, else: Enum.join(next, ","))})
     )}
  end

  def handle_event("exclude_suggested_origins", _params, socket) do
    suggested =
      socket.assigns.origins
      |> Enum.filter(& &1.suggested)
      |> Enum.map(& &1.ip_hash)

    combined = Enum.uniq(socket.assigns.filters.exclude_origins ++ suggested)

    {:noreply,
     push_patch(socket,
       to:
         path_for(socket, %{"noip" => if(combined == [], do: nil, else: Enum.join(combined, ","))})
     )}
  end

  def handle_event("clear_origins", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"noip" => nil}))}
  end

  # One row, one session. The origin filter is a different control with a
  # different scope, and it lives in the Origins panel.
  def handle_event("toggle_session", %{"session" => id}, socket) do
    current = socket.assigns.filters.exclude_sessions
    id = String.to_integer(id)

    next =
      if id in current, do: List.delete(current, id), else: [id | current]

    {:noreply,
     push_patch(socket,
       to: path_for(socket, %{"nosess" => if(next == [], do: nil, else: Enum.join(next, ","))})
     )}
  end

  # The one obvious way back: clears both kinds of exclusion, because a reader
  # looking at a filtered table wants the table back, not a lesson in which
  # control did it.
  def handle_event("clear_row_filters", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"nosess" => nil, "noip" => nil}))}
  end

  @impl true
  def handle_event("navigate", params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, params))}
  end

  def handle_event("toggle_anomalies", _params, socket) do
    next = if socket.assigns.filters.exclude_anomalies, do: "include", else: "exclude"
    {:noreply, push_patch(socket, to: path_for(socket, %{"anomalies" => next}))}
  end

  def handle_event("toggle_crawlers", _params, socket) do
    next = if socket.assigns.filters.exclude_crawlers, do: "include", else: "exclude"
    {:noreply, push_patch(socket, to: path_for(socket, %{"crawlers" => next}))}
  end

  def handle_event("select_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"page" => page, "tab" => "flow"}))}
  end

  def handle_event("select_event", %{"event" => name}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"event" => name, "tab" => "events"}))}
  end

  def handle_event("select_domain", %{"domain" => domain}, socket) do
    # Toggles: clicking the domain you are already filtered to clears it, which
    # is what a reader expects from a row that is visibly highlighted.
    next = if socket.assigns.filters.host == domain, do: nil, else: domain
    {:noreply, push_patch(socket, to: path_for(socket, %{"domain" => next}))}
  end

  def handle_event("select_project", %{"project" => project}, socket) do
    next = if socket.assigns.filters.project == project, do: nil, else: project
    {:noreply, push_patch(socket, to: path_for(socket, %{"project" => next}))}
  end

  # Toggles like the domain and project rows: the chip on a row that is already
  # the selected user is how a reader gets back to everyone.
  def handle_event("select_user", %{"user" => user}, socket) do
    next = if socket.assigns.filters.user == user, do: nil, else: user
    {:noreply, push_patch(socket, to: path_for(socket, %{"user" => next}))}
  end

  def handle_event("clear_user", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"user" => nil}))}
  end

  def handle_event("clear_event", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"event" => nil}))}
  end

  def handle_event("clear_page", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"page" => nil}))}
  end

  # -- state ---------------------------------------------------------------

  defp resolve_site([], _key), do: nil
  defp resolve_site([site | _], nil), do: site

  defp resolve_site(sites, key) do
    Enum.find(sites, List.first(sites), &(&1.key == key))
  end

  defp tab(value) when value in @tabs, do: value
  defp tab(_), do: "overview"

  defp click_group(value) when value in @click_groups, do: String.to_existing_atom(value)
  defp click_group(_), do: :name

  defp user_sort(value) do
    Enum.find(Analytics.user_sorts(), :recent, &(Atom.to_string(&1) == value))
  end

  defp flow_mode(value) when value in @flow_modes, do: value
  defp flow_mode(_), do: "pages"

  defp location_level(value) when value in @location_levels, do: String.to_existing_atom(value)
  defp location_level(_), do: :country

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp build_filters(nil, _params), do: nil

  defp build_filters(site, params) do
    Analytics.filters(site.id, %{
      range: range(params["range"]),
      exclude_anomalies: params["anomalies"] != "include",
      exclude_crawlers: params["crawlers"] != "include",
      project: blank_to_nil(params["project"]),
      host: blank_to_nil(params["domain"]),
      user: blank_to_nil(params["user"]),
      dwell_min: params["dmin"] || 0,
      dwell_max: params["dmax"] || last_dwell_bucket(),
      exclude_origins: origins_param(params["noip"]),
      exclude_sessions: sessions_param(params["nosess"]),
      group_by: if(params["group"] == "title", do: :title, else: :path)
    })
  end

  defp range(value) do
    if value in Analytics.ranges(), do: value, else: "7d"
  end

  defp last_dwell_bucket, do: length(Analytics.dwell_bucket_labels()) - 1

  # Hourly for the short ranges and daily for the long ones, unless the reader
  # has chosen: a month in hourly bars is seven hundred slivers, and a day in
  # daily bars is one.
  defp grain(value, _range) when value in ["hour", "day"], do: String.to_existing_atom(value)
  defp grain(_value, range) when range in ["1h", "24h"], do: :hour
  defp grain(_value, _range), do: :day

  # Dropped from the URL at the range's own default, like every other control
  # here: a shared link carrying each default is longer and says less.
  defp grain_param(%{assigns: %{grain: grain, filters: %{range: range}}}) do
    if grain == grain(nil, range), do: nil, else: Atom.to_string(grain)
  end

  defp grain_param(_socket), do: nil

  # Hex hashes, so anything else in the parameter is somebody editing the URL
  # by hand and is dropped rather than sent to the database.
  defp origins_param(nil), do: []

  defp origins_param(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{6,64}\z/, &1))
    |> Enum.uniq()
    |> Enum.take(50)
  end

  defp origins_param(_), do: []

  # Sifted to digits here and cast to integers by Analytics.filters/2, so a
  # hand-edited URL cannot put a string where the query wants a bigint.
  defp sessions_param(nil), do: []

  defp sessions_param(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/\A[0-9]{1,19}\z/, &1))
    |> Enum.uniq()
    |> Enum.take(200)
  end

  defp sessions_param(_), do: []

  defp list_param(socket, key) do
    case socket.assigns.filters && Map.get(socket.assigns.filters, key) do
      nil -> nil
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  # Dropped from the URL when it is at the stop, so a default view does not
  # carry a range that excludes nothing.
  defp dwell_param(socket, key, default) do
    case socket.assigns.filters && Map.get(socket.assigns.filters, key) do
      nil -> nil
      ^default -> nil
      value -> to_string(value)
    end
  end

  # Keeps every control additive: changing the range preserves the tab, the
  # grouping and the filter state instead of resetting them.
  defp path_for(socket, changes) do
    current = %{
      "site" => socket.assigns.site && socket.assigns.site.key,
      "range" => socket.assigns.filters && socket.assigns.filters.range,
      "anomalies" =>
        if(socket.assigns.filters && socket.assigns.filters.exclude_anomalies,
          do: "exclude",
          else: "include"
        ),
      "group" =>
        if(socket.assigns.filters && socket.assigns.filters.group_by == :title,
          do: "title",
          else: "path"
        ),
      "crawlers" =>
        if(socket.assigns.filters && socket.assigns.filters.exclude_crawlers,
          do: "exclude",
          else: "include"
        ),
      "tab" => socket.assigns.tab,
      "clicks" => to_string(socket.assigns.click_group),
      "loc" => to_string(socket.assigns.location_level),
      "project" => socket.assigns.filters && socket.assigns.filters.project,
      "page" => socket.assigns.selected_page,
      "event" => socket.assigns.selected_event,
      # Omitted at its default, like every other control: a shared URL carrying
      # each default is longer and says less.
      "flow" => if(socket.assigns.flow_mode == "pages", do: nil, else: "events"),
      "domain" => socket.assigns.filters && socket.assigns.filters.host,
      "dmin" => dwell_param(socket, :dwell_min, 0),
      "dmax" => dwell_param(socket, :dwell_max, last_dwell_bucket()),
      "noip" => list_param(socket, :exclude_origins),
      "nosess" => list_param(socket, :exclude_sessions),
      "metric" => socket.assigns[:metric],
      "grain" => grain_param(socket),
      "user" => socket.assigns.filters && socket.assigns.filters.user,
      "usort" =>
        if(socket.assigns[:user_sort] in [nil, :recent],
          do: nil,
          else: to_string(socket.assigns.user_sort)
        )
    }

    query =
      current
      |> Map.merge(changes)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.sort()

    if socket.assigns[:viewing_as_admin] do
      ~p"/admin/accounts/#{socket.assigns.site.key}?#{query}"
    else
      ~p"/dashboard?#{query}"
    end
  end

  # -- loading -------------------------------------------------------------

  defp load(%{assigns: %{site: nil}} = socket), do: assign(socket, :data, %{})

  defp load(socket) do
    filters = socket.assigns.filters

    data =
      %{
        overview: Analytics.overview(filters),
        projects: Analytics.projects(filters),
        domains: Analytics.domains(filters),
        channels: Analytics.channels(filters),
        # For the banner every tab shows while narrowed to one user. Only then:
        # unfiltered, there is no one to profile and no query to run.
        user_profile: Analytics.user_profile(filters)
      }
      |> Map.merge(tab_data(socket.assigns.tab, filters, socket.assigns))

    assign(socket, :data, data)
  end

  defp tab_data("overview", filters, _assigns) do
    %{
      timeseries: Analytics.timeseries(filters),
      pages: Analytics.pages(filters, 8),
      referrers: Analytics.session_breakdown(filters, :referrer_host, 8),
      browsers: Analytics.session_breakdown(filters, :browser, 6),
      devices: Analytics.session_breakdown(filters, :device_type, 4),
      anomalies: Analytics.anomaly_breakdown(filters)
    }
  end

  # Everyone identified, or — narrowed to one user — what that user did: their
  # events as a timeline, what they did most, and the numbers they reported.
  defp tab_data("users", %{user: user} = filters, _assigns) when is_binary(user) do
    %{
      recent_events: Analytics.recent_events(filters, 60),
      events: Analytics.events(filters, 12),
      metrics: Analytics.metrics(filters),
      sessions: Analytics.recent_sessions(filters, 20)
    }
  end

  defp tab_data("users", filters, assigns) do
    %{users: Analytics.users(filters, 100, assigns.user_sort)}
  end

  defp tab_data("pages", filters, _assigns) do
    %{
      pages: Analytics.pages(filters, 50),
      scroll: Analytics.scroll_distribution(filters),
      entries: Analytics.entries(filters),
      exits: Analytics.exits(filters)
    }
  end

  defp tab_data("locations", filters, assigns) do
    %{
      coverage: Analytics.geo_coverage(filters),
      locations: Analytics.locations(filters, assigns.location_level, 50),
      countries: Analytics.locations(filters, :country, 10),
      cities: Analytics.locations(filters, :city, 10)
    }
  end

  defp tab_data("events", filters, assigns) do
    events = Analytics.events(filters, 50)

    # A name that no longer appears in the range would otherwise show an empty
    # breakdown next to a populated list, which reads as a bug rather than as a
    # stale link.
    selected =
      assigns.selected_event && Enum.find(events, &(&1.name == assigns.selected_event))

    %{
      events: events,
      recent_events: Analytics.recent_events(filters, 40),
      selected_event: selected,
      event_attributes: selected && Analytics.event_attributes(filters, selected.name),
      event_series: selected && Analytics.event_timeseries(filters, selected.name)
    }
  end

  defp tab_data("flow", filters, %{flow_mode: "events"} = assigns) do
    %{
      event_flow: Analytics.event_flow(filters, 18),
      event_entries: Analytics.event_entries(filters),
      event_exits: Analytics.event_exits(filters),
      events: Analytics.events(filters, 30),
      sequences:
        assigns.selected_event && Analytics.event_sequences(filters, assigns.selected_event, 8)
    }
  end

  defp tab_data("flow", filters, assigns) do
    %{
      flow: Analytics.flow(filters, 18),
      journeys: Analytics.journeys(filters, 12),
      flow_coverage: Analytics.flow_coverage(filters, 18),
      entries: Analytics.entries(filters),
      exits: Analytics.exits(filters),
      navigation:
        assigns.selected_page && Analytics.navigation_summary(filters, assigns.selected_page),
      pages: Analytics.pages(filters, 20)
    }
  end

  defp tab_data("clicks", filters, assigns) do
    %{
      clicks: Analytics.clicks(filters, assigns.click_group, 30),
      # The same clicks under four labellings, side by side. One at a time
      # meant clicking through the switcher to find out which way of naming an
      # element your markup actually supports — and on a page with no ids, or
      # no classes, that is three empty lists to discover one at a time.
      click_breakdowns:
        Map.new([:name, :id, :class, :selector], fn group ->
          {group, Analytics.clicks(filters, group, 8)}
        end),
      outbound: Analytics.outbound_links(filters, 20),
      click_types: Analytics.click_types(filters)
    }
  end

  defp tab_data("forms", filters, _assigns) do
    %{
      form_summary: Analytics.form_summary(filters),
      recent_forms: Analytics.recent_forms(filters, 20)
    }
  end

  defp tab_data("sessions", filters, _assigns) do
    %{
      sessions: Analytics.recent_sessions(filters, 60),
      anomalies: Analytics.anomaly_breakdown(filters)
    }
  end

  defp tab_data("metrics", filters, assigns) do
    metrics = Analytics.metrics(filters)

    # The chosen key if it still has numbers in this range, otherwise the one
    # reported most. A stale ?metric= from a shared link should land on
    # something rather than on an empty chart naming a key that is not there.
    selected =
      Enum.find(metrics, &(&1.key == assigns.metric)) || List.first(metrics)

    %{
      metrics: metrics,
      selected_metric: selected,
      metric_series:
        selected && Analytics.metric_series(filters, selected.key, granularity: assigns.grain)
    }
  end

  defp tab_data("anomalies", filters, _assigns) do
    %{
      anomalies: Analytics.anomaly_breakdown(filters),
      anomaly_explanations: Anomaly.explanations(),
      dwell: Analytics.dwell_distribution(filters)
    }
  end

  defp tab_data("crawlers", filters, _assigns) do
    %{
      crawler_overview: Analytics.crawler_overview(filters),
      crawlers_by_name: Analytics.crawlers_by_name(filters),
      crawlers_by_kind: Analytics.crawlers_by_kind(filters),
      crawler_pages: Analytics.crawler_pages(filters),
      recent_crawlers: Analytics.recent_crawlers(filters)
    }
  end

  # Loaded by assign_live/1 on its own interval rather than here, so the five
  # second refresh does not run it too.
  defp tab_data("live", _filters, _assigns), do: %{}

  defp tab_data(_tab, _filters, _assigns), do: %{}

  # The filter bar's own data, kept out of the five second refresh.
  #
  # These two feed controls rather than metrics: the session-length chart and
  # the origins list. Rebuilding them on the timer re-rendered the filter bar
  # every five seconds, which snapped the Origins panel shut while it was open
  # and fought a slider being dragged — the page looked like it was reloading
  # itself. They change when the range or a filter changes, which is exactly
  # when handle_params runs, so that is when they are loaded.
  defp load_controls(%{assigns: %{filters: nil}} = socket) do
    socket |> assign(:dwell, []) |> assign(:origins, [])
  end

  defp load_controls(socket) do
    socket
    |> assign(:dwell, Analytics.dwell_distribution(socket.assigns.filters))
    |> assign(:origins, Analytics.origins(socket.assigns.filters))
  end

  defp assign_live(socket) do
    assign(socket, :live, Analytics.active_now(socket.assigns.filters))
  end

  # -- template helpers ----------------------------------------------------

  defp tabs, do: @tabs
  defp click_groups, do: @click_groups
  defp location_levels, do: @location_levels

  defp base_url, do: url(~p"/") |> String.trim_trailing("/")

  @doc """
  The line to hand a coding agent, naming this account.

  Called from GettingStartedLive, which is where the instructions live now. It
  stays here because the account-id variant of the prompt belongs beside the
  dashboard's own idea of a site, and moving it would leave two nearly
  identical prompts in two modules.
  """
  def agent_prompt(site, endpoint) do
    """
    Read #{endpoint}/llms.txt and instrument this project with
    SeriouslySimpleAnalytics. Use account id #{site.key} and set project to this
    tool's name. Report at least: first run, run started/completed with an
    outcome, each tool call, and errors by kind. Reuse one sid for the whole run.
    Never send credentials, prompts or completions. Update our llms.txt with the
    instructed changes.
    """
    |> String.trim()
  end
end
