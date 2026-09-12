defmodule WebAnalytics.LocationsTest do
  use WebAnalytics.DataCase, async: true

  import WebAnalytics.Fixtures

  alias WebAnalytics.Analytics
  alias WebAnalytics.Geo
  alias WebAnalytics.Ingest
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Session

  setup do
    %{site: site_fixture()}
  end

  defp submit(site, events, opts) do
    {:ok, id} =
      Ingest.submit_sync(
        site,
        payload(site, events, Keyword.take(opts, [:token])),
        Keyword.merge([received_at: DateTime.utc_now()], Keyword.take(opts, [:location]))
      )

    id
  end

  defp location(overrides) do
    Map.merge(
      %{
        Geo.empty()
        | country_code: "US",
          country: "United States",
          region: "California",
          region_code: "CA",
          city: "Mountain View",
          latitude: 37.422,
          longitude: -122.085,
          accuracy_km: 20,
          source: "mmdb"
      },
      overrides
    )
  end

  test "stores the resolved location on the session", %{site: site} do
    id =
      submit(site, [init_event(), pageview_event(1, "/")],
        location: location(%{}),
        token: "geo-1"
      )

    session = Repo.get!(Session, id)

    assert session.country_code == "US"
    assert session.country == "United States"
    assert session.region == "California"
    assert session.region_code == "CA"
    assert session.city == "Mountain View"
    assert session.latitude == 37.422
    assert session.accuracy_km == 20
    assert session.geo_source == "mmdb"
  end

  test "never stores the address itself", %{site: site} do
    address = "203.0.113.45"

    {:ok, id} =
      Ingest.submit_sync(
        site,
        payload(site, [init_event(), pageview_event(1, "/")], token: "geo-ip"),
        received_at: DateTime.utc_now(),
        location: location(%{}),
        ip_hash: Ingest.hash_ip(address, site)
      )

    session = Repo.get!(Session, id)

    # The schema has nowhere to put an address, and the hash that stands in for
    # one is not reversible to it.
    refute :ip in Session.__schema__(:fields)
    refute :ip_address in Session.__schema__(:fields)
    assert session.ip_hash =~ ~r/^[0-9a-f]{32}$/

    # Whole octets and the whole address, not a three-character fragment of one:
    # "203" turns up in a random 32-character hex string about once every
    # hundred-odd runs, which made this assertion a coincidence detector rather
    # than a privacy one.
    refute session.ip_hash =~ address
    refute session.ip_hash =~ String.replace(address, ".", "")

    stored =
      session
      |> Map.from_struct()
      |> Map.drop([:__meta__, :browser_version])
      |> Map.values()
      |> Enum.filter(&is_binary/1)

    refute Enum.any?(stored, &(&1 =~ ~r/\b\d{1,3}(\.\d{1,3}){3}\b/))
  end

  test "keeps the first location even if a later beacon reports another", %{site: site} do
    submit(site, [init_event(), pageview_event(1, "/")],
      location: location(%{}),
      token: "geo-stable"
    )

    # A visitor switching networks mid-visit must not relocate the whole session.
    id =
      submit(site, [tick_event(1)],
        location:
          location(%{country_code: "JP", country: "Japan", city: "Tokyo", region: "Tokyo"}),
        token: "geo-stable"
      )

    session = Repo.get!(Session, id)
    assert session.country_code == "US"
    assert session.city == "Mountain View"
  end

  test "falls back to the reported time zone when nothing better is available", %{site: site} do
    id =
      submit(site, [init_event(%{"tz" => "Europe/Lisbon"}), pageview_event(1, "/")],
        location: Geo.empty(),
        token: "geo-tz"
      )

    session = Repo.get!(Session, id)

    assert session.country_code == "PT"
    assert session.country == "Portugal"
    assert session.geo_source == "timezone"
    assert session.city == nil
  end

  test "prefers a real fix over the time-zone guess", %{site: site} do
    id =
      submit(site, [init_event(%{"tz" => "Europe/Lisbon"}), pageview_event(1, "/")],
        location: location(%{}),
        token: "geo-both"
      )

    session = Repo.get!(Session, id)
    assert session.country_code == "US"
    assert session.geo_source == "mmdb"
  end

  describe "reporting" do
    setup %{site: site} do
      places = [
        {location(%{}), 3},
        {location(%{city: "San Francisco", region: "California"}), 2},
        {location(%{
           country_code: "CA",
           country: "Canada",
           region: "Quebec",
           region_code: "QC",
           city: "Montreal"
         }), 2},
        {location(%{
           country_code: "DE",
           country: "Germany",
           region: "Berlin",
           region_code: "BE",
           city: "Berlin"
         }), 1}
      ]

      for {place, count} <- places, index <- 1..count do
        token = "#{place.city}-#{index}"

        submit(site, [init_event(), pageview_event(1, "/"), tick_event(1)],
          location: place,
          token: token
        )
      end

      # One session that could not be placed at all.
      submit(site, [pageview_event(1, "/")], location: Geo.empty(), token: "unplaced")

      %{filters: Analytics.filters(site.id, %{range: "30d"})}
    end

    test "groups by country", %{filters: f} do
      rows = Analytics.locations(f, :country)

      assert [%{country_code: "US", count: 5}, %{country_code: "CA", count: 2} | _] = rows
      assert Enum.find(rows, &(&1.country_code == "US")).label == "United States"
    end

    test "groups by state or province", %{filters: f} do
      rows = Analytics.locations(f, :region)
      california = Enum.find(rows, &(&1.region == "California"))

      assert california.count == 5
      assert california.label == "California, United States"
      assert Enum.any?(rows, &(&1.region == "Quebec"))
    end

    test "groups by county when a caller supplied one", %{site: site, filters: f} do
      # Only a caller can supply county; no GeoIP database carries it.
      submit(site, [init_event(), pageview_event(1, "/")],
        location: location(%{county: "Santa Clara"}),
        token: "county-1"
      )

      rows = Analytics.locations(f, :county)

      assert [%{county: "Santa Clara", count: 1, label: label}] = rows
      assert label == "Santa Clara, California, United States"
    end

    test "groups by city", %{filters: f} do
      rows = Analytics.locations(f, :city)
      top = List.first(rows)

      assert top.city == "Mountain View"
      assert top.count == 3
      assert top.label == "Mountain View, California, United States"
      assert Enum.any?(rows, &(&1.city == "Berlin"))
    end

    test "reports how much traffic could be placed, and how precisely", %{filters: f} do
      coverage = Analytics.geo_coverage(f)

      assert coverage.sessions == 9
      assert coverage.located == 8
      assert coverage.with_city == 8
      assert coverage.city_rate > 88.0
      # No county in the fixtures, and the report says so rather than implying it.
      assert coverage.with_county == 0
      assert coverage.county_rate == 0.0
      assert [%{name: "mmdb", count: 8}] = coverage.sources
    end

    test "returns coordinates for plotting", %{filters: f} do
      points = Analytics.location_points(f)

      assert Enum.all?(points, &(is_float(&1.latitude) and is_float(&1.longitude)))
      assert Enum.sum(Enum.map(points, & &1.count)) == 8
    end

    test "leaves unplaceable sessions out of location rows rather than bucketing them", %{
      filters: f
    } do
      # They are still counted in coverage, which is the honest place to say so.
      assert Enum.sum(Enum.map(Analytics.locations(f, :country), & &1.count)) == 8
      assert Analytics.geo_coverage(f).sessions == 9
    end
  end
end
