defmodule WebAnalytics.Geo do
  @moduledoc """
  Resolves a visitor to a city, region and country.

  Three sources are tried in descending order of precision:

  1. **CDN headers.** If the request came through Cloudflare, Vercel, CloudFront
     or Netlify, the edge already resolved the location closer to the client and
     with better data than a local database.
  2. **A local MaxMind-format database.** City-level, offline, no rate limit and
     no third party sees your visitors' addresses.
  3. **The browser's time zone.** Country only, and never a city — a zone name
     like `America/Los_Angeles` names the zone's reference city, not the
     visitor's. This exists so a deployment with no database and no CDN still
     gets something useful.

  Resolution happens at ingest, in the request that carries the address, and the
  address itself is never stored — only the city, region and country it resolved
  to. That ordering is the point: the raw IP exists in memory for the length of
  one lookup and is then gone.
  """

  alias WebAnalytics.Geo.Countries
  alias WebAnalytics.Geo.Database
  alias WebAnalytics.Geo.Headers
  alias WebAnalytics.Geo.MMDB

  @empty %{
    country_code: nil,
    country: nil,
    region: nil,
    region_code: nil,
    county: nil,
    city: nil,
    latitude: nil,
    longitude: nil,
    accuracy_km: nil,
    source: nil
  }

  @doc "An empty location, for when nothing could be resolved."
  def empty, do: @empty

  @doc """
  Resolves a location from whatever is available.

  ## Options

    * `:headers` — the request headers, for CDN geolocation
    * `:ip` — the client address, as a string or `:inet` tuple
    * `:timezone` — the IANA zone the tracker reported, as a last resort
  """
  def resolve(opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    ip = Keyword.get(opts, :ip)
    timezone = Keyword.get(opts, :timezone)

    location =
      from_headers(headers) || from_database(ip) || from_timezone(timezone) || @empty

    fill_country_name(location)
  end

  @doc "Looks up an address in the local database only."
  def lookup_ip(nil), do: nil

  def lookup_ip(ip) do
    with false <- private?(ip),
         db when not is_nil(db) <- Database.get(),
         {:ok, record} <- MMDB.lookup(db, ip) do
      from_record(record)
    else
      _ -> nil
    end
  end

  @doc """
  Whether an address is private, loopback, or otherwise unroutable.

  Worth checking before a lookup: these never appear in a GeoIP database, and in
  development every request comes from one.
  """
  def private?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> private?(parsed)
      {:error, _} -> true
    end
  end

  def private?({10, _, _, _}), do: true
  def private?({127, _, _, _}), do: true
  def private?({0, _, _, _}), do: true
  def private?({169, 254, _, _}), do: true
  def private?({192, 168, _, _}), do: true
  def private?({172, second, _, _}) when second in 16..31, do: true
  def private?({100, second, _, _}) when second in 64..127, do: true
  def private?({a, _, _, _}) when a >= 224, do: true
  def private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # fc00::/7 unique-local and fe80::/10 link-local.
  def private?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF, do: true
  def private?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEBF, do: true
  def private?({_, _, _, _}), do: false
  def private?({_, _, _, _, _, _, _, _}), do: false
  def private?(_), do: true

  defp from_headers([]), do: nil
  defp from_headers(headers), do: Headers.resolve(headers)

  defp from_database(nil), do: nil
  defp from_database(ip), do: lookup_ip(ip)

  # Country-only, and explicitly marked as a guess so the dashboard can say so.
  defp from_timezone(nil), do: nil

  defp from_timezone(timezone) do
    case Countries.country_for_zone(timezone) do
      nil -> nil
      code -> %{@empty | country_code: code, source: "timezone"}
    end
  end

  # DB-IP and MaxMind share a record shape, so one extractor serves both.
  defp from_record(record) when is_map(record) do
    country = record["country"] || record["registered_country"] || %{}
    location = record["location"] || %{}
    subdivision = record["subdivisions"] |> List.wrap() |> List.first() || %{}

    %{
      country_code: upcase(country["iso_code"]),
      country: name_of(country),
      region: name_of(subdivision),
      region_code: subdivision["iso_code"],
      # GeoIP databases stop at the first-level subdivision.
      county: nil,
      city: record["city"] |> Kernel.||(%{}) |> name_of(),
      latitude: to_float(location["latitude"]),
      longitude: to_float(location["longitude"]),
      accuracy_km: location["accuracy_radius"],
      source: "mmdb"
    }
    |> nilify_blanks()
  end

  defp from_record(_record), do: nil

  # Every name in these databases is a map of language to translation.
  defp name_of(%{"names" => names}) when is_map(names) do
    names["en"] || names["en-US"] || names |> Map.values() |> List.first()
  end

  defp name_of(_), do: nil

  # A country code is always present; the name is filled in from the ISO table
  # when the source only gave a code.
  defp fill_country_name(%{country_code: nil} = location), do: location

  defp fill_country_name(%{country: nil, country_code: code} = location) do
    %{location | country: Countries.name(code)}
  end

  defp fill_country_name(location), do: location

  defp nilify_blanks(location) do
    Map.new(location, fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
  end

  defp upcase(nil), do: nil
  defp upcase(value) when is_binary(value), do: String.upcase(value)
  defp upcase(_), do: nil

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1
  defp to_float(_), do: nil
end
