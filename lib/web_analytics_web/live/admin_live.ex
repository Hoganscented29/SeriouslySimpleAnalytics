defmodule WebAnalyticsWeb.AdminLive do
  @moduledoc """
  The operator's view of the whole deployment.

  Counters refresh every ten seconds. The tables and breakdowns underneath them
  refresh every sixth tick, because they walk the tables properly and running
  them every ten seconds would make this page the heaviest thing on the box —
  on a box that is also serving the application it is reporting on.

  The sections it shows are whatever the deployment actually has: a box with no
  crawler traffic does not get an empty crawler table.
  """
  use WebAnalyticsWeb, :live_view

  # Only the one component: this module defines its own num/1 and duration/1,
  # and importing the rest would collide with them.
  import WebAnalyticsWeb.DashboardComponents, only: [live_sparkline: 1, masked_ip: 1]

  alias WebAnalytics.Admin
  alias WebAnalytics.Admin.Host

  @counter_ms 10_000

  # Detail is refreshed every sixth counter tick, i.e. once a minute.
  @detail_every 6

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@counter_ms, self(), :tick)
      # CPU is a rate, so the first reading needs a second sample. Taking it a
      # second from now rather than waiting for the first tick means the number
      # appears almost immediately instead of after a blank ten seconds.
      Process.send_after(self(), :prime_cpu, 1_000)
    end

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:tick, 0)
     |> assign(:counter_seconds, div(@counter_ms, 1000))
     |> assign(:system, Admin.system())
     |> assign(:admins, WebAnalytics.Accounts.list_admins())
     |> assign(:cpu_sample, Host.cpu_sample())
     |> assign(:cpu_util, nil)
     |> assign(:cpu_window, nil)
     |> assign(:site_window, :day)
     |> assign(:scope, Admin.scope())
     |> load_host()
     |> load_counters()
     |> load_live()
     |> load_sites()
     |> load_detail()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = %{
      domain: blank_to_nil(params["domain"]),
      project: blank_to_nil(params["project"]),
      origins: origins_param(params["noip"]),
      sessions: sessions_param(params["nosess"])
    }

    socket = assign(socket, :scope, scope)

    {:noreply, socket |> load_counters() |> load_live() |> load_sites() |> load_detail()}
  end

  @impl true
  def handle_info(:tick, socket) do
    tick = socket.assigns.tick + 1

    socket =
      socket
      |> assign(:tick, tick)
      |> sample_cpu(@counter_ms)
      |> load_host()
      |> load_counters()
      # Every tick, not every sixth: a figure about the last thirty seconds is
      # worthless if it is a minute old.
      |> load_live()

    {:noreply,
     if rem(tick, @detail_every) == 0 do
       socket |> load_sites() |> load_detail() |> assign(:system, Admin.system())
     else
       socket
     end}
  end

  def handle_info(:prime_cpu, socket) do
    {:noreply, sample_cpu(socket, 1_000)}
  end

  @impl true
  def handle_event("open_account", %{"key" => key}, socket) do
    case key |> to_string() |> String.trim() do
      "" ->
        {:noreply, socket}

      key ->
        # Checked here rather than letting the dashboard bounce back, so a typo
        # says so on the page the reader is already looking at.
        case WebAnalytics.Sites.fetch_site_by_key(key) do
          nil -> {:noreply, put_flash(socket, :error, "No account with the ID #{key}.")}
          site -> {:noreply, push_navigate(socket, to: ~p"/admin/accounts/#{site.key}")}
        end
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> load_host()
     |> load_counters()
     |> load_live()
     |> load_sites()
     |> load_detail()
     |> assign(:system, Admin.system())
     |> put_flash(:info, "Refreshed.")}
  end

  def handle_event("filter", params, socket) do
    scope = socket.assigns.scope

    next = %{
      "domain" => Map.get(params, "domain", scope.domain),
      "project" => Map.get(params, "project", scope.project)
    }

    {:noreply,
     push_patch(socket, to: ~p"/admin?#{Enum.reject(next, &(elem(&1, 1) in [nil, ""]))}")}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin")}
  end

  # Unticking a row filters out that origin, not the one session: a single
  # session is not something a report can usefully exclude.
  def handle_event("toggle_origin", %{"origin" => origin}, socket) do
    current = Map.get(socket.assigns.scope, :origins, [])

    next =
      if origin in current, do: List.delete(current, origin), else: [origin | current]

    {:noreply,
     push_patch(socket, to: admin_path(socket.assigns.scope, next, socket.assigns.scope.sessions))}
  end

  def handle_event("clear_origins", _params, socket) do
    {:noreply,
     push_patch(socket, to: admin_path(socket.assigns.scope, [], socket.assigns.scope.sessions))}
  end

  # One row, one session — the origin filter is a different control.
  def handle_event("toggle_session", %{"session" => id}, socket) do
    current = Map.get(socket.assigns.scope, :sessions, [])
    id = String.to_integer(id)

    next = if id in current, do: List.delete(current, id), else: [id | current]

    {:noreply,
     push_patch(socket, to: admin_path(socket.assigns.scope, socket.assigns.scope.origins, next))}
  end

  def handle_event("clear_row_filters", _params, socket) do
    {:noreply, push_patch(socket, to: admin_path(socket.assigns.scope, [], []))}
  end

  def handle_event("site_window", %{"window" => window}, socket) do
    window = parse_window(window)

    # Re-queried rather than sorted client-side: the counts themselves are
    # per-window, so a different window is different numbers, not the same ones
    # in a different order.
    {:noreply, socket |> assign(:site_window, window) |> load_sites()}
  end

  defp admin_path(scope, origins, sessions) do
    query =
      [
        {"domain", scope.domain},
        {"project", scope.project},
        {"noip", if(origins == [], do: nil, else: Enum.join(origins, ","))},
        {"nosess", if(sessions == [], do: nil, else: Enum.join(sessions, ","))}
      ]
      |> Enum.reject(&(elem(&1, 1) in [nil, ""]))

    ~p"/admin?#{query}"
  end

  # Hex hashes only; anything else in the parameter is a hand-edited URL and is
  # dropped rather than handed to the database.
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

  defp sessions_param(nil), do: []

  defp sessions_param(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case Integer.parse(String.trim(part)) do
        {id, ""} when id > 0 -> [id]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(200)
  end

  defp sessions_param(_), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp parse_window(value) do
    Enum.find(Admin.windows(), :day, &(to_string(&1) == value))
  end

  # Utilisation over the interval since the last sample, which is exactly the
  # window the reader is looking at rather than an average since boot.
  defp sample_cpu(socket, window_ms) do
    current = Host.cpu_sample()

    case Host.cpu_util(socket.assigns.cpu_sample, current) do
      nil ->
        assign(socket, :cpu_sample, current)

      util ->
        socket
        |> assign(:cpu_sample, current)
        |> assign(:cpu_util, util)
        |> assign(:cpu_window, div(window_ms, 1000))
    end
  end

  defp load_host(socket) do
    socket
    |> assign(:memory, Host.memory())
    |> assign(:load, Host.load_average())
    |> assign(:cpu_count, Host.cpu_count())
  end

  defp load_counters(socket) do
    now = DateTime.utc_now()

    socket
    |> assign(:counters, Admin.counters(socket.assigns.scope, now))
    |> assign(:counters_at, now)
  end

  defp load_live(socket) do
    assign(socket, :live, Admin.active_now(socket.assigns.scope))
  end

  defp load_sites(socket) do
    assign(
      socket,
      :sites,
      Admin.sites(socket.assigns.site_window, DateTime.utc_now(), socket.assigns.scope)
    )
  end

  defp load_detail(socket) do
    now = DateTime.utc_now()

    socket
    |> assign(:detail, Admin.detail(socket.assigns.scope, now))
    |> assign(:detail_at, now)
  end

  # -- template helpers -----------------------------------------------------

  @doc "Thousands separators, because six-figure counts are unreadable without."
  def num(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def num(nil), do: "0"
  def num(value), do: to_string(value)

  @doc "A duration a person can read at a glance, not a millisecond count."
  def duration(nil), do: "—"
  def duration(ms) when ms < 1_000, do: "#{ms}ms"
  def duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  def duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  def duration(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h"
  def duration(ms), do: "#{div(ms, 86_400_000)}d"

  @doc "Relative time, which is what \"is this thing still alive\" needs."
  def ago(nil), do: "never"

  def ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      s when s < 10 -> "just now"
      s when s < 60 -> "#{s}s ago"
      s when s < 3_600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3_600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end

  def ago(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> ago()

  @doc "A window's label, for the buttons and the column headings."
  def window_label(:hour), do: "1h"
  def window_label(:day), do: "24h"
  def window_label(:week), do: "7d"
  def window_label(:month), do: "30d"
  def window_label(:all), do: "All"

  @doc "Bytes as something a person reads, not a digit count."
  def bytes(nil), do: "—"
  def bytes(n) when n < 1024, do: "#{n} B"
  def bytes(n) when n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KB"
  def bytes(n) when n < 1_073_741_824, do: "#{Float.round(n / 1_048_576, 1)} MB"
  def bytes(n), do: "#{Float.round(n / 1_073_741_824, 2)} GB"

  @doc """
  Green, amber or red for a percentage.

  A dashboard that colours everything the same makes the reader do the
  comparing, which is the one job the colour was there to do.
  """
  def level(nil), do: "text-base-content/40"
  def level(pct) when pct >= 90, do: "text-error"
  def level(pct) when pct >= 75, do: "text-warning"
  def level(_pct), do: "text-success"

  def bar_colour(nil), do: "bg-base-300"
  def bar_colour(pct) when pct >= 90, do: "bg-error"
  def bar_colour(pct) when pct >= 75, do: "bg-warning"
  def bar_colour(_pct), do: "bg-success"

  @doc "Bar height as a percentage of the tallest bar in the series."
  def bar_pct(_count, 0), do: 0
  def bar_pct(count, max), do: round(count / max * 100)

  def channel_label(nil), do: "web"
  def channel_label(channel), do: channel
end
