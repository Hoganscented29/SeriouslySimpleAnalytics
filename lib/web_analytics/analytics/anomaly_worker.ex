defmodule WebAnalytics.Analytics.AnomalyWorker do
  @moduledoc """
  Periodically (re)classifies sessions for every site.

  Ingest clears `classified_at` whenever a session receives new activity, so a
  live visit is re-judged on each pass and settles once it stops moving. That
  keeps a long visit from being permanently branded an outlier on the strength
  of its first few seconds.
  """
  use GenServer

  require Logger

  alias WebAnalytics.Analytics.Anomaly
  alias WebAnalytics.Repo

  @session_fields ~w(id dwell_ms active_ms tick_count active_tick_count
                     pageview_count click_count max_scroll_pct crawler channel)a

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one classification pass in the calling process.

  The GenServer below is only a scheduler — the work itself lives here so it can
  be run directly by tests, seeds and one-off scripts, which own their own
  database connection and cannot borrow the worker's.
  """
  def classify_all(config \\ Anomaly.config()), do: run(config)

  @doc "Asks the running worker to classify now and waits for it."
  def classify_now(server \\ __MODULE__, timeout \\ 60_000) do
    GenServer.call(server, :classify, timeout)
  end

  @doc """
  Forces every session for a site back into the queue.

  Used after the anomaly thresholds change, so the stored verdicts reflect the
  settings currently in force rather than the ones in force when they were
  written.
  """
  def reclassify_site(site_id) do
    {count, _} =
      Repo.update_all(
        from_sessions(site_id),
        set: [classified_at: nil]
      )

    count
  end

  @doc """
  Median and MAD of `ln(dwell_ms)` for a site over the configured window.

  Returns `nil` when the site has no usable sessions yet.
  """
  def baseline(site_id, config \\ Anomaly.config()) do
    since = DateTime.add(DateTime.utc_now(), -config.window_days * 86_400, :second)

    sql = """
    WITH base AS (
      SELECT ln(GREATEST(dwell_ms, 1)::float8) AS x
      FROM sessions
      WHERE site_id = $1 AND started_at >= $2 AND dwell_ms > 0
    ),
    med AS (
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) AS m FROM base
    )
    SELECT med.m,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(base.x - med.m)),
           count(*)
    FROM base CROSS JOIN med
    GROUP BY med.m
    """

    case Repo.query!(sql, [site_id, since]) do
      %{rows: [[median, mad, sample]]} when is_number(median) ->
        %{median: median, mad: mad || 0.0, sample: sample}

      _ ->
        nil
    end
  end

  @impl true
  def init(opts) do
    config = Anomaly.config()
    state = %{config: config, enabled: Keyword.get(opts, :enabled, config.enabled)}

    if state.enabled, do: schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:classify, _from, state) do
    {:reply, run(state.config), state}
  end

  @impl true
  def handle_info(:classify, state) do
    config = Anomaly.config()

    try do
      run(config)
    rescue
      exception ->
        Logger.error(
          "anomaly classification failed: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )
    end

    state = %{state | config: config}
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    Process.send_after(self(), :classify, state.config.interval_ms)
  end

  defp run(config) do
    site_ids = Repo.all(site_id_query())
    Enum.reduce(site_ids, 0, fn site_id, acc -> acc + classify_site(site_id, config) end)
  end

  defp classify_site(site_id, config) do
    baseline = baseline(site_id, config)
    classify_chunks(site_id, baseline, config, 0)
  end

  defp classify_chunks(site_id, baseline, config, total) do
    sessions = Repo.all(unclassified_query(site_id, config.batch_size))

    if sessions == [] do
      total
    else
      verdicts =
        Enum.map(sessions, fn session ->
          {session.id, Anomaly.classify(session, baseline, config)}
        end)

      write_verdicts(verdicts)
      count = length(sessions)

      if count < config.batch_size do
        total + count
      else
        classify_chunks(site_id, baseline, config, total + count)
      end
    end
  end

  # One statement per chunk. A per-row UPDATE would be hundreds of round trips
  # on a busy site, and the values differ per row so `update_all` cannot do it.
  defp write_verdicts([]), do: :ok

  defp write_verdicts(verdicts) do
    {rows, params, _} =
      Enum.reduce(verdicts, {[], [], 1}, fn {id, verdict}, {rows, params, index} ->
        row =
          if index == 1 do
            "($1::bigint, $2::boolean, $3::float8, $4::text[])"
          else
            "($#{index}, $#{index + 1}, $#{index + 2}, $#{index + 3})"
          end

        {
          [row | rows],
          [verdict.anomaly_reasons, verdict.anomaly_score, verdict.anomalous, id | params],
          index + 4
        }
      end)

    values = rows |> Enum.reverse() |> Enum.join(", ")
    params = Enum.reverse(params)
    stamp_index = length(params) + 1

    sql = """
    UPDATE sessions AS s
    SET anomalous = v.anomalous,
        anomaly_score = v.score,
        anomaly_reasons = v.reasons,
        classified_at = $#{stamp_index}
    FROM (VALUES #{values}) AS v(id, anomalous, score, reasons)
    WHERE s.id = v.id
    """

    Repo.query!(sql, params ++ [DateTime.utc_now()])
    :ok
  end

  defp site_id_query do
    import Ecto.Query
    from s in "sites", select: s.id
  end

  defp unclassified_query(site_id, limit) do
    import Ecto.Query

    from s in "sessions",
      where: s.site_id == ^site_id and is_nil(s.classified_at),
      order_by: [asc: s.id],
      limit: ^limit,
      select: ^@session_fields
  end

  defp from_sessions(site_id) do
    import Ecto.Query
    from s in "sessions", where: s.site_id == ^site_id
  end
end
