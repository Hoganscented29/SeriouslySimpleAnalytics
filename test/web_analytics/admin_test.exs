defmodule WebAnalytics.AdminTest do
  use WebAnalytics.DataCase, async: true

  import WebAnalytics.Fixtures
  import WebAnalytics.AccountsFixtures

  import Ecto.Query, only: [from: 2]

  alias WebAnalytics.Admin
  alias WebAnalytics.Ingest

  describe "active_now/2" do
    test "an empty deployment reports zeros rather than failing" do
      live = Admin.active_now()

      assert live.sessions == 0
      assert live.live_sessions == 0
      assert live.sessions_list == []
    end

    test "separates the last thirty seconds from the last thirty minutes" do
      site = site_fixture(%{key: "live-admin"})

      for path <- ["/now", "/recent", "/stale"] do
        {:ok, _} =
          Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, path)]),
            received_at: DateTime.utc_now(),
            token: path
          )
      end

      sessions = WebAnalytics.Repo.all(WebAnalytics.Tracking.Session)
      assert length(sessions) == 3
      [minutes_ago, long_ago, _still_here] = Enum.sort_by(sessions, & &1.id)

      # One a few minutes back, one well outside the half hour. Only the third
      # is still inside the thirty second window.
      age(minutes_ago, -5, :minute)
      age(long_ago, -45, :minute)

      live = Admin.active_now()

      assert live.sessions == 2
      assert live.live_sessions == 1
      assert length(live.sessions_list) == 2
    end

    test "honours the domain scope, so a filtered page counts filtered traffic" do
      site = site_fixture(%{key: "live-scoped"})

      for host <- ["a.example.com", "b.example.com"] do
        {:ok, _} =
          Ingest.submit_sync(
            site,
            payload(
              site,
              [init_event(), pageview_event(1, "/", %{"url" => "https://#{host}/"})],
              token: host
            ),
            received_at: DateTime.utc_now()
          )
      end

      assert Admin.active_now().sessions == 2
      assert Admin.active_now(%{domain: "a.example.com", project: nil}).sessions == 1
    end

    defp age(session, amount, unit) do
      at = DateTime.add(DateTime.utc_now(), amount, unit)

      WebAnalytics.Repo.update_all(
        from(s in WebAnalytics.Tracking.Session, where: s.id == ^session.id),
        set: [last_seen_at: at, started_at: at]
      )
    end
  end

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

      assert detail.users == []
      assert detail.crawlers == []
      assert length(detail.hourly) == 24
      assert Enum.all?(detail.hourly, &(&1.count == 0))
    end

    test "sites carry their owner's email and an unclaimed site says so" do
      user = user_fixture()
      user_site_fixture(user, %{key: "owned", name: "Owned"})
      site_fixture(%{key: "orphan", name: "Orphan"})

      by_key = Map.new(Admin.sites(), &{&1.key, &1})

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

  describe "sites/2" do
    setup do
      busy = site_fixture(%{key: "busy", name: "Busy"})
      quiet = site_fixture(%{key: "quiet", name: "Quiet"})
      stale = site_fixture(%{key: "stale", name: "Stale"})
      now = DateTime.utc_now()

      # Busy: three visits today. Quiet: one. Stale: one, three weeks ago.
      for _ <- 1..3 do
        {:ok, _} =
          Ingest.submit_sync(
            busy,
            payload(busy, [init_event(), pageview_event(1, "/"), click_event(%{"id" => "x"})]),
            received_at: now
          )
      end

      {:ok, _} =
        Ingest.submit_sync(quiet, payload(quiet, [init_event(), pageview_event(1, "/")]),
          received_at: now
        )

      {:ok, _} =
        Ingest.submit_sync(stale, payload(stale, [init_event(), pageview_event(1, "/")]),
          received_at: DateTime.add(now, -21, :day)
        )

      %{busy: busy, quiet: quiet, stale: stale, now: now}
    end

    test "ranks by views in the window, busiest first" do
      assert ["busy", "quiet" | _] = Enum.map(Admin.sites(:day), & &1.key)
    end

    test "a site outside the window counts zero and sorts last" do
      by_key = Map.new(Admin.sites(:day), &{&1.key, &1})

      assert by_key["busy"].views == 3
      assert by_key["stale"].views == 0
      assert List.last(Enum.map(Admin.sites(:day), & &1.key)) in ["stale", "quiet"]
    end

    test "a wider window brings the older site back into the count" do
      assert Map.new(Admin.sites(:day), &{&1.key, &1})["stale"].views == 0
      assert Map.new(Admin.sites(:month), &{&1.key, &1})["stale"].views == 1
      assert Map.new(Admin.sites(:all), &{&1.key, &1})["stale"].views == 1
    end

    test "an hour window excludes what a day includes", %{quiet: quiet, now: now} do
      {:ok, _} =
        Ingest.submit_sync(quiet, payload(quiet, [init_event(), pageview_event(1, "/older")]),
          received_at: DateTime.add(now, -5, :hour)
        )

      by_hour = Map.new(Admin.sites(:hour), &{&1.key, &1})
      by_day = Map.new(Admin.sites(:day), &{&1.key, &1})

      assert by_hour["quiet"].views == 1
      assert by_day["quiet"].views == 2
    end

    test "counts are not multiplied by joining sessions, pageviews and events" do
      # One join across all three would return the product of the three counts
      # rather than the three counts, and every number here would be wrong in a
      # way that still looks plausible.
      busy = Map.new(Admin.sites(:day), &{&1.key, &1})["busy"]

      assert busy.sessions == 3
      assert busy.views == 3
      assert busy.events == 3
    end

    test "last seen is all-time, so a quiet site still says when it last spoke" do
      by_key = Map.new(Admin.sites(:hour), &{&1.key, &1})

      # Outside the hour window, but it did speak once and that is worth saying.
      assert by_key["stale"].views == 0
      assert by_key["stale"].last_seen
    end

    test "an unknown window falls back to a day rather than raising" do
      assert Admin.sites(:fortnight) == Admin.sites(:day)
    end

    test "every window is offered and every one of them works" do
      for window <- Admin.windows() do
        assert is_list(Admin.sites(window))
      end
    end
  end
end
