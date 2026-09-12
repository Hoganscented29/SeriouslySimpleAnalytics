defmodule WebAnalyticsWeb.DashboardLive do
  @moduledoc """
  The analytics dashboard.

  All view state lives in the query string, so any view — a range, a tab, the
  anomaly filter, a flow grouped by title — is a shareable URL rather than
  something the reader has to reconstruct by clicking.
  """
  use WebAnalyticsWeb, :live_view

  import WebAnalyticsWeb.DashboardComponents
  import WebAnalyticsWeb.IntegrationComponents, only: [integration_chat: 1]

  alias WebAnalytics.Analytics
  alias WebAnalytics.Analytics.Anomaly
  alias WebAnalytics.Geo
  alias WebAnalytics.Ingest.Crawler
  alias WebAnalytics.Sites

  @tabs ~w(overview pages events flow locations clicks forms sessions crawlers)
  @click_groups ~w(name id class text selector tag)
  @location_levels ~w(country region county city)
  @refresh_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    # The tracker beacons every second, so the dashboard refreshes on its own
    # rather than making the reader reload to see a visit in progress.
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

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
      |> assign(:project, blank_to_nil(params["project"]))
      |> assign(:anomaly_labels, Anomaly.labels())
      |> assign(:crawler_labels, Crawler.labels())
      # DB-IP's Lite database is CC BY 4.0, which requires attribution wherever
      # its data is shown. Surfacing it here keeps a default deployment
      # compliant without the operator having to know that.
      |> assign(:geoip_loaded?, Geo.Database.loaded?())
      |> assign(:filters, build_filters(site, params))

    {:noreply, load(socket)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

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

  def handle_event("clear_event", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"event" => nil}))}
  end

  def handle_event("clear_page", _params, socket) do
    {:noreply, push_patch(socket, to: path_for(socket, %{"page" => nil}))}
  end

  def handle_event("add_site", _params, %{assigns: %{viewing_as_admin: true}} = socket) do
    # The button is hidden in the admin view, and a hidden button is not a
    # control. Creating a site under an account you are only inspecting is
    # nobody's intention.
    {:noreply, put_flash(socket, :error, "Not while viewing another account.")}
  end

  def handle_event("add_site", _params, socket) do
    user = socket.assigns.current_scope.user

    case Sites.create_site_for_user(user) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign(:sites, Sites.list_sites_for_user(user))
         |> push_patch(to: ~p"/dashboard?site=#{site.key}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create another site")}
    end
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
      group_by: if(params["group"] == "title", do: :title, else: :path)
    })
  end

  defp range(value) do
    if value in Analytics.ranges(), do: value, else: "7d"
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
      "event" => socket.assigns.selected_event
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
        channels: Analytics.channels(filters)
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
      dwell: Analytics.dwell_distribution(filters),
      anomalies: Analytics.anomaly_breakdown(filters)
    }
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

  defp tab_data("flow", filters, assigns) do
    %{
      flow: Analytics.flow(filters, 18),
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
      anomalies: Analytics.anomaly_breakdown(filters),
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

  defp tab_data(_tab, _filters, _assigns), do: %{}

  # -- template helpers ----------------------------------------------------

  defp tabs, do: @tabs
  defp click_groups, do: @click_groups
  defp location_levels, do: @location_levels

  defp base_url, do: url(~p"/") |> String.trim_trailing("/")

  @doc """
  The prompt to hand a coding agent, naming this account.

  A prompt rather than a description, because the reader's next move is to paste
  it. Naming what to report matters more than it looks: an agent told only to
  "add analytics" chooses its own events, and every integration then measures
  something different.
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
