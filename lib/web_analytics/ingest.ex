defmodule WebAnalytics.Ingest do
  @moduledoc """
  Entry point for tracker beacons.

  `submit/3` validates and queues; `submit_sync/3` skips the buffer and writes
  immediately, which is what tests and backfills want.
  """

  alias WebAnalytics.Ingest.Collector
  alias WebAnalytics.Ingest.Normalizer
  alias WebAnalytics.Ingest.Processor
  alias WebAnalytics.Sites

  @doc """
  Normalises `payload` for `site` and queues it for writing.

  Returns `:ok`, `:dropped` when the write buffer is saturated, or
  `{:error, reason}` when the payload is unusable.
  """
  def submit(site, payload, opts \\ []) do
    case Normalizer.normalize(site, payload, put_settings(site, opts)) do
      {:ok, batch} -> Collector.enqueue(batch)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Like `submit/3` but writes synchronously, bypassing the buffer."
  def submit_sync(site, payload, opts \\ []) do
    case Normalizer.normalize(site, payload, put_settings(site, opts)) do
      {:ok, batch} -> Processor.apply_batch(batch)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes everything currently buffered."
  defdelegate flush, to: Collector, as: :flush_sync

  @doc """
  Resolves a visitor's location from the request.

  Done here, in the request that carries the address, so the address itself is
  never handed to the write path — only the city, region and country it resolved
  to.
  """
  def locate(headers, ip) do
    WebAnalytics.Geo.resolve(headers: headers, ip: ip)
  end

  @doc """
  Salted, day-rotating hash of a client IP.

  Raw addresses are never stored — this exists only so anomaly scoring can spot
  a single origin spraying sessions, and it stops being linkable after a day.
  """
  def hash_ip(nil, _site), do: nil

  def hash_ip(ip, site) when is_binary(ip) do
    salt = Application.get_env(:web_analytics, :ip_salt, "web-analytics-dev-salt")
    day = Date.utc_today() |> Date.to_iso8601()

    :sha256
    |> :crypto.hash([salt, "|", site.key, "|", day, "|", ip])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  def hash_ip(_, _), do: nil

  defp put_settings(site, opts) do
    Keyword.put_new_lazy(opts, :settings, fn -> Sites.settings_for(site) end)
  end
end
