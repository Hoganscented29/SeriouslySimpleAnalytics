defmodule WebAnalytics.Analytics.Anomaly do
  @moduledoc """
  Decides whether a session's dwell time makes it unfit for reporting.

  Two kinds of signal are combined. Rule checks catch the shapes that are
  impossible for a human — a dozen pages in two seconds, twelve hours parked on
  one tab, a hundred heartbeats with no scroll, click or focus. On top of that
  sits a distribution check: dwell times are log-normal in practice, so the
  baseline uses the median and median absolute deviation of `ln(dwell)` rather
  than mean and standard deviation, because those two statistics are themselves
  wrecked by the outliers being looked for.

  Only web-channel sessions are classified at all. Everything else — an AI tool
  reporting through the ping API, a CLI, a job — has no dwell to judge, and
  measuring it against a browser's distribution would hide it entirely.

  Automated traffic is deliberately *not* handled here. A crawler is not a
  malformed session, it is a different kind of visitor, so it is classified by
  `WebAnalytics.Ingest.Crawler` and filtered on its own axis — otherwise every
  bot would be counted twice, once as a crawler and again as an outlier.

  Classification only ever *labels* a session. Nothing is deleted and nothing is
  hidden at the database level — the dashboard decides whether to apply the
  filter, so the toggle can show the excluded traffic at any time.
  """

  @defaults [
    enabled: true,
    interval_ms: 30_000,
    window_days: 7,
    batch_size: 500,
    # Below this many sampled sessions the distribution check is skipped
    # entirely; MAD on a handful of visits is noise.
    min_sample: 30,
    # Robust z cutoff. 3.5 is the conventional MAD threshold.
    z_threshold: 3.5,
    min_dwell_ms: 1_000,
    fast_page_ms: 700,
    hyper_pages_per_second: 1.0,
    idle_tab_ms: 14_400_000,
    idle_active_ratio: 0.02,
    max_dwell_ms: 43_200_000,
    stale_tick_count: 60
  ]

  # Scale factor making MAD a consistent estimator of sigma for normal data.
  @mad_to_sigma 1.4826

  @labels %{
    "no_dwell" => "No measurable dwell",
    "too_fast" => "Faster than humanly possible",
    "hyper_navigation" => "Impossible navigation rate",
    "idle_tab" => "Parked idle tab",
    "extreme_dwell" => "Implausibly long visit",
    "no_engagement" => "Heartbeats with zero engagement",
    "dwell_outlier" => "Dwell time is a statistical outlier"
  }

  @doc "Merged anomaly configuration."
  def config do
    @defaults
    |> Keyword.merge(Application.get_env(:web_analytics, :anomaly, []))
    |> Map.new()
  end

  @doc "Human-readable name for a stored reason code."
  def label(reason), do: Map.get(@labels, reason, reason)

  @doc "All reason codes with their labels."
  def labels, do: @labels

  @doc """
  Classifies one session against a baseline.

  `session` needs the dwell, engagement and count fields; `baseline` comes from
  `WebAnalytics.Analytics.AnomalyWorker.baseline/2` and may be `nil` when the
  site has too little traffic to model.
  """
  def classify(session, baseline, config \\ config())

  # Crawlers are judged on their own axis and never here. Their dwell profile —
  # no scrolling, no clicks, several pages in a second — trips almost every rule
  # below by design, so classifying them would flag them twice and mean that
  # un-hiding crawler traffic still left it hidden behind the anomaly filter.
  def classify(%{crawler: true}, _baseline, _config), do: clean()

  # Only browser sessions are judged on dwell. A tool reporting its own usage
  # through the ping API has no dwell by construction — one request, no
  # heartbeats — so every rule here would fire on it and the owner's own
  # telemetry would be filtered out of their own reports by default.
  def classify(%{channel: channel}, _baseline, _config)
      when is_binary(channel) and channel != "web" do
    clean()
  end

  def classify(session, baseline, config) do
    reasons =
      []
      |> check_no_dwell(session, config)
      |> check_too_fast(session, config)
      |> check_hyper_navigation(session, config)
      |> check_idle_tab(session, config)
      |> check_extreme_dwell(session, config)
      |> check_no_engagement(session, config)
      |> check_dwell_outlier(session, baseline, config)
      |> Enum.reverse()

    %{
      anomalous: reasons != [],
      anomaly_score: score(session, baseline),
      anomaly_reasons: reasons
    }
  end

  @doc """
  Robust z-score of a session's dwell time against the site baseline.

  Returns 0.0 when there is no usable baseline, so a quiet site reports
  "not an outlier" rather than a misleading number.
  """
  def score(session, baseline) do
    with %{median: median, mad: mad} when is_number(median) and is_number(mad) <- baseline,
         dwell when is_integer(dwell) and dwell > 0 <- session.dwell_ms,
         sigma when sigma > 0 <- mad * @mad_to_sigma do
      abs(:math.log(dwell) - median) / sigma
    else
      _ -> 0.0
    end
  end

  # -- rule checks ---------------------------------------------------------

  # A visit with no dwell, no heartbeat and no click carries no information.
  defp check_no_dwell(reasons, session, config) do
    if session.dwell_ms < config.min_dwell_ms and session.tick_count == 0 and
         session.click_count == 0 do
      ["no_dwell" | reasons]
    else
      reasons
    end
  end

  # Several pages at a pace a person could not read or click through.
  defp check_too_fast(reasons, session, config) do
    if session.pageview_count >= 3 and
         session.dwell_ms / session.pageview_count < config.fast_page_ms do
      ["too_fast" | reasons]
    else
      reasons
    end
  end

  defp check_hyper_navigation(reasons, session, config) do
    seconds = max(session.dwell_ms / 1000, 1.0)

    if session.pageview_count > 1 and
         session.pageview_count / seconds > config.hyper_pages_per_second do
      ["hyper_navigation" | reasons]
    else
      reasons
    end
  end

  # A tab left open for hours inflates dwell without any attention behind it.
  defp check_idle_tab(reasons, session, config) do
    ratio = active_ratio(session)

    if session.dwell_ms > config.idle_tab_ms and ratio < config.idle_active_ratio do
      ["idle_tab" | reasons]
    else
      reasons
    end
  end

  defp check_extreme_dwell(reasons, session, config) do
    if session.dwell_ms > config.max_dwell_ms, do: ["extreme_dwell" | reasons], else: reasons
  end

  # Heartbeats still arriving, but nothing ever moved: a background tab, or a
  # headless browser holding the page open.
  defp check_no_engagement(reasons, session, config) do
    if session.tick_count >= config.stale_tick_count and session.active_tick_count == 0 and
         session.click_count == 0 and session.max_scroll_pct == 0 do
      ["no_engagement" | reasons]
    else
      reasons
    end
  end

  defp check_dwell_outlier(reasons, session, baseline, config) do
    with %{sample: sample} when sample >= config.min_sample <- baseline,
         z when z > config.z_threshold <- score(session, baseline) do
      ["dwell_outlier" | reasons]
    else
      _ -> reasons
    end
  end

  defp active_ratio(%{dwell_ms: dwell, active_ms: active}) when dwell > 0, do: active / dwell
  defp active_ratio(_), do: 1.0

  defp clean, do: %{anomalous: false, anomaly_score: 0.0, anomaly_reasons: []}
end
