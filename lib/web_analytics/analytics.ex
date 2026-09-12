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
      # And one tag can be deployed on several hostnames. Same rule: nil is all.
      host: Map.get(opts, :host),
      group_by: Map.get(opts, :group_by, :path),
      # Origins to leave out. Hashes, not addresses — see origins/2.
      exclude_origins: opts |> Map.get(:exclude_origins, []) |> List.wrap() |> Enum.uniq(),
      # Individual sessions struck out by hand, from the row checkboxes. Cast
      # here, once, because these arrive from a query string and the column is
      # a bigint: a string in this list is a database error, not a filter.
      exclude_sessions:
        opts |> Map.get(:exclude_sessions, []) |> List.wrap() |> Enum.flat_map(&session_id/1)
    }
    |> put_dwell_range(opts)
  end

  # The dwell range is carried as bucket indices rather than raw milliseconds,
  # because those are what the reader is actually moving. Dwell spans
  # milliseconds to hours, so a linear slider over the raw value would spend
  # nine tenths of its travel on "over an hour" and leave every real visit
  # crushed against the left stop. The buckets are already uneven for the same
  # reason, and a notch per bucket lines the slider up with the chart above it.
  defp put_dwell_range(f, opts) do
    last = length(@dwell_buckets) - 1

    min = opts |> Map.get(:dwell_min, 0) |> clamp_bucket(0, last)
    max = opts |> Map.get(:dwell_max, last) |> clamp_bucket(0, last)

    # A reader who drags the low handle past the high one means a range, not an
    # empty set, so the two swap rather than cancelling each other out.
    {min, max} = if min <= max, do: {min, max}, else: {max, min}

    f
    |> Map.put(:dwell_min, min)
    |> Map.put(:dwell_max, max)
    |> Map.put(:dwell_from_ms, bucket_floor(min))
    |> Map.put(:dwell_to_ms, bucket_ceiling(max))
  end

  defp session_id(id) when is_integer(id) and id > 0, do: [id]

  defp session_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> [parsed]
      _ -> []
    end
  end

  defp session_id(_), do: []

  defp clamp_bucket(value, low, high) when is_integer(value),
    do: value |> max(low) |> min(high)

  defp clamp_bucket(value, low, high) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> clamp_bucket(parsed, low, high)
      :error -> low
    end
  end

  defp clamp_bucket(_value, low, _high), do: low

  # The floor of a bucket is the ceiling of the one before it; the first starts
  # at zero.
  defp bucket_floor(0), do: 0

  defp bucket_floor(index) do
    @dwell_buckets |> Enum.at(index - 1) |> elem(0)
  end

  defp bucket_ceiling(index) do
    case @dwell_buckets |> Enum.at(index) |> elem(0) do
      :infinity -> nil
      ceiling -> ceiling
    end
  end

  @doc """
  The dwell buckets, as the slider and the chart above it both need them.

  One list so the two cannot disagree about how many notches there are or what
  each one means.
  """
  def dwell_bucket_labels do
    @dwell_buckets |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The selected session-length range, as one span rather than two bucket names.

  The handles sit on buckets, and every bucket is itself a range, so naming the
  two of them produced "0-5s – 30m-1h" — four numbers for a two-number idea,
  and the two in the middle are edges of buckets nobody asked about. What the
  reader chose is the outside edges: "0–1h".
  """
  def dwell_range_label(%{dwell_min: min, dwell_max: max}) do
    last = length(@dwell_buckets) - 1

    cond do
      min == 0 and max == last -> "Any length"
      # The top bucket has no ceiling, so a range ending there is open-ended
      # and "5m–1h+" would be claiming a bound that does not exist.
      max == last -> dwell_edge(bucket_floor(min)) <> "+"
      true -> dwell_edge(bucket_floor(min)) <> "–" <> dwell_edge(bucket_ceiling(max))
    end
  end

  def dwell_range_label(_f), do: "Any length"

  defp dwell_edge(0), do: "0"
  defp dwell_edge(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"
  defp dwell_edge(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp dwell_edge(ms), do: "#{div(ms, 3_600_000)}h"

  @doc "Whether a dwell range is narrower than everything."
  def dwell_filtered?(%{dwell_min: min, dwell_max: max}),
    do: min > 0 or max < length(@dwell_buckets) - 1

  def dwell_filtered?(_f), do: false

  # -- scopes --------------------------------------------------------------

  defp sessions_scope(f) do
    from(s in Session,
      where: s.site_id == ^f.site_id,
      where: s.started_at >= ^f.from and s.started_at < ^f.to
    )
    |> filter_anomalies(f)
    |> filter_crawlers(f)
    |> filter_dwell(f)
    |> filter_origins(f)
    |> filter_sessions(f)
    |> filter_project(f)
    |> filter_host(f)
  end

  defp filter_project(query, %{project: project}) when is_binary(project),
    do: where(query, [s], s.project == ^project)

  defp filter_project(query, _f), do: query

  defp filter_host(query, %{host: host}) when is_binary(host),
    do: where(query, [s], s.host == ^host)

  defp filter_host(query, _f), do: query

  defp filter_joined_project(query, %{project: project}) when is_binary(project),
    do: where(query, [session: s], s.project == ^project)

  defp filter_joined_project(query, _f), do: query

  defp filter_joined_host(query, %{host: host}) when is_binary(host),
    do: where(query, [session: s], s.host == ^host)

  defp filter_joined_host(query, _f), do: query

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

  # Struck out one row at a time. No null case to worry about here: a session
  # always has an id, which is the whole reason the row checkbox works on this
  # rather than on the origin — unticking one row should remove one row.
  defp filter_sessions(query, %{exclude_sessions: [_ | _] = ids}),
    do: where(query, [s], s.id not in ^ids)

  defp filter_sessions(query, _f), do: query

  defp filter_joined_sessions(query, %{exclude_sessions: [_ | _] = ids}),
    do: where(query, [session: s], s.id not in ^ids)

  defp filter_joined_sessions(query, _f), do: query

  # A session with no hash at all — a ping that arrived without a resolvable
  # address — is not one of the excluded origins and has to survive the filter.
  # Left to SQL's three-valued logic, `not in` against NULL yields NULL and
  # drops the row, so the null case is spelled out.
  defp filter_origins(query, %{exclude_origins: [_ | _] = origins}),
    do: where(query, [s], is_nil(s.ip_hash) or s.ip_hash not in ^origins)

  defp filter_origins(query, _f), do: query

  defp filter_joined_origins(query, %{exclude_origins: [_ | _] = origins}),
    do: where(query, [session: s], is_nil(s.ip_hash) or s.ip_hash not in ^origins)

  defp filter_joined_origins(query, _f), do: query

  # Open-ended at the top when the reader has the high handle at "1h+": there is
  # no ceiling to compare against, and inventing one would silently drop the
  # longest visits from a range that says it includes them.
  defp filter_dwell(query, %{dwell_from_ms: from_ms, dwell_to_ms: to_ms}) do
    query
    |> then(fn q -> if from_ms > 0, do: where(q, [s], s.dwell_ms >= ^from_ms), else: q end)
    |> then(fn q -> if to_ms, do: where(q, [s], s.dwell_ms < ^to_ms), else: q end)
  end

  defp filter_dwell(query, _f), do: query

  defp filter_joined_dwell(query, %{dwell_from_ms: from_ms, dwell_to_ms: to_ms}) do
    query
    |> then(fn q ->
      if from_ms > 0, do: where(q, [session: s], s.dwell_ms >= ^from_ms), else: q
    end)
    |> then(fn q -> if to_ms, do: where(q, [session: s], s.dwell_ms < ^to_ms), else: q end)
  end

  defp filter_joined_dwell(query, _f), do: query

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
    |> filter_joined_dwell(f)
    |> filter_joined_origins(f)
    |> filter_joined_sessions(f)
    |> filter_joined_project(f)
    |> filter_joined_host(f)
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
    |> filter_joined_dwell(f)
    |> filter_joined_origins(f)
    |> filter_joined_sessions(f)
    |> filter_joined_project(f)
    |> filter_joined_host(f)
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
    |> filter_joined_dwell(f)
    |> filter_joined_origins(f)
    |> filter_joined_sessions(f)
    |> filter_joined_project(f)
    |> filter_joined_host(f)
  end

  # -- overview ------------------------------------------------------------

  # A bounce is a visit that did not last. Counted on time rather than on
  # pageview count because a one-page visit is not automatically a failure —
  # someone who reads a long answer and leaves satisfied got what they came
  # for, and a pageview-count rule calls that a bounce while calling ten
  # seconds of frantic clicking a success. Ten seconds is the line: below it
  # nobody has read anything.
  @bounce_dwell_ms 10_000

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
            bounces: filter(count(s.id), s.dwell_ms < @bounce_dwell_ms)
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
      from = bucket * 10
      # `LEAST(pct/10, 9)` puts 100% in the last bucket alongside 90-99, so that
      # one spans eleven points and the arithmetic for the other nine does not
      # describe it.
      to = if bucket == 9, do: 100, else: from + 9

      %{
        from: from,
        to: to,
        # The histogram component reads `:label` for the caption under each bar.
        # Without one it renders an empty span, which is a chart of ten unnamed
        # bars — you can see the shape and not read a value off it.
        label: "#{from}-#{to}%",
        count: Map.get(rows, bucket, 0)
      }
    end)
  end

  # -- flow ----------------------------------------------------------------

  @doc """
  Page-to-page transitions.

  Each pageview row already carries the hop that produced it, so the whole
  graph is one grouped scan rather than a self join over ordered sessions.
  """
  def flow(f, limit \\ 25) do
    Repo.all(
      from row in transitions(f),
        group_by: [row.from, row.to],
        order_by: [desc: count(row.session_id)],
        limit: ^limit,
        select: %{
          from: row.from,
          to: row.to,
          count: count(row.session_id),
          sessions: count(row.session_id, :distinct)
        }
    )
  end

  # Every transition in range, one row per hop, before any ranking or limit.
  #
  # Shared so flow/2 and flow_coverage/1 cannot disagree about what a transition
  # is: a coverage line counting differently from the diagram it explains would
  # be worse than no coverage line.
  #
  # The previous page is worked out here rather than taken from the client. The
  # tag does send one — it carries the last path across page loads in
  # sessionStorage — but it is missing whenever that state did not survive: a
  # restored tab, a new tab, the first load after the tag was added, a browser
  # refusing storage, and every pageview reported through the ping API, which
  # has no notion of a previous page at all. On real traffic that was most of
  # them, and a diagram built only from the ones that arrived with a from_path
  # showed a handful of transitions out of hundreds.
  #
  # The server already holds every pageview of a session in order, so it can
  # simply look at the row before. The client's value is kept as the fallback
  # for the one case the server cannot see: a session whose earlier pageviews
  # never reached us, where the row before is genuinely not here.
  defp transitions(f) do
    {from_key, to_key} = flow_fields(f)

    ordered =
      from p in pageviews_scope(f),
        select: %{
          session_id: p.session_id,
          to: field(p, ^to_key),
          from:
            fragment(
              "COALESCE(lag(?) OVER (PARTITION BY ? ORDER BY ?, ?, ?), ?)",
              field(p, ^to_key),
              p.session_id,
              p.seq,
              p.entered_at,
              p.id,
              field(p, ^from_key)
            )
        }

    from row in subquery(ordered),
      where: not is_nil(row.from) and not is_nil(row.to),
      # A reload reports the same path twice in a row. It is a real pageview and
      # belongs in the counts, but as a loop on the diagram it says nothing and
      # crowds out the routes that do.
      where: row.from != row.to
  end

  @doc """
  How much of the traffic the flow diagram can actually draw.

  A thin diagram has two causes that look identical from the outside: the limit
  is cutting the tail off a busy graph, or almost every visit was a single page
  and there is no route to draw at all. Reporting both lets the panel say which
  one it is, instead of leaving a reader to wonder whether it is broken.
  """
  def flow_coverage(f, limit \\ 25) do
    # A subquery has to select a map or a source, so the grouped pairs come back
    # as one and are counted outside.
    routes =
      Repo.one(
        from r in subquery(
               from(row in transitions(f),
                 group_by: [row.from, row.to],
                 select: %{from: row.from, to: row.to}
               )
             ),
             select: count()
      ) || 0

    hops =
      Repo.one(from row in transitions(f), select: count(row.session_id)) || 0

    visits =
      Repo.one(
        from s in sessions_scope(f),
          select: %{
            total: count(s.id),
            single: filter(count(s.id), s.pageview_count <= 1)
          }
      ) || %{total: 0, single: 0}

    shown =
      Repo.one(
        from r in subquery(
               from(row in transitions(f),
                 group_by: [row.from, row.to],
                 order_by: [desc: count(row.session_id)],
                 limit: ^limit,
                 select: %{hops: count(row.session_id)}
               )
             ),
             select: coalesce(sum(r.hops), 0)
      ) || 0

    %{
      routes: routes,
      routes_shown: min(routes, limit),
      hops: hops,
      # sum/1 comes back as a Decimal, and a Decimal in a template renders as a
      # struct rather than a number.
      hops_shown: shown |> to_number() |> round(),
      sessions: visits.total,
      single_page_sessions: visits.single
    }
  end

  @doc """
  The commonest three-page journeys.

  A pair says which page follows which; three says what a route actually looks
  like — whether the people who reach checkout came through teams, or arrived
  there some other way. Read from the order of each visit, like `flow/2`, with
  the same window and the same partition.

  A repeat of the page in hand is dropped on either side, so a reload in the
  middle of a route does not turn one journey into a different-looking one.
  """
  def journeys(f, limit \\ 12) do
    key = group_field(f)

    ordered =
      from p in pageviews_scope(f),
        select: %{
          session_id: p.session_id,
          second: field(p, ^key),
          first:
            fragment(
              "lag(?) OVER (PARTITION BY ? ORDER BY ?, ?, ?)",
              field(p, ^key),
              p.session_id,
              p.seq,
              p.entered_at,
              p.id
            ),
          third:
            fragment(
              "lead(?) OVER (PARTITION BY ? ORDER BY ?, ?, ?)",
              field(p, ^key),
              p.session_id,
              p.seq,
              p.entered_at,
              p.id
            )
        }

    Repo.all(
      from row in subquery(ordered),
        where: not is_nil(row.first) and not is_nil(row.second) and not is_nil(row.third),
        where: row.first != row.second and row.second != row.third,
        group_by: [row.first, row.second, row.third],
        order_by: [desc: count(row.session_id)],
        limit: ^limit,
        select: %{
          first: row.first,
          second: row.second,
          third: row.third,
          count: count(row.session_id),
          sessions: count(row.session_id, :distinct)
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

  # "Name" is the question "what is this element called", and for almost every
  # element on a real page nobody has answered it: `name` comes from an opt-in
  # data-wa-name attribute that nothing carries by default. Grouping on that
  # alone, with a not-null filter, made this — the default view of the Clicks
  # tab — empty on sites where every click had in fact been recorded. The rows
  # were in the database with a tag, a text and an href on them; the one column
  # being grouped was the only one nobody had filled in.
  #
  # So it falls through to what a page always has. The explicit attribute still
  # wins where somebody set it, which is the whole point of having it.
  #
  # The fragment is repeated in GROUP BY rather than referenced through
  # selected_as: Postgres resolves a GROUP BY name against input columns first,
  # and `name` is one of them, so the alias would silently group by e.name —
  # exactly the column this clause exists to stop relying on.
  def clicks(f, :name, limit) do
    Repo.all(
      from e in events_scope(f),
        where: e.type != "custom",
        group_by:
          fragment(
            "COALESCE(NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?)",
            e.name,
            e.text,
            e.el_id,
            e.tag
          ),
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          name:
            fragment(
              "COALESCE(NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?)",
              e.name,
              e.text,
              e.el_id,
              e.tag
            ),
          count: count(e.id),
          sessions: count(e.session_id, :distinct),
          outbound: filter(count(e.id), e.outbound)
        }
    )
  end

  def clicks(f, group, limit) do
    key =
      case group do
        :id -> :el_id
        :text -> :text
        :selector -> :selector
        :tag -> :tag
        _ -> :el_id
      end

    Repo.all(
      from e in events_scope(f),
        # A custom event from track() is not a click and does not belong in a
        # report about them. The :class clause always filtered it out; this one
        # did not, so the same tab disagreed with itself depending on grouping.
        where: e.type != "custom",
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

  # -- events ---------------------------------------------------------------

  @doc """
  Named events, ranked.

  Split from clicks on purpose. A click is something the tracker noticed; an
  event is something a caller decided to tell us about, and `run_completed`
  sitting in a list called "Clicks" reads as a bug in the product rather than a
  choice about where to put it.
  """
  def events(f, limit \\ 50) do
    Repo.all(
      from e in events_scope(f),
        where: not is_nil(e.name),
        group_by: [e.name, e.type],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: %{
          name: e.name,
          type: e.type,
          count: count(e.id),
          sessions: count(e.session_id, :distinct),
          first_seen: min(e.occurred_at),
          last_seen: max(e.occurred_at),
          attributes: count(fragment("nullif(?, '{}'::jsonb)", e.data_attrs))
        }
    )
  end

  @doc """
  The attributes carried by one event name, each with its commonest values.

  This is the half of the ping contract nothing showed until now: llms.txt
  promises that anything a caller invents is kept on the event, and a promise
  you cannot read back is only half kept.

  One query for keys and values together, grouped here rather than a query per
  key. An event with a dozen attributes would otherwise be a dozen round trips
  on a page that refreshes itself every few seconds.
  """
  def event_attributes(f, name, value_limit \\ 6) do
    Repo.all(
      from e in events_scope(f),
        cross_join: kv in fragment("jsonb_each_text(?)", e.data_attrs),
        where: e.name == ^name,
        group_by: [fragment("?", field(kv, :key)), fragment("?", field(kv, :value))],
        select: %{
          key: fragment("?", field(kv, :key)),
          value: fragment("?", field(kv, :value)),
          count: count(e.id)
        }
    )
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {key, rows} ->
      %{
        key: key,
        count: rows |> Enum.map(& &1.count) |> Enum.sum(),
        distinct_values: length(rows),
        top: rows |> Enum.sort_by(& &1.count, :desc) |> Enum.take(value_limit)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc """
  Event-to-event transitions inside a session.

  The page flow graph answers "where did people go next"; for a tool that has no
  pages, the same question is asked of events — run_started to tool_called to
  run_completed. Paired with a window function so consecutive events are found
  in one pass, rather than reading every event back and pairing them here.
  """
  def event_flow(f, limit \\ 18) do
    Repo.all(
      from t in subquery(event_sequence(f)),
        where: not is_nil(t.previous),
        group_by: [t.previous, t.name],
        order_by: [desc: count(t.id)],
        limit: ^limit,
        select: %{
          from: t.previous,
          to: t.name,
          count: count(t.id),
          sessions: count(t.session_id, :distinct)
        }
    )
  end

  @doc "The events sessions open with, and the ones they stop at."
  def event_entries(f, limit \\ 10) do
    Repo.all(
      from t in subquery(event_sequence(f)),
        where: is_nil(t.previous),
        group_by: t.name,
        order_by: [desc: count(t.id)],
        limit: ^limit,
        select: %{name: t.name, count: count(t.id)}
    )
  end

  def event_exits(f, limit \\ 10) do
    Repo.all(
      from t in subquery(event_sequence(f)),
        where: is_nil(t.next),
        group_by: t.name,
        order_by: [desc: count(t.id)],
        limit: ^limit,
        select: %{name: t.name, count: count(t.id)}
    )
  end

  @doc "Everything that happened in one session, in order. The drill-down's payload."
  def event_sequences(f, name, limit \\ 10) do
    sessions =
      Repo.all(
        from t in subquery(event_sequence(f)),
          where: t.name == ^name,
          group_by: t.session_id,
          order_by: [desc: max(t.at)],
          limit: ^limit,
          select: t.session_id
      )

    Repo.all(
      from e in events_scope(f),
        join: s in assoc(e, :session),
        where: e.session_id in ^sessions and not is_nil(e.name),
        order_by: [asc: e.session_id, asc: e.occurred_at, asc: e.id],
        select: %{
          session_id: e.session_id,
          name: e.name,
          at: e.occurred_at,
          attrs: e.data_attrs,
          project: s.project
        }
    )
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {id, events} -> %{session_id: id, events: events} end)
    |> Enum.sort_by(fn %{events: [first | _]} -> first.at end, {:desc, DateTime})
  end

  # Each event with the one before and after it in the same session. Ordered by
  # id as well as time because two pings from the same run can land in the same
  # millisecond, and a tie makes the pairing arbitrary.
  defp event_sequence(f) do
    from e in events_scope(f),
      where: not is_nil(e.name),
      select: %{
        id: e.id,
        session_id: e.session_id,
        name: e.name,
        at: e.occurred_at,
        previous:
          fragment(
            "lag(?) OVER (PARTITION BY ? ORDER BY ?, ?)",
            e.name,
            e.session_id,
            e.occurred_at,
            e.id
          ),
        next:
          fragment(
            "lead(?) OVER (PARTITION BY ? ORDER BY ?, ?)",
            e.name,
            e.session_id,
            e.occurred_at,
            e.id
          )
      }
  end

  @doc "The most recent events, with whatever attributes came with them."
  def recent_events(f, limit \\ 50) do
    Repo.all(
      from e in events_scope(f),
        join: s in assoc(e, :session),
        where: not is_nil(e.name),
        order_by: [desc: e.occurred_at],
        limit: ^limit,
        select: %{
          id: e.id,
          name: e.name,
          type: e.type,
          at: e.occurred_at,
          path: e.path,
          title: e.title,
          text: e.text,
          href: e.href,
          href_host: e.href_host,
          outbound: e.outbound,
          trigger: e.trigger,
          tag: e.tag,
          scroll_pct: e.scroll_pct,
          # How far into the pageview it happened, which is the difference
          # between a click someone went looking for and one they hit on
          # arrival.
          ms_since_pageview: e.ms_since_pageview,
          attrs: e.data_attrs,
          # The session, so a run of events can be read as one run rather than
          # as a list of unrelated things that happened.
          session_token: s.token,
          project: s.project,
          channel: s.channel,
          crawler_name: s.crawler_name,
          browser: s.browser,
          device_type: s.device_type,
          host: s.host,
          country: s.country,
          city: s.city
        }
    )
  end

  @doc "One event's volume over the range, so a spike has a shape."
  def event_timeseries(f, name, buckets \\ 24) do
    seconds = max(DateTime.diff(f.to, f.from), 60)
    width = max(div(seconds, buckets), 60)

    Repo.all(
      from e in events_scope(f),
        where: e.name == ^name,
        select: %{
          at:
            selected_as(
              fragment(
                "to_timestamp(floor(extract(epoch from ?) / ?) * ?)",
                e.occurred_at,
                ^width,
                ^width
              ),
              :at
            ),
          count: count(e.id)
        },
        group_by: selected_as(:at),
        order_by: selected_as(:at)
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
    # The full scope, minus the row checkboxes. Built from sessions_scope rather
    # than its own query so this table cannot disagree with the numbers above
    # it — it was ignoring the session-length range and the origin exclusions,
    # which meant dragging the slider moved every figure on the page except the
    # list of the very rows being filtered.
    #
    # The one exception is exclude_sessions: a row struck out by hand stays
    # visible, because this list is the only place to untick it again.
    Repo.all(
      from s in sessions_scope(%{f | exclude_sessions: []}),
        order_by: [desc: s.last_seen_at],
        limit: ^limit
    )
  end

  # Two windows, because they answer different questions. Thirty minutes is the
  # conventional "active users" figure — how many people are around. Thirty
  # seconds is who is touching the page as you watch, which is the number you
  # want when you have just shipped something and are asking whether it works.
  @active_window_ms 30 * 60 * 1000
  @live_window_ms 30 * 1000

  @doc """
  Who is on the site right now.

  Deliberately ignores the selected range: "active" is a fact about the clock,
  not about the window the reader happens to be looking at, and a live panel
  that went empty because someone picked last month would be reporting on the
  filter rather than on the traffic. The dimension filters — project, domain —
  are kept, because those narrow which traffic you meant.
  """
  def active_now(f, now \\ DateTime.utc_now(), limit \\ 40) do
    active_since = DateTime.add(now, -@active_window_ms, :millisecond)
    live_since = DateTime.add(now, -@live_window_ms, :millisecond)

    base =
      from(s in Session,
        where: s.site_id == ^f.site_id,
        where: s.last_seen_at >= ^active_since
      )
      |> filter_anomalies(f)
      |> filter_crawlers(f)
      |> filter_origins(f)
      # Struck-out sessions are hidden here, unlike in the session list. That
      # list is where a row goes to be put back, so it has to keep showing one;
      # this panel answers "who is here right now", and a visit you have
      # decided is not traffic should not be in the answer or in the count.
      # The Remove filter strip above it is the way back from either.
      |> filter_sessions(f)
      |> filter_project(f)
      |> filter_host(f)

    totals =
      Repo.one(
        from s in base,
          select: %{
            sessions: count(s.id),
            visitors: count(s.visitor_token, :distinct),
            pageviews: coalesce(sum(s.pageview_count), 0),
            live_sessions: filter(count(s.id), s.last_seen_at >= ^live_since),
            live_visitors:
              fragment(
                "count(distinct ?) FILTER (WHERE ? >= ?)",
                s.visitor_token,
                s.last_seen_at,
                ^live_since
              )
          }
      ) || %{}

    sessions =
      Repo.all(
        from s in base,
          order_by: [desc: s.last_seen_at],
          limit: ^limit
      )

    totals
    |> Map.put(:sessions_list, with_events(sessions))
    |> Map.put(:series, concurrent_series(base, now))
    |> Map.put(:as_of, now)
  end

  # What each listed visit has reported, for the same reason the admin panel
  # needs it: an AI tool has no page, no pageview and no dwell by construction,
  # so a live row for one is a line of em dashes unless its events are on it.
  #
  # Two small queries against the listed ids, so the panel's own limit bounds
  # the work rather than the size of the account.
  defp with_events([]), do: []

  defp with_events(sessions) do
    ids = Enum.map(sessions, & &1.id)

    counts =
      Repo.all(
        from e in Event,
          where: e.session_id in ^ids and not is_nil(e.name),
          group_by: e.session_id,
          select: {e.session_id, count(e.id)}
      )
      |> Map.new()

    # DISTINCT ON gets the newest row per session; an aggregate can give the
    # latest time but not the name that came with it.
    latest =
      Repo.all(
        from e in Event,
          where: e.session_id in ^ids and not is_nil(e.name),
          distinct: e.session_id,
          # id breaks the tie. Events reported in one batch share a timestamp,
          # so ordering on occurred_at alone leaves "latest" to whatever the
          # planner returns first — which is how a run whose last act was
          # tool_called showed run_started instead.
          order_by: [asc: e.session_id, desc: e.occurred_at, desc: e.id],
          select: {e.session_id, e.name}
      )
      |> Map.new()

    # Flattened to a plain map rather than wrapped, so the template keeps
    # reaching for session.field and simply gains two more. A struct cannot
    # carry keys it did not declare, and a wrapper would mean rewriting every
    # cell in the row to say row.session.whatever.
    Enum.map(sessions, fn session ->
      session
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.put(:events, Map.get(counts, session.id, 0))
      |> Map.put(:last_event, Map.get(latest, session.id))
    end)
  end

  @doc "The two live windows, in milliseconds, for anything that has to label them."
  def live_windows, do: %{active_ms: @active_window_ms, live_ms: @live_window_ms}

  # How many sessions were open during each of the last thirty minutes.
  #
  # A session is counted in every minute it spanned, not just the one it was
  # last seen in. Bucketing on last_seen_at alone would put a visit that has
  # been reading for ten minutes in the newest bucket only, and draw the other
  # nine as empty — a chart that says nothing was happening during the exact
  # period something was.
  #
  # Bucketed here rather than in SQL because the row set is already bounded by
  # the thirty minute window: two timestamps per active session is a small read,
  # and a lateral join over generate_series to save it would be the harder thing
  # to read for no gain.
  defp concurrent_series(base, now) do
    spans =
      Repo.all(from s in base, select: {s.started_at, s.last_seen_at})

    start = now |> DateTime.add(-29, :minute) |> truncate_minute()

    for offset <- 0..29 do
      at = DateTime.add(start, offset, :minute)
      until = DateTime.add(at, 60, :second)

      count =
        Enum.count(spans, fn {started_at, last_seen_at} ->
          DateTime.compare(started_at, until) == :lt and
            DateTime.compare(last_seen_at, at) != :lt
        end)

      %{at: at, sessions: count}
    end
  end

  defp truncate_minute(%DateTime{} = at) do
    %{at | second: 0, microsecond: {0, 0}}
  end

  # What makes an origin worth offering to exclude. Both are about one place
  # generating traffic that is not a person reading the site, and they catch
  # different shapes of it: a scraper that produces many junk sessions, and a
  # single origin that has come to dominate the whole report.
  @origin_min_sessions 5
  @origin_anomalous_share 0.5
  @origin_dominant_share 0.2
  @origin_dominant_floor 10

  @doc """
  Traffic grouped by origin, with the ones worth excluding flagged.

  These are hashes, never addresses: nothing in this system stores an address.
  The hash is salted per site and rotated daily, which is the important caveat
  for this screen — over a range longer than a day one address appears as one
  origin per day, and an exclusion only matches the day it was made on.

  Deliberately ignores both the anomaly filter and the origin exclusions: the
  anomalous count is the reason a row is being suggested, and a row you have
  already excluded still has to be listed so you can put it back.
  """
  def origins(f, limit \\ 12) do
    query =
      from(s in Session,
        where: s.site_id == ^f.site_id,
        where: s.started_at >= ^f.from and s.started_at < ^f.to,
        where: not is_nil(s.ip_hash)
      )
      |> filter_project(f)
      |> filter_host(f)

    rows =
      Repo.all(
        from s in query,
          group_by: s.ip_hash,
          order_by: [desc: count(s.id)],
          limit: ^limit,
          select: %{
            ip_hash: s.ip_hash,
            sessions: count(s.id),
            anomalous: filter(count(s.id), s.anomalous),
            crawlers: filter(count(s.id), s.crawler),
            pageviews: coalesce(sum(s.pageview_count), 0),
            last_seen_at: max(s.last_seen_at)
          }
      )

    total = Enum.reduce(rows, 0, &(&1.sessions + &2))

    Enum.map(rows, fn row -> Map.merge(row, suggestion(row, total)) end)
  end

  # The reason travels with the flag. A suggestion a reader cannot see the
  # basis of is a nag, and this one is asking them to throw data away.
  defp suggestion(row, total) do
    share = if total > 0, do: row.sessions / total, else: 0.0
    anomalous_share = if row.sessions > 0, do: row.anomalous / row.sessions, else: 0.0

    cond do
      row.sessions >= @origin_min_sessions and anomalous_share >= @origin_anomalous_share ->
        %{suggested: true, reason: "#{round(anomalous_share * 100)}% of its sessions are junk"}

      row.sessions >= @origin_dominant_floor and share >= @origin_dominant_share ->
        %{suggested: true, reason: "#{round(share * 100)}% of all sessions from one origin"}

      true ->
        %{suggested: false, reason: nil}
    end
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
  Automated traffic against one site in the last day, named and counted.

  For the landing page: the crawlers hitting this deployment's own pages, which
  the server records because the browser tag cannot see them.
  """
  def recent_crawler_summary(site_id, hours \\ 24, limit \\ 8) do
    since = DateTime.add(DateTime.utc_now(), -hours, :hour)

    rows =
      Repo.all(
        from s in Session,
          where: s.site_id == ^site_id and s.crawler and s.started_at > ^since,
          group_by: [s.crawler_name, s.crawler_kind],
          order_by: [desc: count(s.id)],
          select: %{
            name: s.crawler_name,
            kind: s.crawler_kind,
            sessions: count(s.id),
            pageviews: coalesce(sum(s.pageview_count), 0),
            last_seen: max(s.last_seen_at)
          }
      )

    %{
      crawlers: Enum.take(rows, limit),
      total_sessions: rows |> Enum.map(& &1.sessions) |> Enum.sum(),
      total_pageviews: rows |> Enum.map(& &1.pageviews) |> Enum.sum(),
      ai_sessions:
        rows |> Enum.filter(&(&1.kind == "ai")) |> Enum.map(& &1.sessions) |> Enum.sum(),
      distinct: length(rows)
    }
  end

  @doc """
  Hostnames this account has seen traffic on, busiest first.

  Populated from the first pageview of each session, so an account whose tag is
  only on one domain gets a single row and no selector worth showing.

  Ignores the host filter, since it exists to populate the control that sets it.
  """
  def domains(f) do
    Repo.all(
      from s in Session,
        where: s.site_id == ^f.site_id,
        where: s.started_at >= ^f.from and s.started_at < ^f.to,
        where: not is_nil(s.host),
        group_by: s.host,
        order_by: [desc: count(s.id)],
        select: %{
          name: s.host,
          count: count(s.id),
          pageviews: coalesce(sum(s.pageview_count), 0),
          last_seen: max(s.last_seen_at)
        }
    )
  end

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
          bounces: filter(count(s.id), s.dwell_ms < @bounce_dwell_ms)
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
          bounces: filter(count(s.id), s.dwell_ms < @bounce_dwell_ms)
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
          bounces: filter(count(s.id), s.dwell_ms < @bounce_dwell_ms)
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
          bounces: filter(count(s.id), s.dwell_ms < @bounce_dwell_ms)
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
