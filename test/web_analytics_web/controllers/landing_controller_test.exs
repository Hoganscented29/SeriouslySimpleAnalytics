defmodule WebAnalyticsWeb.LandingControllerTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import WebAnalytics.Fixtures

  describe "website landing page" do
    test "leads with website analytics, not AI tools", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "SeriouslySimpleAnalytics"
      assert html =~ "Website analytics"
      assert html =~ "/wa.js"
      assert html =~ "data-site="
    end

    test "names what the script tag captures", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for claim <- ["scroll depth", "Page-to-page flow", "Outbound clicks", "Forms"] do
        assert html =~ claim
      end
    end

    test "names the AI crawlers it identifies", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for bot <- ~w(GPTBot ClaudeBot PerplexityBot) do
        assert html =~ bot
      end
    end

    test "offers registration and sign-in", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/users/register"|
      assert html =~ ~s|href="/users/log-in"|
    end

    test "cross-links to the AI analytics page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/AI-Analytics-llms-txt"|
    end

    test "links to the dashboard, the demo and llms.txt", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/dashboard"|
      assert html =~ ~s|href="/demo"|
      assert html =~ ~s|href="/llms.txt"|
    end
  end

  describe "AI analytics landing page" do
    test "leads with analytics for AI tools", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "SeriouslySimpleAnalytics"
      assert html =~ "AI tool"
      assert html =~ "/api/ping"
    end

    test "shows a ping URL carrying a real account id", %{conn: conn} do
      site = site_fixture(%{key: "landing-key"})
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "uid=#{site.key}"
      assert html =~ "project="
      assert html =~ "event=page_view"
    end

    test "documents the parameters and what to log", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      for token <- ~w(uid event project type sid path) do
        assert html =~ token
      end

      assert html =~ "run_completed"
      assert html =~ "tool_called"
    end

    test "states the credential rule prominently", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "Never send credentials"
      assert html =~ "proxy"
    end

    test "shows the required location parameters", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "c=Austin"
      assert html =~ "cc=Travis"
      assert html =~ "s_p=Texas"
      assert html =~ "city, county, state/province and nation"
    end

    test "documents the self-service accounts endpoint", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "/api/v1/accounts"
      assert html =~ "claim_url"
    end

    test "cross-links back to the website analytics page", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ ~s|href="/"|
      assert html =~ "/wa.js"
    end
  end

  describe "llms.txt" do
    test "carries a block the reader can paste into their own llms.txt", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Put this in your own llms.txt"
      assert body =~ "--- copy from here ---"
      assert body =~ "--- copy to here ---"

      [_, block] = String.split(body, "--- copy from here ---", parts: 2)
      [block, _] = String.split(block, "--- copy to here ---", parts: 2)

      # The block is read by an agent that will never see the rest of this file,
      # so it has to carry the whole integration on its own.
      assert block =~ "/api/v1/accounts"
      assert block =~ "/api/ping"
      assert block =~ "claim_url"
      assert block =~ "sid"
      assert block =~ "NEVER send credentials"
      assert block =~ "ONE account per project"
    end

    test "documents the account creation endpoint for agents", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Getting an account ID"
      assert body =~ ~r{POST https?://[^/\s]+/api/v1/accounts}
      assert body =~ "409 email_taken"
      assert body =~ "429 rate_limited"
    end

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

      # County is the one location field marked recommended rather than required:
      # plenty of callers simply do not have it, and demanding it would invite
      # invented values.
      for param <- ~w(c s_p n email) do
        assert body =~ "| `#{param}` | yes |", "#{param} should be documented as required"
      end

      assert body =~ "| `cc` | recommended |"

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
