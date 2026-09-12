defmodule WebAnalyticsWeb.AdminLiveTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WebAnalytics.Fixtures
  import WebAnalytics.AccountsFixtures

  alias WebAnalytics.Ingest

  describe "access" do
    test "a signed-out visitor is sent to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin")
    end

    test "an ordinary user is not told the page exists", %{conn: conn} do
      user = user_fixture()

      assert {:error, {:redirect, %{to: "/dashboard", flash: flash}}} =
               conn |> log_in_user(user) |> live(~p"/admin")

      # The same wording any missing page gets. "Forbidden" would confirm that
      # /admin is real and that this account is simply not on the list.
      assert flash["error"] == "Not found."
    end

    test "an admin gets in", %{conn: conn} do
      admin = admin_fixture()
      {:ok, _live, html} = conn |> log_in_user(admin) |> live(~p"/admin")

      assert html =~ "Everything"
      assert html =~ "Right now"
    end

    test "admin cannot be granted through a changeset", %{conn: conn} do
      user = user_fixture()

      # Every path that casts user input goes through email_changeset, so this
      # is the guarantee that matters: no request body can promote anyone.
      changeset = WebAnalytics.Accounts.User.email_changeset(user, %{"admin" => true})
      refute Ecto.Changeset.get_change(changeset, :admin)

      {:ok, _live, _html} = conn |> log_in_user(admin_fixture()) |> live(~p"/admin")
    end
  end

  describe "the dashboard" do
    setup %{conn: conn} do
      admin = admin_fixture()
      site = user_site_fixture(admin, %{key: "admin-dash", name: "Admin Site"})

      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [
            init_event(),
            pageview_event(1, "/", %{"title" => "Home"}),
            tick_event(1, %{"d" => 30_000, "am" => 25_000, "sp" => 75}),
            click_event(%{"id" => "cta"})
          ]),
          received_at: DateTime.utc_now()
        )

      {:ok, _} =
        Ingest.submit_sync(
          site,
          payload(site, [
            init_event(%{
              "ua" => "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
            }),
            pageview_event(1, "/docs", %{"title" => "Docs"})
          ]),
          received_at: DateTime.utc_now()
        )

      %{conn: log_in_user(conn, admin), admin: admin, site: site}
    end

    test "counts every account's traffic, not just the admin's", %{conn: conn} do
      other = user_fixture()
      theirs = user_site_fixture(other, %{key: "someone-else", name: "Someone Else"})

      {:ok, _} =
        Ingest.submit_sync(theirs, payload(theirs, [init_event(), pageview_event(1, "/theirs")]),
          received_at: DateTime.utc_now()
        )

      {:ok, _live, html} = live(conn, ~p"/admin")

      # The point of the page: it crosses ownership boundaries.
      assert html =~ "Someone Else"
      assert html =~ "someone-else"
      assert html =~ "Admin Site"
    end

    test "shows sites, users, crawlers and recent sessions", %{conn: conn, site: site} do
      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ site.key
      assert html =~ "ClaudeBot"
      assert html =~ "Most recent sessions"
      assert html =~ "This deployment"
    end

    test "separates crawler traffic from the rest", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")
      counters = :sys.get_state(live.pid).socket.assigns.counters

      assert counters.sessions == 2
      assert counters.crawler_sessions == 1
    end

    test "refreshes counters on a tick without reloading the tables", %{conn: conn, site: site} do
      {:ok, live, _html} = live(conn, ~p"/admin")

      before = :sys.get_state(live.pid).socket.assigns

      {:ok, _} =
        Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, "/later")]),
          received_at: DateTime.utc_now()
        )

      send(live.pid, :tick)
      _ = render(live)
      after_tick = :sys.get_state(live.pid).socket.assigns

      assert after_tick.counters.sessions == before.counters.sessions + 1
      assert after_tick.tick == before.tick + 1
      # The expensive half is left alone until its own slower cadence comes round.
      assert after_tick.detail_at == before.detail_at
    end

    test "reloads the tables on the sixth tick", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")
      before = :sys.get_state(live.pid).socket.assigns.detail_at

      for _ <- 1..6, do: send(live.pid, :tick)
      _ = render(live)

      assert :sys.get_state(live.pid).socket.assigns.detail_at != before
    end

    test "refresh now reloads everything", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")
      before = :sys.get_state(live.pid).socket.assigns.detail_at

      render_click(element(live, "button", "Refresh now"))

      assert :sys.get_state(live.pid).socket.assigns.detail_at != before
    end

    test "shows host CPU and memory, or says why it cannot", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/admin")

      assert html =~ "This server"
      assert html =~ "CPU"
      assert html =~ "Memory"
      assert html =~ "Load average"

      # The suite runs on Linux in CI and on a Mac locally, so assert the
      # behaviour rather than the platform: either a real reading, or a plain
      # statement that /proc is not there.
      assigns = :sys.get_state(live.pid).socket.assigns

      if assigns.memory == :unavailable do
        assert html =~ "needs /proc"
      else
        assert assigns.memory.total > 0
        assert assigns.memory.used_pct >= 0 and assigns.memory.used_pct <= 100
        assert html =~ "available"
      end
    end

    test "CPU needs two samples, so it reads as measuring until it has them", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/admin")

      # Nothing can be said from one sample, and saying it anyway would mean
      # showing average-since-boot as though it were current.
      assert :sys.get_state(live.pid).socket.assigns.cpu_util == nil
      assert html =~ "measuring…" or html =~ "needs /proc"

      send(live.pid, :prime_cpu)
      _ = render(live)

      assigns = :sys.get_state(live.pid).socket.assigns

      if assigns.cpu_sample != :unavailable do
        assert assigns.cpu_util >= 0 and assigns.cpu_util <= 100
        assert assigns.cpu_window == 1
      end
    end

    test "a tick moves the CPU window to the tick interval", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")

      send(live.pid, :tick)
      _ = render(live)

      assigns = :sys.get_state(live.pid).socket.assigns

      if assigns.cpu_sample != :unavailable do
        assert assigns.cpu_window == 10
      end
    end

    test "the accounts table can be ranked over each window", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/admin")

      assert html =~ "busiest first"
      assert :sys.get_state(live.pid).socket.assigns.site_window == :day

      html = live |> element("button[phx-value-window='hour']") |> render_click()

      assert :sys.get_state(live.pid).socket.assigns.site_window == :hour
      assert html =~ "Views"

      live |> element("button[phx-value-window='all']") |> render_click()
      assert :sys.get_state(live.pid).socket.assigns.site_window == :all
    end

    test "switching window re-queries rather than re-sorting the same numbers", %{
      conn: conn,
      site: site
    } do
      {:ok, _} =
        Ingest.submit_sync(site, payload(site, [init_event(), pageview_event(1, "/old")]),
          received_at: DateTime.add(DateTime.utc_now(), -10, :day)
        )

      {:ok, live, _html} = live(conn, ~p"/admin")

      by_key = fn -> Map.new(:sys.get_state(live.pid).socket.assigns.sites, &{&1.key, &1}) end

      live |> element("button[phx-value-window='day']") |> render_click()
      day = by_key.()[site.key].views

      live |> element("button[phx-value-window='month']") |> render_click()
      month = by_key.()[site.key].views

      assert month > day, "a wider window has to include more, or it is only re-sorting"
    end

    test "an account ID can be opened straight from the lookup box", %{conn: conn, site: site} do
      {:ok, live, _html} = live(conn, ~p"/admin")

      assert {:error, {:live_redirect, %{to: to}}} =
               live
               |> form("form[phx-submit='open_account']", %{key: site.key})
               |> render_submit()

      assert to == "/admin/accounts/#{site.key}"
    end

    test "a typo in the lookup box says so rather than navigating", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")

      html =
        live |> form("form[phx-submit='open_account']", %{key: "acct-nope"}) |> render_submit()

      assert html =~ "No account with the ID"
    end

    test "the 24-hour chart always has 24 buckets, gaps included", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin")
      hourly = :sys.get_state(live.pid).socket.assigns.detail.hourly

      assert length(hourly) == 24
      assert Enum.any?(hourly, &(&1.count > 0))
      assert Enum.any?(hourly, &(&1.count == 0))
    end
  end

  describe "an empty deployment" do
    test "renders without a single row anywhere", %{conn: conn} do
      {:ok, _live, html} = conn |> log_in_user(admin_fixture()) |> live(~p"/admin")

      assert html =~ "No sites yet."
      assert html =~ "No crawler traffic yet."
      assert html =~ "Nothing has reported yet."
    end
  end

  describe "drilling into one account" do
    setup %{conn: conn} do
      admin = admin_fixture()
      owner = user_fixture()
      theirs = user_site_fixture(owner, %{key: "acct-theirs", name: "Their Site"})

      {:ok, _} =
        Ingest.submit_sync(
          theirs,
          payload(theirs, [
            init_event(),
            pageview_event(1, "/their-secret-page", %{"title" => "Their Secret Page"}),
            tick_event(1, %{"d" => 30_000, "am" => 25_000, "sp" => 80})
          ]),
          received_at: DateTime.utc_now()
        )

      %{conn: log_in_user(conn, admin), admin: admin, owner: owner, theirs: theirs}
    end

    test "an admin sees the full dashboard for an account they do not own", %{
      conn: conn,
      theirs: theirs,
      owner: owner
    } do
      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{theirs.key}")

      assert html =~ "Their Site"
      assert html =~ theirs.key
      # The point of the drill-down: the same reports, someone else's data.
      assert html =~ "Admin view"
      assert html =~ owner.email
    end

    test "every tab works, on someone else's account", %{conn: conn, theirs: theirs} do
      for tab <- ~w(overview pages flow locations clicks forms sessions crawlers) do
        {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{theirs.key}?tab=#{tab}")
        assert html =~ "Admin view"
      end
    end

    test "navigating stays on the admin route rather than bouncing home", %{
      conn: conn,
      theirs: theirs
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/accounts/#{theirs.key}")

      live |> element("button[phx-value-tab='pages']") |> render_click()

      # A tab click that pushed to /dashboard would silently swap the admin onto
      # their own account, with the same chrome and different numbers.
      assert_patched(
        live,
        ~p"/admin/accounts/#{theirs.key}?#{[anomalies: "exclude", clicks: "name", crawlers: "exclude", group: "path", loc: "country", range: "7d", site: theirs.key, tab: "pages"]}"
      )
    end

    test "opening your own account through admin does not claim it is someone else's", %{
      conn: conn,
      admin: admin
    } do
      mine = user_site_fixture(admin, %{key: "acct-mine-admin", name: "Mine"})

      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{mine.key}")

      assert html =~ "Your own account, opened through admin"
      refute html =~ "Someone else's account"
    end

    test "an unclaimed account says so rather than showing a blank owner", %{conn: conn} do
      orphan = site_fixture(%{key: "acct-orphan", name: "Orphan"})

      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{orphan.key}")

      assert html =~ "unclaimed"
    end

    test "an unknown account ID goes back to admin with a reason", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin", flash: flash}}} =
               live(conn, ~p"/admin/accounts/acct-does-not-exist")

      assert flash["error"] =~ "No account with the ID"
    end

    test "creating a site is refused while inspecting someone else's", %{
      conn: conn,
      theirs: theirs,
      owner: owner
    } do
      {:ok, live, html} = live(conn, ~p"/admin/accounts/#{theirs.key}")

      refute html =~ "Add another site"

      # The hidden button is not the control. The server refuses it too.
      render_click(live, "add_site", %{})

      assert [%{id: id}] = WebAnalytics.Sites.list_sites_for_user(owner)
      assert id == theirs.id
    end
  end

  describe "the boundary the drill-down must not move" do
    test "a signed-out visitor cannot reach an account", %{conn: conn} do
      site = site_fixture(%{key: "acct-locked"})

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/admin/accounts/#{site.key}")
    end

    test "an ordinary user cannot reach anyone's account, including their own", %{conn: conn} do
      user = user_fixture()
      theirs = user_site_fixture(user, %{key: "acct-mine"})

      assert {:error, {:redirect, %{to: "/dashboard", flash: flash}}} =
               conn |> log_in_user(user) |> live(~p"/admin/accounts/#{theirs.key}")

      assert flash["error"] == "Not found."
    end

    test "the ordinary dashboard still refuses another user's account", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      theirs = user_site_fixture(other, %{key: "acct-not-yours", name: "Not Yours"})

      # The drill-down exists so this rule never had to be relaxed.
      {:ok, _live, html} =
        conn |> log_in_user(user) |> live(~p"/dashboard?site=#{theirs.key}")

      refute html =~ "Not Yours"
      refute html =~ theirs.key
    end
  end
end
