defmodule WebAnalytics.Ingest.Collector do
  @moduledoc """
  Buffers incoming batches and applies them to Postgres on a timer.

  The tracker beacons once a second per visitor for the first stretch of a
  visit, so writing straight through would put one transaction per visitor per
  second on the database. Buffering lets consecutive beacons from the same
  session merge into a single write, which is where almost all of the traffic
  goes.

  Flushes are serial and the next one is only scheduled once the previous
  finishes, so a slow database throttles the loop instead of stacking timers.
  """
  use GenServer

  require Logger

  alias WebAnalytics.Ingest.Processor

  @default_flush_interval_ms 1_000
  @default_max_queue 20_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queues a normalised batch. Returns `:ok`, or `:dropped` under backpressure."
  def enqueue(server \\ __MODULE__, batch) do
    GenServer.call(server, {:enqueue, batch})
  catch
    :exit, _ -> :dropped
  end

  @doc "Flushes everything queued and waits for it. Intended for tests."
  def flush_sync(server \\ __MODULE__, timeout \\ 15_000) do
    GenServer.call(server, :flush, timeout)
  end

  @doc "Number of batches currently waiting to be written."
  def queue_size(server \\ __MODULE__), do: GenServer.call(server, :queue_size)

  @doc """
  Discards everything queued without writing it.

  For tests: this process outlives any one test's sandbox transaction, so a
  batch left queued when a test ends would otherwise be written afterwards,
  against rows that have since been rolled back.
  """
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    config = Application.get_env(:web_analytics, __MODULE__, [])

    state = %{
      queue: [],
      size: 0,
      dropped: 0,
      flush_interval_ms:
        opts[:flush_interval_ms] || config[:flush_interval_ms] || @default_flush_interval_ms,
      max_queue: opts[:max_queue] || config[:max_queue] || @default_max_queue
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_call({:enqueue, batch}, _from, state) do
    if state.size >= state.max_queue do
      if rem(state.dropped, 100) == 0 do
        Logger.warning("ingest queue full (#{state.max_queue}), dropping batch")
      end

      {:reply, :dropped, %{state | dropped: state.dropped + 1}}
    else
      {:reply, :ok, %{state | queue: [batch | state.queue], size: state.size + 1}}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, drain(state)}
  end

  def handle_call(:queue_size, _from, state) do
    {:reply, state.size, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | queue: [], size: 0}}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, state |> drain() |> schedule_flush()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, state.flush_interval_ms)
    state
  end

  defp drain(%{queue: []} = state), do: state

  defp drain(state) do
    batches = state.queue |> Enum.reverse() |> merge()
    started = System.monotonic_time()

    Enum.each(batches, &write/1)

    :telemetry.execute(
      [:web_analytics, :ingest, :flush],
      %{
        duration: System.monotonic_time() - started,
        batches: length(batches),
        queued: state.size
      },
      %{}
    )

    %{state | queue: [], size: 0}
  end

  defp write(batch) do
    case Processor.apply_batch(batch) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("ingest write failed for session #{batch.token}: #{inspect(reason)}")
        :error
    end
  rescue
    exception ->
      Logger.error(
        "ingest write crashed for session #{batch.token}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :error
  end

  # Consecutive beacons from one session are concatenated into a single batch so
  # a flush does one transaction per session rather than one per beacon. Order
  # within a session is preserved, which the processor relies on.
  defp merge(batches) do
    {merged, order} =
      Enum.reduce(batches, {%{}, []}, fn batch, {acc, order} ->
        key = {batch.site_id, batch.token}

        case Map.fetch(acc, key) do
          {:ok, existing} ->
            combined = %{
              existing
              | events: existing.events ++ batch.events,
                visitor_token: batch.visitor_token || existing.visitor_token,
                ip_hash: batch.ip_hash || existing.ip_hash,
                ip_masked: batch.ip_masked || existing.ip_masked,
                received_at: batch.received_at
            }

            {Map.put(acc, key, combined), order}

          :error ->
            {Map.put(acc, key, batch), [key | order]}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(merged, &1))
  end
end
