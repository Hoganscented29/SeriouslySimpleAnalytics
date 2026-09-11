defmodule WebAnalytics.GeoTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.Geo
  alias WebAnalytics.Geo.Countries
  alias WebAnalytics.Geo.Headers

  describe "CDN headers" do
    test "reads Cloudflare" do
      location =
        Headers.resolve([
          {"CF-IPCountry", "GB"},
          {"cf-ipcity", "London"},
          {"cf-region", "England"},
          {"cf-region-code", "ENG"},
          {"cf-iplatitude", "51.5074"},
          {"cf-iplongitude", "-0.1278"}
        ])

      assert location.country_code == "GB"
      assert location.city == "London"
      assert location.region == "England"
      assert location.region_code == "ENG"
      assert location.latitude == 51.5074
      assert location.source == "cloudflare"
    end

    test "reads Vercel and decodes its percent-encoded city" do
      location =
        Headers.resolve([
          {"x-vercel-ip-country", "FR"},
          {"x-vercel-ip-city", "Paris%2007"},
          {"x-vercel-ip-country-region", "IDF"}
        ])

      assert location.country_code == "FR"
      assert location.city == "Paris 07"
      assert location.region_code == "IDF"
      assert location.source == "vercel"
    end

    test "reads CloudFront" do
      location =
        Headers.resolve([
          {"cloudfront-viewer-country", "jp"},
          {"cloudfront-viewer-city", "Tokyo"},
          {"cloudfront-viewer-country-region-name", "Tokyo"}
        ])

      assert location.country_code == "JP"
      assert location.city == "Tokyo"
      assert location.source == "cloudfront"
    end

    test "reads Netlify's packed header" do
      payload =
        Jason.encode!(%{
          "country" => %{"code" => "SE", "name" => "Sweden"},
          "subdivision" => %{"code" => "AB", "name" => "Stockholm"},
          "city" => "Stockholm",
          "location" => %{"latitude" => 59.33, "longitude" => 18.06}
        })

      location = Headers.resolve([{"x-nf-geo", Base.encode64(payload, padding: false)}])

      assert location.country_code == "SE"
      assert location.city == "Stockholm"
      assert location.region == "Stockholm"
      assert location.latitude == 59.33
      assert location.source == "netlify"
    end

    test "reads generic proxy headers" do
      location = Headers.resolve([{"x-geo-country", "NL"}, {"x-geo-city", "Utrecht"}])

      assert location.country_code == "NL"
      assert location.source == "headers"
    end

    test "ignores Cloudflare's placeholder countries" do
      assert Headers.resolve([{"cf-ipcountry", "XX"}]) == nil
      assert Headers.resolve([{"cf-ipcountry", "T1"}]) == nil
    end

    test "returns nil when nothing recognisable is present" do
      assert Headers.resolve([{"user-agent", "curl"}, {"accept", "*/*"}]) == nil
      assert Headers.resolve([]) == nil
      assert Headers.resolve(nil) == nil
    end
  end

  describe "resolve/1 precedence" do
    test "prefers CDN headers over everything else" do
      location =
        Geo.resolve(
          headers: [{"cf-ipcountry", "DE"}, {"cf-ipcity", "Berlin"}],
          ip: "8.8.8.8",
          timezone: "Asia/Tokyo"
        )

      assert location.country_code == "DE"
      assert location.city == "Berlin"
      assert location.source == "cloudflare"
    end

    test "falls back to the time zone for country only" do
      location = Geo.resolve(ip: "127.0.0.1", timezone: "Australia/Sydney")

      assert location.country_code == "AU"
      assert location.country == "Australia"
      assert location.source == "timezone"
      # A zone names its own reference city, not the visitor's, so it must never
      # be presented as one.
      assert location.city == nil
      assert location.region == nil
    end

    test "fills in the country name from the ISO table when only a code is given" do
      location = Geo.resolve(headers: [{"cf-ipcountry", "PT"}])
      assert location.country == "Portugal"
    end

    test "returns an empty location when nothing can be resolved" do
      assert Geo.resolve() == Geo.empty()
      assert Geo.resolve(ip: "192.168.1.1").country_code == nil
      assert Geo.resolve(timezone: "Not/AZone").country_code == nil
    end
  end

  describe "private?/1" do
    test "recognises unroutable addresses" do
      for ip <- [
            "10.1.2.3",
            "127.0.0.1",
            "192.168.0.1",
            "172.16.5.4",
            "172.31.255.255",
            "169.254.1.1",
            "100.64.0.1",
            "0.0.0.0",
            "224.0.0.1",
            "::1",
            "fd00::1",
            "fe80::1"
          ] do
        assert Geo.private?(ip), "expected #{ip} to be private"
      end
    end

    test "lets public addresses through" do
      for ip <- ["8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.0.1", "2001:4860:4860::8888"] do
        refute Geo.private?(ip), "expected #{ip} to be public"
      end
    end

    test "treats anything unparseable as private, so it is never looked up" do
      assert Geo.private?("nonsense")
      assert Geo.private?(nil)
    end
  end

  describe "country and time-zone tables" do
    test "covers the ISO country list" do
      assert Countries.count() > 240
      assert Countries.name("US") == "United States"
      assert Countries.name("jp") == "Japan"
      assert Countries.name("ZZ") == nil
      assert Countries.known?("FR")
      refute Countries.known?("ZZ")
    end

    test "uses conventional names rather than the tz database's abbreviations" do
      assert Countries.name("GB") == "United Kingdom"
      assert Countries.name("KR") == "South Korea"
      assert Countries.name("CZ") == "Czechia"
    end

    test "maps time zones to countries, including legacy aliases" do
      assert Countries.zone_count() > 400
      assert Countries.country_for_zone("America/New_York") == "US"
      assert Countries.country_for_zone("Europe/Kyiv") == "UA"
      assert Countries.country_for_zone("Europe/Kiev") == "UA"
      assert Countries.country_for_zone("Asia/Calcutta") == "IN"
      assert Countries.country_for_zone("US/Pacific") == "US"
      assert Countries.country_for_zone("Mars/Olympus") == nil
      assert Countries.country_for_zone(nil) == nil
    end
  end
end
