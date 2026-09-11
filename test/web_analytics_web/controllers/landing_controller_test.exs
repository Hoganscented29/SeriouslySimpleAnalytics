defmodule WebAnalyticsWeb.LandingControllerTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import WebAnalytics.Fixtures

  describe "landing page" do
    test "leads with analytics for AI tools", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "SeriouslySimpleAnalytics"
      assert html =~ "AI tool"
      assert html =~ "/api/ping"
    end

    test "shows a ping URL carrying a real account id", %{conn: conn} do
      site = site_fixture(%{key: "landing-key"})
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "uid=#{site.key}"
      assert html =~ "project="
      assert html =~ "event=page_view"
    end

    test "documents the parameters and what to log", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for token <- ~w(uid event project type sid path) do
        assert html =~ token
      end

      assert html =~ "run_completed"
      assert html =~ "tool_called"
    end

    test "states the credential rule prominently", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Never send credentials"
      assert html =~ "proxy"
    end

    test "shows the required location parameters", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "c=Austin"
      assert html =~ "cc=Travis"
      assert html =~ "s_p=Texas"
      assert html =~ "city, county, state/province and nation"
    end

    test "still offers the browser tracker for websites", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "/wa.js"
      assert html =~ "data-site="
    end

    test "links to the dashboard, the demo and llms.txt", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/dashboard"|
      assert html =~ ~s|href="/demo"|
      assert html =~ ~s|href="/llms.txt"|
    end
  end

  describe "llms.txt" do
    test "is served as plain text", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")

      assert response(conn, 200)
      assert response_content_type(conn, :txt) =~ "text/plain"
    end

    test "carries absolute URLs for this deployment, not placeholders", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      refute body =~ "{{BASE_URL}}"
      # An agent that reads this must never have to work out the host itself.
      assert body =~ ~r{https?://[^/\s]+/api/ping}
      refute body =~ ~r{(?<!\w)/api/ping}
    end

    test "documents the whole ping contract", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      for token <- ~w(uid event project type sid path visitor format bot) do
        assert body =~ "`#{token}`", "llms.txt should document #{token}"
      end

      assert body =~ "204"
      assert body =~ "page_view"
    end

    test "states the rules an integrating agent must follow", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Never send credentials"
      assert body =~ "Keep prompts and completions out"
      # Self-identification for crawlers, which is the opposite case.
      assert body =~ "bot=agent"
      assert body =~ "10 seconds"
    end

    test "requires the caller to supply its user's location", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      for param <- ~w(c cc s_p n) do
        assert body =~ "| `#{param}` | yes |", "#{param} should be documented as required"
      end

      assert body =~ "Location is yours to send, not ours to guess"
      assert body =~ "c=Austin&cc=Travis&s_p=Texas"
      # The reason matters: an agent that understands it will not omit them.
      assert body =~ "where the\n*software* is"
    end

    test "is reachable cross-origin so an agent can read it first", %{conn: conn} do
      conn = conn |> put_req_header("origin", "https://agent.example") |> get(~p"/llms.txt")
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://agent.example"]
    end
  end
end
