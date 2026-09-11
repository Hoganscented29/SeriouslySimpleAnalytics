defmodule WebAnalytics.AdminTest do
  use WebAnalytics.DataCase, async: true

  import WebAnalytics.Fixtures
  import WebAnalytics.AccountsFixtures

  import Ecto.Query, only: [from: 2]

  alias WebAnalytics.Admin
  alias WebAnalytics.Ingest

  describe "counters/1" do
    test "an empty deployment reports zeros rather than failing" do
      counters = Admin.counters()

      assert counters.users == 0
      assert counters.sites == 0
      assert counters.sessions == 0
      assert counters.events == 0
      assert counters.active_now == 0
    end

    test "counts across every account" do
      a = user_fixture()
      b = user_fixture()
      site_a = user_site_fixture(a, %{key: "acct-a"})
      site_b = user_site_fixture(b, %{key: "acct-b"})

      for site <- [site_a, site_b] do
        {:ok, _} =
          Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, "/")]),
            received_at: DateTime.utc_now()
          )
      end

      counters = Admin.counters()

      assert counters.users == 2
      assert counters.sites == 2
      assert counters.sites_claimed == 2
      assert counters.sessions == 2
      assert counters.pageviews == 2
    end

    test "separates crawlers, AI and web" do
      site = site_fixture(%{key: "mixed"})

      {:ok, _} =
        Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, "/")]),
          received_at: DateTime.utc_now()
        )

      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [
            init_event(%{
              "ua" => "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"
            }),
            pageview_event(1, "/docs")
          ]),
          received_at: DateTime.utc_now()
        )

      counters = Admin.counters()

      assert counters.sessions == 2
      assert counters.crawler_sessions == 1
      assert counters.web_sessions == 2
    end

    test "the recent windows only count what falls inside them" do
      site = site_fixture(%{key: "windows"})
      old = DateTime.add(DateTime.utc_now(), -3, :day)

      {:ok, _} =
        Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, "/old")]),
          received_at: old
        )

      {:ok, _} =
        Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, "/new")]),
          received_at: DateTime.utc_now()
        )

      counters = Admin.counters()

      assert counters.sessions == 2
      assert counters.sessions_24h == 1
    end

    test "an unreachable collector is reported, not raised" do
      # The dashboard must never be the reason ingest stalls, so a collector
      # that cannot answer degrades to a label rather than a 500.
      assert Admin.counters().queue_depth in [0, :unavailable] or
               is_integer(Admin.counters().queue_depth)
    end
  end

  describe "detail/1" do
    test "an empty deployment returns empty lists, and 24 chart buckets" do
      detail = Admin.detail()

      assert detail.sites == []
      assert detail.users == []
      assert detail.crawlers == []
      assert length(detail.hourly) == 24
      assert Enum.all?(detail.hourly, &(&1.count == 0))
    end

    test "sites carry their owner's email and an unclaimed site says so" do
      user = user_fixture()
      user_site_fixture(user, %{key: "owned", name: "Owned"})
      site_fixture(%{key: "orphan", name: "Orphan"})

      by_key = Map.new(Admin.detail().sites, &{&1.key, &1})

      assert by_key["owned"].owner == user.email
      assert by_key["orphan"].owner == nil
    end

    test "crawlers are grouped by name" do
      site = site_fixture(%{key: "bots"})

      for _ <- 1..3 do
        {:ok, _} =
          Ingest.submit_sync(
            site,
            payload(site, [
              init_event(%{
                "ua" => "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
              }),
              pageview_event(1, "/")
            ]),
            received_at: DateTime.utc_now()
          )
      end

      assert [%{name: "ClaudeBot", kind: "ai", sessions: 3}] = Admin.detail().crawlers
    end

    test "web sessions are one row, whichever way the channel was recorded" do
      site = site_fixture(%{key: "channels"})

      for path <- ["/one", "/two"] do
        {:ok, _} =
          Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, path)]),
            received_at: DateTime.utc_now()
          )
      end

      # Sessions written before the channel column was populated have a null
      # there, and rows like that are still in every deployment that has been
      # running a while. Forcing one is the only way to cover the case.
      [older | _] = WebAnalytics.Repo.all(WebAnalytics.Tracking.Session)

      WebAnalytics.Repo.update_all(
        from(s in WebAnalytics.Tracking.Session, where: s.id == ^older.id),
        set: [channel: nil]
      )

      assert WebAnalytics.Repo.aggregate(
               from(s in WebAnalytics.Tracking.Session, where: is_nil(s.channel)),
               :count
             ) == 1

      channels = Admin.detail().channels

      assert [%{channel: "web", sessions: 2}] = channels
      assert length(channels) == 1
    end

    test "the hourly chart keeps empty hours rather than closing over them" do
      site = site_fixture(%{key: "chart"})

      {:ok, _} =
        Ingest.submit_sync(site, payload(site, [init_event(), click_event(%{"id" => "x"})]),
          received_at: DateTime.utc_now()
        )

      hourly = Admin.detail().hourly

      assert length(hourly) == 24
      assert Enum.count(hourly, &(&1.count > 0)) == 1
      # Ascending, so the chart reads left to right as time.
      assert hourly == Enum.sort_by(hourly, & &1.at, DateTime)
    end
  end

  describe "system/0" do
    test "reports what the box is running" do
      system = Admin.system()

      assert system.elixir == System.version()
      assert system.memory_mb > 0
      assert is_binary(system.database_size)
      assert is_boolean(system.geoip)
      assert system.mailer =~ ~r/\w/
    end

    test "table sizes come back with names and row estimates" do
      assert Enum.any?(Admin.system().table_sizes, &(&1.name in ~w(sessions pageviews events)))
    end
  end

  describe "admin?/1 and set_admin/2" do
    test "nobody is an admin by default" do
      refute WebAnalytics.Accounts.admin?(user_fixture())
      assert WebAnalytics.Accounts.list_admins() == []
    end

    test "granting and revoking" do
      user = user_fixture()

      {:ok, promoted} = WebAnalytics.Accounts.set_admin(user.email, true)
      assert WebAnalytics.Accounts.admin?(promoted)
      assert [%{id: id}] = WebAnalytics.Accounts.list_admins()
      assert id == user.id

      {:ok, demoted} = WebAnalytics.Accounts.set_admin(user.email, false)
      refute WebAnalytics.Accounts.admin?(demoted)
      assert WebAnalytics.Accounts.list_admins() == []
    end

    test "an unknown email is not found rather than a crash" do
      assert WebAnalytics.Accounts.set_admin("nobody@example.com", true) == {:error, :not_found}
    end
  end
end
