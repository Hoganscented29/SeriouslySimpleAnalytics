defmodule WebAnalyticsWeb.SelfTrackingTest do
  use WebAnalyticsWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:web_analytics, :self_site_key)
    on_exit(fn -> Application.put_env(:web_analytics, :self_site_key, original) end)
    :ok
  end

  test "reports nowhere when no account is configured", %{conn: conn} do
    Application.put_env(:web_analytics, :self_site_key, nil)

    html = conn |> get(~p"/") |> html_response(200)

    # The tag still runs, because the landing page shows a reader their own
    # visit as the tag records it and cannot be the one page with no tag on it.
    assert html =~ ~s|src="/wa.js"|
    assert html =~ ~s|data-measure-only="true"|

    # But it names no account, so a clone or a self-hosted copy cannot report
    # into somebody else's by inheriting a default.
    refute html =~ "data-site="
  end

  test "stops measuring-only once an account is configured", %{conn: conn} do
    Application.put_env(:web_analytics, :self_site_key, "acct_selftest")

    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ "data-measure-only"
  end

  test "renders the tag on every page once an account is configured", %{conn: conn} do
    Application.put_env(:web_analytics, :self_site_key, "acct_selftest")

    for path <- ["/", "/AI-Analytics-llms-txt", "/claude-bot-analytics", "/ai-crawler-analytics"] do
      html = conn |> get(path) |> html_response(200)

      assert html =~ ~s|src="/wa.js"|, "#{path} should carry the tag"
      assert html =~ ~s|data-site="acct_selftest"|
    end
  end

  test "the tag defers, so it never blocks the page it measures", %{conn: conn} do
    Application.put_env(:web_analytics, :self_site_key, "acct_selftest")

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~r|<script[^>]*src="/wa\.js"[^>]*defer|
  end
end
