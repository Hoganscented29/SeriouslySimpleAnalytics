defmodule WebAnalyticsWeb.GettingStartedLiveTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WebAnalytics.Fixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    %{site: user_site_fixture(user, %{key: "dash", name: "Dashboard Site"})}
  end

  test "offers the website snippet above the agent instructions", %{conn: conn, site: site} do
    {:ok, _live, html} = live(conn, ~p"/getting-started")

    assert html =~ "Website Integration Instructions"
    assert html =~ "data-site=&quot;#{site.key}&quot;"
    assert html =~ "AI Integration Instructions"

    # One line, and most accounts want it, so it comes first.
    {website, _} = :binary.match(html, "Website Integration Instructions")
    {ai, _} = :binary.match(html, "AI Integration Instructions")
    assert website < ai
  end

  test "names the account in the prompt it hands an agent", %{conn: conn, site: site} do
    {:ok, _live, html} = live(conn, ~p"/getting-started")

    assert html =~ "Your coding agent"
    assert html =~ "Use account id #{site.key}"
    # The heredoc wraps and the bubble renders llms.txt as code, so assert the
    # pieces rather than a span of the sentence.
    assert html =~ "Update our "
    assert html =~ ~r{<code[^>]*>llms\.txt</code>}
  end

  test "the snippet can be copied", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/getting-started")

    assert html =~ ~s|data-copy="script-tag"|
    assert html =~ ~s|src="/wa-live.js"|
  end

  test "shows the account id, and says what it is safe to do with", %{conn: conn, site: site} do
    {:ok, _live, html} = live(conn, ~p"/getting-started")

    assert html =~ site.key
    assert html =~ "Public"
  end

  test "does not tell someone who has an account how to create one", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/getting-started")

    refute html =~ "/api/v1/accounts"
  end

  test "creates a site for an account arriving here first", %{conn: conn} do
    user = WebAnalytics.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)

    # Someone can land here before ever opening the dashboard, and must not be
    # told to go and make an account somewhere else first.
    {:ok, _live, html} = live(conn, ~p"/getting-started")

    assert html =~ "Account ID"
    assert html =~ "Website Integration Instructions"
  end

  test "requires signing in", %{conn: conn} do
    conn = conn |> Phoenix.ConnTest.recycle() |> Plug.Test.init_test_session(%{})

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/getting-started")
  end
end
