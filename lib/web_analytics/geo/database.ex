defmodule WebAnalytics.Geo.Database do
  @moduledoc """
  Owns the loaded GeoIP database.

  The database is put in `:persistent_term` rather than kept in this process's
  state. Lookups then need no message round trip and no copying — every request
  reads the same shared binary directly. That matters because the alternative,
  a GenServer call per beacon, would serialise the entire ingest path through
  one process and copy a result out of it every time.

  Loading is best-effort and never fatal: with no database file the app runs
  exactly as before, and location falls back to CDN headers or the visitor's
  time zone.
  """
  use GenServer

  require Logger

  alias WebAnalytics.Geo.MMDB

  @key {__MODULE__, :db}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The loaded database, or nil when none is available."
  @spec get() :: MMDB.t() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc "Whether a database is loaded."
  def loaded?, do: get() != nil

  @doc "A one-line description of what is loaded, for the dashboard and logs."
  def describe do
    case get() do
      nil -> "no database loaded"
      db -> MMDB.describe(db)
    end
  end

  @doc "Reloads from disk. Returns `{:ok, description}` or `{:error, reason}`."
  def reload, do: GenServer.call(__MODULE__, :reload, 60_000)

  @doc "Configured path to the database file."
  def path do
    configured =
      Application.get_env(:web_analytics, :geoip, [])
      |> Keyword.get(:path, "priv/geoip/dbip-city-lite.mmdb")

    if Path.type(configured) == :absolute do
      configured
    else
      # Resolve against the app directory so it works from a release too, and
      # fall back to the source tree during development.
      release_path = Path.join(Application.app_dir(:web_analytics), configured)
      if File.exists?(release_path), do: release_path, else: Path.expand(configured)
    end
  end

  @impl true
  def init(_opts) do
    # Loading ~120MB of database blocks the supervisor, so it happens after init
    # and the app starts serving immediately either way.
    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    load()
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, load(), state}
  end

  defp load do
    file = path()

    if File.exists?(file) do
      case MMDB.load(file) do
        {:ok, db} ->
          :persistent_term.put(@key, db)
          description = MMDB.describe(db)
          Logger.info("GeoIP database loaded: #{description}")
          {:ok, description}

        {:error, reason} ->
          Logger.warning("GeoIP database at #{file} could not be read: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.info("No GeoIP database at #{file}; run `mix geoip.download` for city-level data")
      {:error, :enoent}
    end
  end
end
