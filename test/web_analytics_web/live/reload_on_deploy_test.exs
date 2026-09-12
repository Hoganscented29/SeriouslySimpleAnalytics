defmodule WebAnalyticsWeb.ReloadOnDeployTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WebAnalytics.Fixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    %{site: user_site_fixture(user, %{key: "dash", name: "Dashboard Site"})}
  end

  test "a tab whose assets still match is left alone", %{conn: conn} do
    # The common case by far, and the one that must stay quiet: reloading on
    # every reconnect would throw away the reader's scroll position and their
    # place in the page every time a network blip dropped the socket.
    {:ok, view, _html} = live(conn, ~p"/dashboard?site=dash")

    refute_push_event(view, "wa:reload", %{})
  end

  test "the hook is on every LiveView, not remembered per page", %{conn: conn} do
    # It rides on the :live_view macro, so a page added later cannot forget it.
    for path <- [~p"/dashboard", ~p"/getting-started", ~p"/users/settings"] do
      {:ok, view, _html} = live(conn, path)
      refute_push_event(view, "wa:reload", %{})
    end
  end
end
