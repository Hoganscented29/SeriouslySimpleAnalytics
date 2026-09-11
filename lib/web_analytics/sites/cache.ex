defmodule WebAnalytics.Sites.Cache do
  @moduledoc """
  ETS-backed cache of site key => `%Site{}`, owned by this process so the table
  dies with it rather than leaking across restarts.
  """
  use GenServer

  @table :web_analytics_site_cache
  @ttl_ms :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether caching is on.

  Disabled under test: the cache outlives a sandbox transaction, so a site
  created and rolled back by one test would still be served — with an id that no
  longer exists — to the next test that asks for the same key.
  """
  def enabled? do
    Application.get_env(:web_analytics, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc "Returns `{:ok, site}` on a live hit, `:miss` otherwise."
  def get(key) do
    if enabled?(), do: lookup(key), else: :miss
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, site, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, site}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put(key, site) do
    if enabled?() do
      expires_at = System.monotonic_time(:millisecond) + @ttl_ms
      :ets.insert(@table, {key, site, expires_at})
    end

    site
  rescue
    ArgumentError -> site
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
