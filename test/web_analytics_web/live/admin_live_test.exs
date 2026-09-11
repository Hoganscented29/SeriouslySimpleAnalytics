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
end
