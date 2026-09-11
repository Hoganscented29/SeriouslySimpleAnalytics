defmodule WebAnalytics.RateLimiter do
  @moduledoc """
  A fixed-window counter, used to keep unauthenticated write endpoints cheap to
  serve and expensive to abuse.

  Counts live in ETS keyed by `{bucket, window}`, so a new window costs nothing
  to start and old ones are swept on a timer rather than on every request. This
  is deliberately per-node: the limits here exist to stop a script, not a
  distributed attacker, and coordinating counters across a cluster would cost
  more than the abuse it prevents.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records one hit against `bucket` and says whether it is still under `limit`
  for the current window.

  Returns `:ok`, or `{:error, retry_after_seconds}` once the window is full.
  """
  def hit(bucket, limit, window_ms, now_ms \\ System.system_time(:millisecond)) do
    window = div(now_ms, window_ms)
    key = {bucket, window}
    expires_at = (window + 1) * window_ms

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, expires_at})

    if count <= limit do
      :ok
    else
      elapsed = rem(now_ms, window_ms)
      {:error, max(1, ceil((window_ms - elapsed) / 1000))}
    end
  end

  @doc "Drops every counter. Test support."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # A window that has closed can never be read again. Windows differ in length
    # between callers, so rows carry their own expiry rather than a window index
    # the sweep would have to interpret.
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
