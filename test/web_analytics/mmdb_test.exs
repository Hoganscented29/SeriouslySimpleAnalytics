defmodule WebAnalytics.Geo.MMDBTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.Geo.MMDB
  alias WebAnalytics.MMDBBuilder

  @left %{"country" => %{"iso_code" => "US", "names" => %{"en" => "United States"}}}
  @right %{"country" => %{"iso_code" => "JP", "names" => %{"en" => "Japan"}}}

  defp database(opts \\ []) do
    path = MMDBBuilder.build(@left, @right, opts) |> MMDBBuilder.write!()
    on_exit(fn -> File.rm(path) end)
    {:ok, db} = MMDB.load(path)
    db
  end

  test "reads the metadata block" do
    db = database()

    assert db.node_count == 1
    assert db.record_size == 32
    assert db.ip_version == 4
    assert db.database_type == "Test-City"
    assert MMDB.describe(db) =~ "Test-City"
  end

  test "walks the tree on the address bits" do
    db = database()

    # A leading 0 bit goes left, a leading 1 bit goes right.
    assert {:ok, %{"country" => %{"iso_code" => "US"}}} = MMDB.lookup(db, {10, 0, 0, 1})
    assert {:ok, %{"country" => %{"iso_code" => "JP"}}} = MMDB.lookup(db, {200, 0, 0, 1})
  end

  test "decodes nested maps and strings" do
    db = database()
    {:ok, record} = MMDB.lookup(db, {1, 2, 3, 4})

    assert get_in(record, ["country", "names", "en"]) == "United States"
  end

  for size <- [24, 28, 32] do
    test "handles #{size}-bit records" do
      db = database(record_size: unquote(size))

      assert {:ok, %{"country" => %{"iso_code" => "US"}}} = MMDB.lookup(db, {10, 0, 0, 1})
      assert {:ok, %{"country" => %{"iso_code" => "JP"}}} = MMDB.lookup(db, {200, 0, 0, 1})
    end
  end

  test "accepts an address as a string" do
    db = database()
    assert {:ok, %{"country" => %{"iso_code" => "US"}}} = MMDB.lookup(db, "10.0.0.1")
  end

  test "returns :not_found for an unparseable address" do
    db = database()
    assert MMDB.lookup(db, "not an address") == :not_found
  end

  test "returns :not_found for IPv6 against an IPv4 database" do
    db = database()
    assert MMDB.lookup(db, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == :not_found
  end

  test "reports a missing file rather than raising" do
    assert {:error, :enoent} = MMDB.load("/nonexistent/does-not-exist.mmdb")
  end

  test "reports a file that is not a database" do
    path = MMDBBuilder.write!(:binary.copy(<<0>>, 4096))
    on_exit(fn -> File.rm(path) end)

    assert {:error, :metadata_not_found} = MMDB.load(path)
  end

  describe "against the real database" do
    @describetag :geoip

    setup do
      path = WebAnalytics.Geo.Database.path()

      if File.exists?(path) do
        {:ok, db} = MMDB.load(path)
        %{db: db}
      else
        # The database is ~120MB and fetched with `mix geoip.download`, so it is
        # not a checked-in fixture; these checks simply do not run without it.
        :ok
      end
    end

    test "places well-known addresses", context do
      if db = context[:db] do
        assert {:ok, record} = MMDB.lookup(db, "8.8.8.8")
        assert get_in(record, ["country", "iso_code"]) == "US"
        assert get_in(record, ["city", "names", "en"]) =~ "Mountain View"

        assert {:ok, sydney} = MMDB.lookup(db, "1.1.1.1")
        assert get_in(sydney, ["country", "iso_code"]) == "AU"
      end
    end

    test "does not place private addresses", context do
      if db = context[:db] do
        assert MMDB.lookup(db, "127.0.0.1") == :not_found
        assert MMDB.lookup(db, "192.168.1.1") == :not_found
      end
    end
  end
end
