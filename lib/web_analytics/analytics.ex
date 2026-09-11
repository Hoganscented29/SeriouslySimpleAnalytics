defmodule WebAnalytics.Analytics do
  @moduledoc """
  Read side of the dashboard.

  Every query runs through the same scope builders, so the anomaly filter is
  applied identically to sessions, pageviews, clicks and forms. That matters:
  a filter that reached some panels and not others would produce a dashboard
  whose totals silently disagree with each other.
  """

  import Ecto.Query

  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Event
  alias WebAnalytics.Tracking.FormCapture
  alias WebAnalytics.Tracking.Pageview
  alias WebAnalytics.Tracking.Session

  @ranges %{
    "1h" => 3_600,
    "24h" => 86_400,
    "7d" => 604_800,
    "30d" => 2_592_000,
    "all" => nil
  }

  @doc "Known range keys, in display order."
  def ranges, do: ["1h", "24h", "7d", "30d", "all"]

  @doc """
  Builds the filter map every query in this module takes.

  `exclude_anomalies` defaults to true — the point of the classifier is that
  reports are clean by default — and the dashboard exposes it as a toggle.
  """
  def filters(site_id, opts \\ %{}) do
    range = Map.get(opts, :range, "7d")
    now = DateTime.utc_now()

    from =
      case Map.get(@ranges, range) do
        nil -> ~U[1970-01-01 00:00:00.000000Z]
        seconds -> DateTime.add(now, -seconds, :second)
      end

    %{
      site_id: site_id,
      range: range,
      from: from,
      to: DateTime.add(now, 60, :second),
      exclude_anomalies: Map.get(opts, :exclude_anomalies, true),
      # Crawlers are filtered on their own axis, so a reader can look at bot
      # traffic without also un-hiding genuinely broken sessions.
      exclude_crawlers: Map.get(opts, :exclude_crawlers, true),
      # One account can instrument several things; nil means "all of them".
      project: Map.get(opts, :project),
      group_by: Map.get(opts, :group_by, :path)
    }
  end

  # -- scopes --------------------------------------------------------------

  defp sessions_scope(f) do
    from(s in Session,
      where: s.site_id == ^f.site_id,
      where: s.started_at >= ^f.from and s.started_at < ^f.to
    )
    |> filter_anomalies(f)
    |> filter_crawlers(f)
    |> filter_project(f)
  end

  defp filter_project(query, %{project: project}) when is_binary(project),
    do: where(query, [s], s.project == ^project)

  defp filter_project(query, _f), do: query

  defp filter_joined_project(query, %{project: project}) when is_binary(project),
    do: where(query, [session: s], s.project == ^project)

  defp filter_joined_project(query, _f), do: query

  defp filter_anomalies(query, %{exclude_anomalies: true}),
    do: where(query, [s], not s.anomalous)

  defp filter_anomalies(query, _f), do: query

  # Crawler filtering is a *web* analytics concern: a bot fetching your pages is
  # noise in a report about your visitors. It must never touch other channels —
  # an AI tool's own telemetry is the data, not noise in front of it, and a tool
  # that honestly declared itself automated would otherwise disappear from the
  # very report it exists to populate.
  defp filter_crawlers(query, %{exclude_crawlers: true}),
    do: where(query, [s], not (s.crawler and coalesce(s.channel, "web") == "web"))

  defp filter_crawlers(query, _f), do: query

  defp filter_joined_anomalies(query, %{exclude_anomalies: true}),
    do: where(query, [session: s], not s.anomalous)

  defp filter_joined_anomalies(query, _f), do: query

  defp filter_joined_crawlers(query, %{exclude_crawlers: true}),
    do: where(query, [session: s], not (s.crawler and coalesce(s.channel, "web") == "web"))

  defp filter_joined_crawlers(query, _f), do: query

  defp pageviews_scope(f) do
    from(p in Pageview,
      join: s in assoc(p, :session),
      as: :session,
      where: p.site_id == ^f.site_id,
      where: p.entered_at >= ^f.from and p.entered_at < ^f.to
    )
    |> filter_joined_anomalies(f)
    |> filter_joined_crawlers(f)
    |> filter_joined_project(f)
  end

  defp events_scope(f) do
    from(e in Event,
      join: s in assoc(e, :session),
      as: :session,
      where: e.site_id == ^f.site_id,
      where: e.occurred_at >= ^f.from and e.occurred_at < ^f.to
    )
    |> filter_joined_anomalies(f)
    |> filter_joined_crawlers(f)
    |> filter_joined_project(f)
  end

  defp forms_scope(f) do
    from(c in FormCapture,
      join: s in assoc(c, :session),
      as: :session,
      where: c.site_id == ^f.site_id,
      where: c.occurred_at >= ^f.from and c.occurred_at < ^f.to
    )
    |> filter_joined_anomalies(f)
    |> filter_joined_crawlers(f)
    |> filter_joined_project(f)
  end

  # -- overview ------------------------------------------------------------

  @doc "Headline numbers for the selected range and filter state."
  def overview(f) do
    totals =
      Repo.one(
        from s in sessions_scope(f),
          select: %{
            sessions: count(s.id),
            visitors: count(s.visitor_token, :distinct),
            pageviews: coalesce(sum(s.pageview_count), 0),
            clicks: coalesce(sum(s.click_count), 0),
            outbound: coalesce(sum(s.outbound_count), 0),
            forms: coalesce(sum(s.form_count), 0),
            dwell_ms: avg(s.dwell_ms),
            active_ms: avg(s.active_ms),
            max_scroll: avg(s.max_scroll_pct),
            bounces: filter(count(s.id), s.pageview_count <= 1)
          }
      ) || %{}

    # Counted without either filter applied, so each toggle can say exactly how
    # much traffic it is holding back.
    hidden =
      Repo.one(
        from s in Session,
          where: s.site_id == ^f.site_id,
          where: s.started_at >= ^f.from and s.started_at < ^f.to,
          select: %{
            anomalous: filter(count(s.id), s.anomalous and not s.crawler),
            crawlers: filter(count(s.id), s.crawler and coalesce(s.channel, "web") == "web")
          }
      ) || %{anomalous: 0, crawlers: 0}

    sessions = Map.get(totals, :sessions, 0)

    totals
    |> Map.put(:excluded_sessions, hidden.anomalous)
    |> Map.put(:crawler_sessions, hidden.crawlers)
    |> Map.put(:bounce_rate, rate(Map.get(totals, :bounces, 0), sessions))
    |> Map.put(:dwell_ms, to_number(Map.get(totals, :dwell_ms)))
    |> Map.put(:active_ms, to_number(Map.get(totals, :active_ms)))
    |> Map.put(:max_scroll, to_number(Map.get(totals, :max_scroll)))
  end

  @doc "Session counts bucketed over time, for the trend chart."
  def timeseries(f, buckets \\ 24) do
    seconds = max(DateTime.diff(f.to, f.from), 60)
    width = max(div(seconds, buckets), 60)

    # Grouped by the select alias rather than a repeated fragment: Ecto emits
    # fresh bind parameters for each copy of an expression, and Postgres then
    # refuses to match the GROUP BY against the SELECT.
    Repo.all(
      from s in sessions_scope(f),
        select: %{
          at:
            selected_as(
              fragment(
                "to_timestamp(floor(extract(epoch from ?) / ?) * ?)",
                s.started_at,
                ^width,
                ^width
              ),
              :at
            ),
          sessions: count(s.id),
          pageviews: coalesce(sum(s.pageview_count), 0)
        },
        group_by: selected_as(:at),
        order_by: selected_as(:at)
    )
  end

  # -- pages ---------------------------------------------------------------

  @doc """
  Per-page metrics, grouped by path or title depending on `group_by`.

  Grouping by title answers "which content did people read"; grouping by path
  answers "which URL did they hit". They diverge as soon as one template serves
  many URLs, which is why both are offered rather than one being picked here.
  """
  def pages(f, limit \\ 50) do
    key = group_field(f)

    Repo.all(
      from p in pageviews_scope(f),
        where: not is_nil(field(p, ^key)),
        group_by: field(p, ^key),
        order_by: [desc: count(p.id)],
        limit: ^limit,
        select: %{
          name: field(p, ^key),
          views: count(p.id),
          sessions: count(p.session_id, :distinct),
          dwell_ms: avg(p.dwell_ms),
          active_ms: avg(p.active_ms),
          max_scroll: avg(p.max_scroll_pct),
          clicks: coalesce(sum(p.click_count), 0),
          entrances: filter(count(p.id), p.entrance),
          exits: filter(count(p.id), p.exit)
        }
    )
    |> Enum.map(fn row ->
      row
      |> Map.update!(:dwell_ms, &to_number/1)
      |> Map.update!(:active_ms, &to_number/1)
      |> Map.update!(:max_scroll, &to_number/1)
      |> Map.put(:exit_rate, rate(row.exits, row.views))
    end)
  end

  @doc "Scroll-depth distribution across pageviews, in ten buckets."
  def scroll_distribution(f) do
    rows =
      Repo.all(
        from p in pageviews_scope(f),
          group_by: fragment("LEAST(?/10, 9)", p.max_scroll_pct),
          order_by: fragment("LEAST(?/10, 9)", p.max_scroll_pct),
          select: %{bucket: fragment("LEAST(?/10, 9)", p.max_scroll_pct), count: count(p.id)}
      )
      |> Map.new(fn row -> {row.bucket, row.count} end)

    Enum.map(0..9, fn bucket ->
      %{from: bucket * 10, to: bucket * 10 + 9, count: Map.get(rows, bucket, 0)}
    end)
  end

  # -- flow ----------------------------------------------------------------

  @doc """
  Page-to-page transitions.

  Each pageview row already carries the hop that produced it, so the whole
  graph is one grouped scan rather than a self join over ordered sessions.
  """
  def flow(f, limit \\ 25) do
    {from_key, to_key} = flow_fields(f)

    Repo.all(
      from p in pageviews_scope(f),
        where: not is_nil(field(p, ^from_key)) and not is_nil(field(p, ^to_key)),
        group_by: [field(p, ^from_key), field(p, ^to_key)],
        order_by: [desc: count(p.id)],
        limit: ^limit,
        select: %{
          from: field(p, ^from_key),
          to: field(p, ^to_key),
          count: count(p.id),
          sessions: count(p.session_id, :distinct)
        }
    )
  end

  @doc "Entry pages — where sessions begin."
  def entries(f, limit \\ 10) do
    key = group_field(f)

    Repo.all(
      from p in pageviews_scope(f),
        where: p.entrance and not is_nil(field(p, ^key)),
        group_by: field(p, ^key),
        order_by: [desc: count(p.id)],
        limit: ^limit,
        select: %{name: field(p, ^key), count: count(p.id)}
    )
  end

  @doc "Exit pages — where sessions end."
  def exits(f, limit \\ 10) do
    key = group_field(f)

    Repo.all(
      from p in pageviews_scope(f),
        where: p.exit and not is_nil(field(p, ^key)),
        group_by: field(p, ^key),
        order_by: [desc: count(p.id)],
        limit: ^limit,
        select: %{name: field(p, ^key), count: count(p.id)}
    )
  end

  @doc """
  What came immediately before and after a given page.

  The navigation summary for one node, which is usually the question behind
  "show me the flow" — the full graph is too dense to read at a glance.
  """
  def navigation_summary(f, page, limit \\ 8) do
    {from_key, to_key} = flow_fields(f)

    before =
      Repo.all(
        from p in pageviews_scope(f),
          where: field(p, ^to_key) == ^page and not is_nil(field(p, ^from_key)),
          group_by: field(p, ^from_key),
          order_by: [desc: count(p.id)],
          limit: ^limit,
          select: %{name: field(p, ^from_key), count: count(p.id)}
      )

    next =
      Repo.all(
        from p in pageviews_scope(f),
          where: field(p, ^to_key) == ^page and not is_nil(field(p, ^next_field(f))),
          group_by: field(p, ^next_field(f)),
          order_by: [desc: count(p.id)],
          limit: ^limit,
          select: %{name: field(p, ^next_field(f)), count: count(p.id)}
      )

    totals =
      Repo.one(
        from p in pageviews_scope(f),
          where: field(p, ^to_key) == ^page,
          select: %{
            views: count(p.id),
            entrances: filter(count(p.id), p.entrance),
            exits: filter(count(p.id), p.exit)
          }
      ) || %{views: 0, entrances: 0, exits: 0}

    # A diagram drawn from the top N alone would silently misrepresent the flow:
    # the ribbons would not add up to the page's traffic. These remainders are
    # what is left over, so the picture stays honest about the long tail.
    inbound_total = totals.views - totals.entrances
    outbound_total = totals.views - totals.exits

    %{
      page: page,
      before: before,
      next: next,
      before_other: max(inbound_total - sum_counts(before), 0),
      next_other: max(outbound_total - sum_counts(next), 0),
      totals: totals
    }
  end

  defp sum_counts(rows), do: rows |> Enum.map(& &1.count) |> Enum.sum()

  defp group_field(%{group_by: :title}), do: :title
  defp group_field(_), do: :path

  defp flow_fields(%{group_by: :title}), do: {:from_title, :title}
  defp flow_fields(_), do: {:from_path, :path}

  defp next_field(%{group_by: :title}), do: :to_title
  defp next_field(_), do: :to_path

  # -- clicks --------------------------------------------------------------

  @doc """
  Clicks grouped by element identity.

  `:id` and `:class` are the two that make auto-captured clicks usable without
  any tagging work — most design systems already name their interactive
  elements, so grouping on those names recovers the intent behind the click.
  """
  def clicks(f, group, limit \\ 25)

  def clicks(f, :class, limit) do
    Repo.all(
      from e in events_scope(f),
        cross_join: c in fragment("unnest(?)", e.classes),
        where: e.type != "custom",
        group_by: fragment("?", c),
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          name: fragment("?", c),
          count: count(e.id),
          sessions: count(e.session_id, :distinct),
          outbound: filter(count(e.id), e.outbound)
        }
    )
  end

  def clicks(f, group, limit) do
    key =
      case group do
        :name -> :name
        :id -> :el_id
        :text -> :text
        :selector -> :selector
        :tag -> :tag
        _ -> :el_id
      end

    Repo.all(
      from e in events_scope(f),
        where: not is_nil(field(e, ^key)),
        group_by: field(e, ^key),
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          name: field(e, ^key),
          count: count(e.id),
          sessions: count(e.session_id, :distinct),
          outbound: filter(count(e.id), e.outbound)
        }
    )
  end

  @doc "Off-site destinations, grouped by host and target."
  def outbound_links(f, limit \\ 25) do
    Repo.all(
      from e in events_scope(f),
        where: e.outbound and not is_nil(e.href),
        group_by: [e.href_host, e.href],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          host: e.href_host,
          href: e.href,
          count: count(e.id),
          sessions: count(e.session_id, :distinct),
          mousedown: filter(count(e.id), e.trigger == "mousedown")
        }
    )
  end

  @doc "Breakdown of captured click types."
  def click_types(f) do
    Repo.all(
      from e in events_scope(f),
        group_by: e.type,
        order_by: [desc: count(e.id)],
        select: %{name: e.type, count: count(e.id)}
    )
  end

  # -- forms ---------------------------------------------------------------

  @doc "Per-form submit and abandon counts."
  def form_summary(f, limit \\ 25) do
    Repo.all(
      from c in forms_scope(f),
        group_by: [c.form_id, c.form_selector, c.path],
        order_by: [desc: count(c.id)],
        limit: ^limit,
        select: %{
          form_id: c.form_id,
          selector: c.form_selector,
          path: c.path,
          total: count(c.id),
          submitted: filter(count(c.id), c.status == "submitted"),
          abandoned: filter(count(c.id), c.status == "abandoned"),
          avg_fill: avg(c.filled_count),
          avg_fields: avg(c.field_count),
          avg_duration: avg(c.duration_ms)
        }
    )
    |> Enum.map(fn row ->
      row
      |> Map.update!(:avg_fill, &to_number/1)
      |> Map.update!(:avg_fields, &to_number/1)
      |> Map.update!(:avg_duration, &to_number/1)
      |> Map.put(:completion_rate, rate(row.submitted, row.total))
    end)
  end

  @doc "Most recent form captures, newest first."
  def recent_forms(f, limit \\ 25) do
    Repo.all(
      from c in forms_scope(f),
        order_by: [desc: c.occurred_at],
        limit: ^limit,
        preload: [session: []]
    )
  end

  def get_form_capture(id), do: Repo.get(FormCapture, id) |> Repo.preload(:session)

  # -- sessions ------------------------------------------------------------

  @doc "Recent sessions. Ignores the anomaly filter so the toggle can reveal them."
  def recent_sessions(f, limit \\ 40) do
    query =
      from s in Session,
        where: s.site_id == ^f.site_id,
        where: s.started_at >= ^f.from and s.started_at < ^f.to,
        order_by: [desc: s.last_seen_at],
        limit: ^limit

    query = query |> filter_anomalies(f) |> filter_crawlers(f)
    Repo.all(query)
  end

  @doc "How many sessions each anomaly reason accounts for."
  def anomaly_breakdown(f) do
    Repo.all(
      from s in Session,
        cross_join: r in fragment("unnest(?)", s.anomaly_reasons),
        where: s.site_id == ^f.site_id,
        where: s.started_at >= ^f.from and s.started_at < ^f.to,
        where: not s.crawler,
        where: coalesce(s.channel, "web") == "web",
        group_by: fragment("?", r),
        order_by: [desc: count(s.id)],
        select: %{reason: fragment("?", r), count: count(s.id)}
    )
  end

  # Dwell spans milliseconds to hours, so the buckets are deliberately uneven.
  # Nothing below five seconds is subdivided: the difference between a 200ms and
  # a 2s visit is noise — neither one read anything — and splitting them apart
  # only produces tall bars at the left that crowd out the range where real
  # reading time actually varies.
  @dwell_buckets [
    {5_000, "0-5s"},
    {10_000, "5-10s"},
    {60_000, "10s-1m"},
    {120_000, "1-2m"},
    {300_000, "2-5m"},
    {900_000, "5-15m"},
    {1_800_000, "15-30m"},
    {3_600_000, "30m-1h"},
    {:infinity, "1h+"}
  ]

  @doc """
  Dwell-time histogram.

  Returned for both kept and filtered sessions, so the anomaly toggle can show
  what the filter removed rather than just asserting that it removed something.
  """
  def dwell_distribution(f) do
    thresholds =
      @dwell_buckets
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(&1 == :infinity))

    rows =
      Repo.all(
        from s in Session,
          where: s.site_id == ^f.site_id,
          where: s.started_at >= ^f.from and s.started_at < ^f.to,
          group_by: [
            selected_as(:bucket),
            s.anomalous
          ],
          select: %{
            bucket:
              selected_as(
                fragment("width_bucket(?, ?)", s.dwell_ms, type(^thresholds, {:array, :integer})),
                :bucket
              ),
            anomalous: s.anomalous,
            count: count(s.id)
          }
      )

    @dwell_buckets
    |> Enum.with_index()
    |> Enum.map(fn {{_ceiling, label}, index} ->
      %{
        bucket: index,
        label: label,
        kept: sum_where(rows, index, false),
        filtered: sum_where(rows, index, true)
      }
    end)
  end

  defp sum_where(rows, bucket, anomalous) do
    rows
    |> Enum.filter(&(&1.bucket == bucket and &1.anomalous == anomalous))
    |> Enum.reduce(0, &(&1.count + &2))
  end

  # -- projects ------------------------------------------------------------

  @doc """
  Projects seen for a site, newest activity first.

  Ignores the project filter, since it exists to populate the control that sets
  it.
  """
  def projects(f) do
    Repo.all(
      from s in Session,
        where: s.site_id == ^f.site_id,
        where: s.started_at >= ^f.from and s.started_at < ^f.to,
        where: not is_nil(s.project),
        group_by: [s.project, s.channel],
        order_by: [desc: max(s.last_seen_at)],
        select: %{
          name: s.project,
          channel: s.channel,
          count: count(s.id),
          last_seen: max(s.last_seen_at)
        }
    )
  end

  @doc "Traffic split by channel — the browser tracker, AI tools, anything else."
  def channels(f) do
    Repo.all(
      from s in sessions_scope(f),
        group_by: s.channel,
        order_by: [desc: count(s.id)],
        select: %{name: coalesce(s.channel, "web"), count: count(s.id)}
    )
  end

  # -- locations -----------------------------------------------------------

  @doc """
  Visitor locations, grouped at country, region or city level.

  Region means whatever the country's first-level division is — a state in the
  US, a province in Canada, a county elsewhere. Rows with no resolved value at
  the requested level are excluded rather than lumped into an "unknown" bucket;
  `geo_coverage/1` reports how much traffic that leaves out, which is the honest
  place for it.
  """
  def locations(f, level \\ :country, limit \\ 25)

  def locations(f, :country, limit) do
    Repo.all(
      from s in sessions_scope(f),
        where: not is_nil(s.country_code),
        group_by: [s.country_code, s.country],
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{
          country_code: s.country_code,
          country: s.country,
          region: nil,
          city: nil,
          count: count(s.id),
          visitors: count(s.visitor_token, :distinct),
          pageviews: coalesce(sum(s.pageview_count), 0),
          dwell_ms: avg(s.dwell_ms),
          bounces: filter(count(s.id), s.pageview_count <= 1)
        }
    )
    |> finish_locations()
  end

  def locations(f, :region, limit) do
    Repo.all(
      from s in sessions_scope(f),
        where: not is_nil(s.region),
        group_by: [s.country_code, s.country, s.region],
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{
          country_code: s.country_code,
          country: s.country,
          region: s.region,
          city: nil,
          count: count(s.id),
          visitors: count(s.visitor_token, :distinct),
          pageviews: coalesce(sum(s.pageview_count), 0),
          dwell_ms: avg(s.dwell_ms),
          bounces: filter(count(s.id), s.pageview_count <= 1)
        }
    )
    |> finish_locations()
  end

  def locations(f, :county, limit) do
    Repo.all(
      from s in sessions_scope(f),
        where: not is_nil(s.county),
        group_by: [s.country_code, s.country, s.region, s.county],
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{
          country_code: s.country_code,
          country: s.country,
          region: s.region,
          county: s.county,
          city: nil,
          count: count(s.id),
          visitors: count(s.visitor_token, :distinct),
          pageviews: coalesce(sum(s.pageview_count), 0),
          dwell_ms: avg(s.dwell_ms),
          bounces: filter(count(s.id), s.pageview_count <= 1)
        }
    )
    |> finish_locations()
  end

  def locations(f, :city, limit) do
    Repo.all(
      from s in sessions_scope(f),
        where: not is_nil(s.city),
        group_by: [s.country_code, s.country, s.region, s.county, s.city],
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{
          country_code: s.country_code,
          country: s.country,
          region: s.region,
          county: s.county,
          city: s.city,
          count: count(s.id),
          visitors: count(s.visitor_token, :distinct),
          pageviews: coalesce(sum(s.pageview_count), 0),
          dwell_ms: avg(s.dwell_ms),
          bounces: filter(count(s.id), s.pageview_count <= 1)
        }
    )
    |> finish_locations()
  end

  defp finish_locations(rows) do
    Enum.map(rows, fn row ->
      row
      |> Map.update!(:dwell_ms, &to_number/1)
      |> Map.put(:bounce_rate, rate(row.bounces, row.count))
      |> Map.put(:label, location_label(row))
    end)
  end

  # County sits between city and state, and is only ever present when a caller
  # supplied it, so it is shown but never required to form a label.
  defp location_label(%{city: city} = row) when is_binary(city) do
    join_parts([city, row[:county], row[:region], row[:country]])
  end

  defp location_label(%{county: county} = row) when is_binary(county) do
    join_parts([county, row[:region], row[:country]])
  end

  defp location_label(%{region: region} = row) when is_binary(region) do
    join_parts([region, row[:country]])
  end

  defp location_label(%{country: country, country_code: code}), do: country || code

  defp join_parts(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(", ")

  @doc """
  How much traffic could actually be placed, and by which resolver.

  Worth showing plainly: a country-level guess from a time zone is a different
  thing from a city-level fix, and a dashboard that presented them identically
  would be overstating what it knows.
  """
  def geo_coverage(f) do
    totals =
      Repo.one(
        from s in sessions_scope(f),
          select: %{
            sessions: count(s.id),
            located: filter(count(s.id), not is_nil(s.country_code)),
            with_region: filter(count(s.id), not is_nil(s.region)),
            with_county: filter(count(s.id), not is_nil(s.county)),
            with_city: filter(count(s.id), not is_nil(s.city))
          }
      ) || %{sessions: 0, located: 0, with_region: 0, with_county: 0, with_city: 0}

    by_source =
      Repo.all(
        from s in sessions_scope(f),
          where: not is_nil(s.geo_source),
          group_by: s.geo_source,
          order_by: [desc: count(s.id)],
          select: %{name: s.geo_source, count: count(s.id)}
      )

    totals
    |> Map.put(:sources, by_source)
    |> Map.put(:country_rate, rate(totals.located, totals.sessions))
    |> Map.put(:region_rate, rate(totals.with_region, totals.sessions))
    |> Map.put(:county_rate, rate(totals.with_county, totals.sessions))
    |> Map.put(:city_rate, rate(totals.with_city, totals.sessions))
  end

  @doc "Coordinates for plotting, one point per city with a fix."
  def location_points(f, limit \\ 400) do
    Repo.all(
      from s in sessions_scope(f),
        where: not is_nil(s.latitude) and not is_nil(s.longitude),
        group_by: [s.latitude, s.longitude, s.city, s.country_code],
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{
          latitude: s.latitude,
          longitude: s.longitude,
          city: s.city,
          country_code: s.country_code,
          count: count(s.id)
        }
    )
  end

  # -- crawlers ------------------------------------------------------------

  # Crawler reporting deliberately ignores `exclude_crawlers` — these queries
  # exist to look *at* the traffic the filter removes, so honouring the filter
  # would always return nothing.
  defp crawlers_scope(f) do
    from s in Session,
      where: s.site_id == ^f.site_id,
      where: s.started_at >= ^f.from and s.started_at < ^f.to,
      where: s.crawler,
      where: coalesce(s.channel, "web") == "web"
  end

  @doc "Headline numbers for automated traffic."
  def crawler_overview(f) do
    totals =
      Repo.one(
        from s in crawlers_scope(f),
          select: %{
            sessions: count(s.id),
            pageviews: coalesce(sum(s.pageview_count), 0),
            distinct_bots: count(s.crawler_name, :distinct),
            dwell_ms: avg(s.dwell_ms),
            ticks: coalesce(sum(s.tick_count), 0)
          }
      ) || %{}

    human =
      Repo.one(
        from s in Session,
          where: s.site_id == ^f.site_id,
          where: s.started_at >= ^f.from and s.started_at < ^f.to,
          where: not s.crawler,
          where: coalesce(s.channel, "web") == "web",
          select: count(s.id)
      ) || 0

    crawler_sessions = Map.get(totals, :sessions, 0)

    totals
    |> Map.put(:dwell_ms, to_number(Map.get(totals, :dwell_ms)))
    |> Map.put(:human_sessions, human)
    |> Map.put(:share, rate(crawler_sessions, crawler_sessions + human))
  end

  @doc "Crawler sessions grouped by the bot that made them."
  def crawlers_by_name(f, limit \\ 25) do
    Repo.all(
      from s in crawlers_scope(f),
        group_by: [s.crawler_name, s.crawler_kind],
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{
          name: s.crawler_name,
          kind: s.crawler_kind,
          count: count(s.id),
          pageviews: coalesce(sum(s.pageview_count), 0),
          dwell_ms: avg(s.dwell_ms),
          last_seen: max(s.last_seen_at)
        }
    )
    |> Enum.map(&Map.update!(&1, :dwell_ms, fn value -> to_number(value) end))
  end

  @doc "Crawler sessions grouped by kind — AI, search, preview, and so on."
  def crawlers_by_kind(f) do
    Repo.all(
      from s in crawlers_scope(f),
        group_by: s.crawler_kind,
        order_by: [desc: count(s.id)],
        select: %{name: s.crawler_kind, count: count(s.id)}
    )
  end

  @doc "Which pages automated traffic actually fetches."
  def crawler_pages(f, limit \\ 15) do
    key = group_field(f)

    Repo.all(
      from p in Pageview,
        join: s in assoc(p, :session),
        where: p.site_id == ^f.site_id,
        where: p.entered_at >= ^f.from and p.entered_at < ^f.to,
        where: s.crawler,
        where: not is_nil(field(p, ^key)),
        group_by: field(p, ^key),
        order_by: [desc: count(p.id)],
        limit: ^limit,
        select: %{name: field(p, ^key), count: count(p.id)}
    )
  end

  @doc "Most recent crawler visits."
  def recent_crawlers(f, limit \\ 40) do
    Repo.all(
      from s in crawlers_scope(f),
        order_by: [desc: s.last_seen_at],
        limit: ^limit
    )
  end

  # -- breakdowns ----------------------------------------------------------

  @doc "Top values of a session dimension, e.g. `:browser` or `:referrer_host`."
  def session_breakdown(f, field, limit \\ 10) do
    Repo.all(
      from s in sessions_scope(f),
        where: not is_nil(field(s, ^field)),
        group_by: field(s, ^field),
        order_by: [desc: count(s.id)],
        limit: ^limit,
        select: %{name: field(s, ^field), count: count(s.id)}
    )
  end

  # -- helpers -------------------------------------------------------------

  defp rate(_part, 0), do: 0.0
  defp rate(_part, nil), do: 0.0
  defp rate(part, total), do: Float.round(part * 100 / total, 1)

  defp to_number(nil), do: 0
  defp to_number(%Decimal{} = value), do: value |> Decimal.to_float() |> round()
  defp to_number(value) when is_float(value), do: round(value)
  defp to_number(value), do: value
end
