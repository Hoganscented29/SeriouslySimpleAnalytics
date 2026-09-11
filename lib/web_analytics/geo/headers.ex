defmodule WebAnalytics.Geo.Headers do
  @moduledoc """
  Reads location from the geolocation headers a CDN or edge platform adds.

  When a request has already passed through Cloudflare, Vercel, CloudFront or
  Netlify, the edge has resolved the visitor's location from a better vantage
  point than this server has — closer to the client, with commercial data — and
  it costs nothing to use. So these headers are preferred over a local database
  lookup when present.

  They are only trusted because they are assumed to be set by infrastructure the
  operator controls: anything in front of the app can forge them, exactly like
  `x-forwarded-for`. Since the worst outcome is a mislabelled city on a chart,
  that trade is acceptable — but it is why nothing here feeds an access decision.
  """

  @doc """
  Extracts location from request headers.

  Returns a location map, or `nil` when no recognised headers are present.
  """
  def resolve(headers) when is_list(headers) do
    lookup = Map.new(headers, fn {key, value} -> {String.downcase(key), value} end)

    cloudflare(lookup) || vercel(lookup) || cloudfront(lookup) || netlify(lookup) ||
      generic(lookup)
  end

  def resolve(_headers), do: nil

  defp cloudflare(headers) do
    build(headers, "cloudflare",
      country: "cf-ipcountry",
      city: "cf-ipcity",
      region: "cf-region",
      region_code: "cf-region-code",
      latitude: "cf-iplatitude",
      longitude: "cf-iplongitude"
    )
  end

  defp vercel(headers) do
    build(headers, "vercel",
      country: "x-vercel-ip-country",
      city: "x-vercel-ip-city",
      region_code: "x-vercel-ip-country-region",
      latitude: "x-vercel-ip-latitude",
      longitude: "x-vercel-ip-longitude"
    )
  end

  defp cloudfront(headers) do
    build(headers, "cloudfront",
      country: "cloudfront-viewer-country",
      country_name: "cloudfront-viewer-country-name",
      city: "cloudfront-viewer-city",
      region: "cloudfront-viewer-country-region-name",
      region_code: "cloudfront-viewer-country-region",
      latitude: "cloudfront-viewer-latitude",
      longitude: "cloudfront-viewer-longitude"
    )
  end

  # Netlify packs everything into one base64 JSON header.
  defp netlify(headers) do
    with value when is_binary(value) <- Map.get(headers, "x-nf-geo"),
         {:ok, json} <- Base.decode64(value, padding: false),
         {:ok, %{} = geo} <- Jason.decode(json) do
      country = geo["country"] || %{}
      subdivision = geo["subdivision"] || %{}
      location = geo["location"] || %{}

      present(%{
        country_code: upcase(country["code"]),
        country: country["name"],
        region: subdivision["name"],
        region_code: subdivision["code"],
        city: geo["city"],
        latitude: to_float(location["latitude"]),
        longitude: to_float(location["longitude"]),
        source: "netlify"
      })
    else
      _ -> nil
    end
  end

  # Fastly and most reverse proxies have no fixed names, so operators are
  # expected to set these when they configure geolocation themselves.
  defp generic(headers) do
    build(headers, "headers",
      country: "x-geo-country",
      city: "x-geo-city",
      region: "x-geo-region",
      region_code: "x-geo-region-code",
      latitude: "x-geo-latitude",
      longitude: "x-geo-longitude"
    )
  end

  defp build(headers, source, keys) do
    country = headers |> Map.get(keys[:country]) |> upcase()

    # Cloudflare uses these for requests it cannot place, and for its own probes.
    if is_nil(country) or country in ["XX", "T1"] do
      nil
    else
      present(%{
        country_code: country,
        country: clean(headers[keys[:country_name]]),
        region: clean(headers[keys[:region]]),
        region_code: clean(headers[keys[:region_code]]),
        city: clean(headers[keys[:city]]),
        latitude: to_float(headers[keys[:latitude]]),
        longitude: to_float(headers[keys[:longitude]]),
        source: source
      })
    end
  end

  defp present(location) do
    if location.country_code, do: location, else: nil
  end

  # Vercel percent-encodes city names ("San%20Francisco").
  defp clean(nil), do: nil

  defp clean(value) when is_binary(value) do
    decoded =
      case URI.decode(value) do
        decoded when is_binary(decoded) -> decoded
        _ -> value
      end

    case String.trim(decoded) do
      "" -> nil
      trimmed -> trimmed
    end
  rescue
    ArgumentError -> nil
  end

  defp clean(_), do: nil

  defp upcase(nil), do: nil

  defp upcase(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      "" -> nil
      upcased -> upcased
    end
  end

  defp upcase(_), do: nil

  defp to_float(nil), do: nil
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp to_float(_), do: nil
end
