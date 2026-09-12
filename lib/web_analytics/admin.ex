defmodule WebAnalytics.Admin do
  @moduledoc """
  Cross-account queries for the operator's dashboard.

  Everything here deliberately ignores site ownership: this is the view of the
  whole deployment, which is exactly why it sits behind an admin flag that only
  a shell command can grant.

  The functions are split by how expensive they are rather than by subject.
  `counters/0` is cheap enough to run every ten seconds; `detail/0` walks the
  tables properly and is refreshed far less often. Mixing the two would mean
  either stale counters or a sequential scan every ten seconds on a box that is
  also serving the application.
  """

  import Ecto.Query, warn: false

  alias WebAnalytics.Accounts.User
  alias WebAnalytics.Ingest.Collector
  alias WebAnalytics.Repo
  alias WebAnalytics.Sites.Site
  alias WebAnalytics.Tracking.Event
  alias WebAnalytics.Tracking.FormCapture
  alias WebAnalytics.Tracking.Pageview
  alias WebAnalytics.Tracking.Session

  @doc """
  The headline numbers, refreshed on every tick.

  One query per table rather than one join across all of them: the tables have
  no relationship worth joining here, and separate counts let Postgres use the
  index-only paths it already has.
  """
  def counters(now \\ DateTime.utc_now()) do
    day = DateTime.add(now, -24, :hour)
    hour = DateTime.add(now, -1, :hour)
    minute = DateTime.add(now, -1, :minute)

    %{
      users: Repo.aggregate(User, :count),
      users_confirmed: Repo.aggregate(from(u in User, where: not is_nil(u.confirmed_at)), :count),
      sites: Repo.aggregate(Site, :count),
      sites_claimed: Repo.aggregate(from(s in Site, where: not is_nil(s.user_id)), :count),
      sessions: Repo.aggregate(Session, :count),
      pageviews: Repo.aggregate(Pageview, :count),
      events: Repo.aggregate(Event, :count),
      forms: Repo.aggregate(FormCapture, :count),
      sessions_24h: count_since(Session, :started_at, day),
      pageviews_24h: count_since(Pageview, :entered_at, day),
      events_24h: count_since(Event, :occurred_at, day),
      sessions_1h: count_since(Session, :started_at, hour),
      events_1h: count_since(Event, :occurred_at, hour),
      events_1m: count_since(Event, :occurred_at, minute),
      # "Active" is a session seen in the last five minutes, which is the
      # shortest window that does not flicker between ticks.
      active_now:
        Repo.aggregate(
          from(s in Session, where: s.last_seen_at > ^DateTime.add(now, -5, :minute)),
          :count
        ),
      crawler_sessions: Repo.aggregate(from(s in Session, where: s.crawler), :count),
      crawler_sessions_24h:
        Repo.aggregate(
          from(s in Session, where: s.crawler and s.started_at > ^day),
          :count
        ),
      ai_sessions: Repo.aggregate(from(s in Session, where: s.channel == "ai"), :count),
      web_sessions:
        Repo.aggregate(from(s in Session, where: is_nil(s.channel) or s.channel != "ai"), :count),
      anomalous_sessions: Repo.aggregate(from(s in Session, where: s.anomalous), :count),
      queue_depth: queue_depth()
    }
  end

  @doc """
  The tables and breakdowns. Heavier, so refreshed on a slower cadence than the
  counters above.
  """
  def detail(now \\ DateTime.utc_now()) do
    %{
      users: users_with_activity(),
      projects: top_projects(now),
      domains: top_domains(now),
      crawlers: top_crawlers(now),
      countries: top_countries(now),
      channels: sessions_by_channel(now),
      hourly: events_per_hour(now),
      recent_sessions: recent_sessions(),
      top_paths: top_paths(now)
    }
  end

  @doc "Facts about the deployment itself, which change rarely."
  def system do
    %{
      version: Application.spec(:web_analytics, :vsn) |> to_string(),
      elixir: System.version(),
      otp: System.otp_release() |> to_string(),
      uptime_ms: :erlang.statistics(:wall_clock) |> elem(0),
      node: to_string(Node.self()),
      schedulers: System.schedulers_online(),
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      geoip: WebAnalytics.Geo.Database.loaded?(),
      mailer: mailer_adapter(),
      database_size: database_size(),
      table_sizes: table_sizes()
    }
  end

  @windows [:hour, :day, :week, :month, :all]

  @doc "The activity windows the sites table can be ranked over."
  def windows, do: @windows

  @doc """
  Every site, ranked by how busy it has been over `window`.

  Counted with one grouped query per table rather than one join across all
  three: joining sessions, pageviews and events onto sites multiplies the rows
  before it counts them, and the numbers come out as the product of the three
  rather than the three. Four indexed aggregates are both correct and cheaper.
  """
  def sites(window \\ :day, now \\ DateTime.utc_now()) do
    since = window_start(window, now)

    views = counts_by_site(Pageview, :entered_at, since)
    events = counts_by_site(Event, :occurred_at, since)
    sessions = counts_by_site(Session, :started_at, since)
    last_seen = last_seen_by_site()

    Repo.all(
      from s in Site,
        left_join: u in User,
        on: u.id == s.user_id,
        select: %{
          id: s.id,
          key: s.key,
          name: s.name,
          domain: s.domain,
          owner: u.email,
          claimed_at: s.claimed_at,
          inserted_at: s.inserted_at
        }
    )
    |> Enum.map(fn site ->
      site
      |> Map.put(:views, Map.get(views, site.id, 0))
      |> Map.put(:events, Map.get(events, site.id, 0))
      |> Map.put(:sessions, Map.get(sessions, site.id, 0))
      |> Map.put(:last_seen, Map.get(last_seen, site.id))
    end)
    # Views first because that is the question being asked — who is busiest —
    # with events and sessions breaking ties rather than a site with no
    # pageviews sorting arbitrarily among the other empty ones.
    |> Enum.sort_by(&{&1.views, &1.events, &1.sessions}, :desc)
  end

  defp window_start(:all, _now), do: nil
  defp window_start(:hour, now), do: DateTime.add(now, -1, :hour)
  defp window_start(:day, now), do: DateTime.add(now, -24, :hour)
  defp window_start(:week, now), do: DateTime.add(now, -7, :day)
  defp window_start(:month, now), do: DateTime.add(now, -30, :day)
  defp window_start(_other, now), do: window_start(:day, now)

  defp counts_by_site(schema, _field, nil) do
    Repo.all(from r in schema, group_by: r.site_id, select: {r.site_id, count(r.id)})
    |> Map.new()
  end

  defp counts_by_site(schema, field, since) do
    Repo.all(
      from r in schema,
        where: field(r, ^field) > ^since,
        group_by: r.site_id,
        select: {r.site_id, count(r.id)}
    )
    |> Map.new()
  end

  # Always all-time: "last seen" answers whether a site is alive at all, and a
  # windowed version of it would just be the window's edge for everything busy.
  defp last_seen_by_site do
    Repo.all(from s in Session, group_by: s.site_id, select: {s.site_id, max(s.last_seen_at)})
    |> Map.new()
  end

  # -- tables ---------------------------------------------------------------

  defp users_with_activity do
    Repo.all(
      from u in User,
        left_join: s in Site,
        on: s.user_id == u.id,
        group_by: u.id,
        order_by: [desc: u.inserted_at],
        select: %{
          id: u.id,
          email: u.email,
          admin: u.admin,
          confirmed_at: u.confirmed_at,
          inserted_at: u.inserted_at,
          sites: count(s.id)
        }
    )
  end

  defp top_projects(now) do
    since = DateTime.add(now, -30, :day)

    Repo.all(
      from s in Session,
        where: not is_nil(s.project) and s.started_at > ^since,
        group_by: [s.project, s.channel],
        order_by: [desc: count(s.id)],
        limit: 25,
        select: %{
          project: s.project,
          channel: s.channel,
          sessions: count(s.id),
          pageviews: coalesce(sum(s.pageview_count), 0),
          accounts: count(s.site_id, :distinct),
          last_seen: max(s.last_seen_at)
        }
    )
  end

  # Across every account, so the operator can see which domains this deployment
  # is actually carrying rather than which accounts exist.
  defp top_domains(now) do
    since = DateTime.add(now, -30, :day)

    Repo.all(
      from s in Session,
        join: site in Site,
        on: site.id == s.site_id,
        where: not is_nil(s.host) and s.started_at > ^since,
        group_by: s.host,
        order_by: [desc: count(s.id)],
        limit: 25,
        select: %{
          name: s.host,
          sessions: count(s.id),
          pageviews: coalesce(sum(s.pageview_count), 0),
          accounts: count(site.id, :distinct),
          last_seen: max(s.last_seen_at)
        }
    )
  end

  defp top_crawlers(now) do
    since = DateTime.add(now, -30, :day)

    Repo.all(
      from s in Session,
        where: s.crawler and s.started_at > ^since,
        group_by: [s.crawler_name, s.crawler_kind],
        order_by: [desc: count(s.id)],
        limit: 25,
        select: %{
          name: s.crawler_name,
          kind: s.crawler_kind,
          sessions: count(s.id),
          pageviews: sum(s.pageview_count),
          last_seen: max(s.last_seen_at)
        }
    )
  end

  defp top_countries(now) do
    since = DateTime.add(now, -30, :day)

    Repo.all(
      from s in Session,
        where: not is_nil(s.country) and s.started_at > ^since,
        group_by: [s.country, s.country_code],
        order_by: [desc: count(s.id)],
        limit: 15,
        select: %{country: s.country, code: s.country_code, sessions: count(s.id)}
    )
  end

  defp sessions_by_channel(now) do
    since = DateTime.add(now, -30, :day)

    # Older sessions have a null channel and newer ones say "web" outright, so
    # grouping on the raw column yields two rows that both render as "web".
    #
    # The expression is repeated in GROUP BY rather than referenced by an
    # alias: in Postgres a GROUP BY name that matches an input column always
    # means that column, never the output alias, so `selected_as(:channel)`
    # here would silently group by the raw column while displaying the
    # coalesced one — the counts split, and the page looks merged.
    Repo.all(
      from s in Session,
        where: s.started_at > ^since,
        group_by: fragment("coalesce(?, 'web')", s.channel),
        order_by: [desc: count(s.id)],
        select: %{
          channel: fragment("coalesce(?, 'web')", s.channel),
          sessions: count(s.id)
        }
    )
  end

  defp top_paths(now) do
    since = DateTime.add(now, -7, :day)

    Repo.all(
      from p in Pageview,
        join: s in Site,
        on: s.id == p.site_id,
        where: p.entered_at > ^since,
        group_by: [p.path, s.name],
        order_by: [desc: count(p.id)],
        limit: 20,
        select: %{path: p.path, site: s.name, views: count(p.id)}
    )
  end

  defp recent_sessions do
    Repo.all(
      from s in Session,
        join: site in Site,
        on: site.id == s.site_id,
        order_by: [desc: s.last_seen_at],
        limit: 25,
        select: %{
          site: site.name,
          channel: s.channel,
          project: s.project,
          crawler_name: s.crawler_name,
          country: s.country,
          city: s.city,
          entry_path: s.entry_path,
          pageviews: s.pageview_count,
          dwell_ms: s.dwell_ms,
          anomalous: s.anomalous,
          last_seen_at: s.last_seen_at
        }
    )
  end

  # Bucketed in SQL rather than in Elixir: pulling 24 hours of rows back to count
  # them here would be the most expensive query on the page by a wide margin.
  defp events_per_hour(now) do
    since = DateTime.add(now, -24, :hour)

    rows =
      Repo.all(
        from e in Event,
          where: e.occurred_at > ^since,
          group_by: selected_as(:bucket),
          order_by: selected_as(:bucket),
          select: %{
            bucket: selected_as(fragment("date_trunc('hour', ?)", e.occurred_at), :bucket),
            count: count(e.id)
          }
      )
      |> Map.new(fn %{bucket: bucket, count: count} -> {unix(bucket), count} end)

    # Every hour present, including the empty ones, so the chart shows a gap as a
    # gap rather than closing over it.
    start = now |> DateTime.add(-23, :hour) |> truncate_hour()

    for offset <- 0..23 do
      at = DateTime.add(start, offset, :hour)
      %{at: at, count: Map.get(rows, unix(at), 0)}
    end
  end

  # date_trunc comes back without a time zone, so Postgres hands Ecto a
  # NaiveDateTime for the bucket while the range we build here is a DateTime.
  # Both are UTC; this is the one place that has to know it.
  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)

  defp unix(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  # -- system ---------------------------------------------------------------

  defp database_size do
    case Repo.query("SELECT pg_size_pretty(pg_database_size(current_database()))") do
      {:ok, %{rows: [[size]]}} -> size
      _ -> "unknown"
    end
  end

  defp table_sizes do
    query = """
    SELECT relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid))
    FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(relid) DESC
    LIMIT 12
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, rows_estimate, size] ->
          %{name: name, rows: rows_estimate, size: size}
        end)

      _ ->
        []
    end
  end

  defp mailer_adapter do
    case Application.get_env(:web_analytics, WebAnalytics.Mailer)[:adapter] do
      nil -> "not configured"
      adapter -> adapter |> Module.split() |> List.last()
    end
  end

  # The collector is a GenServer, and a dashboard must never be the reason the
  # ingest path stalls. If it is busy enough not to answer promptly, that is
  # itself the interesting answer.
  defp queue_depth do
    Collector.queue_size()
  catch
    :exit, _ -> :unavailable
  end

  # -- helpers --------------------------------------------------------------

  defp count_since(schema, field, since) do
    Repo.aggregate(from(r in schema, where: field(r, ^field) > ^since), :count)
  end

  defp truncate_hour(datetime) do
    %{datetime | minute: 0, second: 0, microsecond: {0, 0}}
  end
end
