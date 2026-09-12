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

  Full addresses are never stored. This exists so anomaly scoring can spot a
  single origin spraying sessions, and it stops being linkable after a day. See
  `mask_ip/1` for the other, human-readable thing kept about an address.
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

  @doc """
  An address with everything between its first and last group masked out.

  `203.0.113.42` becomes `203.•••.•••.42`. This is the one piece of address
  data the system stores, and it is masked in the request that carried it — the
  full value is never written anywhere, so there is nothing to unmask later.

  The mask is a fixed width rather than one dot per digit, so it does not leak
  how long the hidden groups were. Worth being straight about what it does not
  conceal: the last group is the most identifying part of an address, and
  keeping it reveals more than the usual /24 anonymisation, which throws the
  tail away instead.
  """
  def mask_ip(nil), do: nil

  def mask_ip(ip) when is_binary(ip) do
    case String.trim(ip) do
      "" -> nil
      trimmed -> mask_groups(trimmed)
    end
  end

  def mask_ip(_), do: nil

  # IPv4 is dot-separated and IPv6 colon-separated, and the rule is the same
  # either way: keep the ends, hide the middle, keep the separators so it still
  # reads as an address.
  #
  # The exception is an IPv4-mapped IPv6 address — `::ffff:203.0.113.42`, which
  # is the form a socket reports for an IPv4 client on a dual-stack listener,
  # so it is the normal case rather than an oddity. Its last colon-group is an
  # entire IPv4 address, and "keep the ends" would have kept all of it. Masking
  # the mapped address on its own terms is the whole point of this clause.
  defp mask_groups(ip) do
    if String.contains?(ip, ":") and String.contains?(ip, ".") do
      ip |> String.split(":") |> List.last() |> mask_separated(".")
    else
      mask_separated(ip, if(String.contains?(ip, ":"), do: ":", else: "."))
    end
  end

  # Kept groups are zero-padded to their full width, so every masked address is
  # the same length and a column of them lines up: 8.8.8.8 reads 008.•••.•••.008
  # rather than 8.•••.•••.8. The padding says nothing the address did not
  # already say — a group is three digits in IPv4 and four in IPv6 whether or
  # not it is written that way.
  defp pad(group, separator) do
    width = if separator == ":", do: 4, else: 3
    String.pad_leading(group, width, "0")
  end

  defp mask_separated(ip, separator) do
    case String.split(ip, separator) do
      # Nothing to hide between the ends, so hide everything past the first
      # group. Storing an address whole is the one outcome this prevents.
      [only] ->
        String.slice(only, 0, 1) <> "•••"

      [first, _last] ->
        pad(first, separator) <> separator <> "•••"

      [first | rest] ->
        middle = rest |> Enum.drop(-1) |> Enum.map(fn _ -> "•••" end)

        Enum.join(
          [pad(first, separator) | middle] ++ [pad(List.last(rest), separator)],
          separator
        )
    end
  end

  defp put_settings(site, opts) do
    Keyword.put_new_lazy(opts, :settings, fn -> Sites.settings_for(site) end)
  end
end
