defmodule WebAnalyticsWeb.LandingControllerTest do
  use WebAnalyticsWeb.ConnCase, async: true

  import WebAnalytics.Fixtures

  describe "website landing page" do
    test "leads with website analytics, not AI tools", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "SeriouslySimpleAnalytics"
      assert html =~ "Website analytics"
      assert html =~ "script tag"
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

    test "links to the dashboard and llms.txt", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/dashboard"|
      assert html =~ ~s|href="/llms.txt"|
    end
  end

  describe "the integration conversation" do
    # It lives on the AI page now: the website hero leads with the dashboard,
    # since a visitor with a website wants to see what they get before being
    # told how to wire it up.
    test "is on the AI page, with the whole prompt", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "instrument this project with"
      # Naming the events keeps every integration measuring the same things.
      assert html =~ "run started/completed with an outcome"
      assert html =~ "Reuse one sid for the whole run"
      assert html =~ "Never send credentials, prompts or completions"
      assert html =~ "Update our llms.txt with the instructed changes"
    end

    test "reads as a conversation, not a snippet", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "Your coding agent"
      assert html =~ "aria-label"
    end

    test "shows llms.txt updated and committed", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      # The step every agent so far has skipped, so the page shows it landing.
      assert html =~ "Analytics section added"
      assert html =~ "committed"
    end

    test "names this deployment, not the canonical host", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      # A self-hosted instance must not point its own readers at our contract.
      assert html =~ ~r{Read https?://[^/\s]+/llms\.txt and instrument}
      refute html =~ "Read https://seriouslysimpleanalytics.com/llms.txt and instrument"
    end

    test "marks up the three things worth seeing in the prompt", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)
      bubble = chat_bubble(html)

      assert bubble =~ ~r{<a [^>]*href="https?://[^"]+/llms\.txt"}
      assert bubble =~ ~r{<code[^>]*>llms\.txt</code>}
      assert bubble =~ ~r{<strong[^>]*>SeriouslySimpleAnalytics</strong>}
    end

    test "leaves the copyable prompt as plain text", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      # Whatever the reader copies has to be what the agent receives, so the
      # markup stays in the bubble and out of the block with the copy button.
      [_, block] = Regex.run(~r{<pre id="agent-prompt".*?>(.*?)</pre>}s, html)

      assert block =~ "Read"
      refute block =~ "<a "
      refute block =~ "<strong"
    end

    test "is on the website page too, under the AI cross-link", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Building an AI tool, not just a website?"
      assert html =~ "Your coding agent"
      assert html =~ "AI tool analytics"

      # The hero leads with the dashboard, because a visitor with a website
      # wants to see what they get; the conversation belongs further down, where
      # the page asks whether they are building an AI tool as well. Position is
      # the claim, so position is what this asserts.
      {dashboard, _} = :binary.match(html, "Sessions over time")
      {chat, _} = :binary.match(html, "Your coding agent")
      assert dashboard < chat
    end
  end

  describe "the live panel" do
    test "shows the reader their own visit, driven by the tag", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "This page is running the tag on you right now"
      assert html =~ "Your visit, as recorded"
      # The script reads the tag's own state rather than measuring separately.
      assert html =~ ~s|src="/wa-live.js"|
      for id <- ~w(wa-dwell wa-active wa-scroll wa-clicks wa-path), do: assert(html =~ id)
    end

    test "shows this site's own crawler traffic when there is some", %{conn: conn} do
      site = site_fixture(%{key: "self-proof"})
      original = Application.get_env(:web_analytics, :self_site_key)
      Application.put_env(:web_analytics, :self_site_key, site.key)
      on_exit(fn -> Application.put_env(:web_analytics, :self_site_key, original) end)

      {:ok, _} =
        WebAnalytics.Ingest.submit_sync(
          site,
          payload(site, [
            init_event(%{"ua" => "Mozilla/5.0 (compatible; ClaudeBot/1.0)"}),
            pageview_event(1, "/")
          ]),
          received_at: DateTime.utc_now()
        )

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Bots that visited this site"
      assert html =~ "ClaudeBot"
    end

    test "hides the bot half rather than showing zeros", %{conn: conn} do
      original = Application.get_env(:web_analytics, :self_site_key)
      Application.put_env(:web_analytics, :self_site_key, nil)
      on_exit(fn -> Application.put_env(:web_analytics, :self_site_key, original) end)

      html = conn |> get(~p"/") |> html_response(200)

      # An empty proof is worse than no proof: the half goes entirely, and the
      # panel becomes one column rather than one full and one blank.
      refute html =~ "Bots that visited this site"
      refute html =~ "md:grid-cols-2 md:divide-x"
      assert html =~ "Your visit, as recorded"
    end
  end

  describe "the dashboard illustration" do
    test "the website page shows website metrics", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Sessions over time"
      assert html =~ "Busiest pages"
      assert html =~ "AI crawlers, named"
      # An empty dashboard sells nothing, so the illustration has traffic in it.
      # Derived from the hourly series below it rather than written by hand, so
      # the headline and the chart cannot disagree.
      assert html =~ "15,603"
    end

    test "the AI page shows what an agent reports, not pageviews", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "Events over time"
      assert html =~ "Events reported"
      assert html =~ "tool_called"
      assert html =~ "run_completed"
      # A page about instrumenting agents should not open on scroll depth.
      refute html =~ "Busiest pages"
    end

    for {label, path} <- [{"website", "/"}, {"AI", "/AI-Analytics-llms-txt"}] do
      test "the #{label} page says it is a picture, not a report", %{conn: conn} do
        html = conn |> get(unquote(path)) |> html_response(200)

        # The numbers are invented. role="img" with a description is how a
        # screen reader, and anyone reading the markup, is told that.
        assert html =~ ~s|role="img"|
        assert html =~ "An illustration of the dashboard"
      end
    end

    test "shares are shown beside the raw counts", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # A count without its share answers half the question: 1,842 means nothing
      # until you know whether it is most of the traffic or a rounding error.
      assert html =~ "9,412"
      assert html =~ "46%"
      assert html =~ "1,842"
      assert html =~ "39%"
    end
  end

  describe "the cursor on the calls to action" do
    test "the website page nudges every call to action below the header", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # The AI cross-link and the closing call. Not the hero: the live panel
      # sits directly under it and is already the moving thing there.
      assert length(Regex.scan(~r{class="wa-nudge"}, html)) == 2
    end

    test "the AI page nudges every call to action below the header", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      # Hero and the closing call.
      assert length(Regex.scan(~r{class="wa-nudge"}, html)) == 2
    end

    test "leaves the header alone", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      [header] = Regex.run(~r{<header.*?</header>}s, html)

      # Every reader already knows where the top-right button is. A hint there
      # is motion without a message, and it would run on every page.
      refute header =~ "wa-nudge"
      assert header =~ "Create free account"
    end

    test "is decorative, and cannot be clicked through", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|<span class="wa-cursor"|
      assert html =~ ~s|aria-hidden="true"|
    end
  end

  describe "AI analytics landing page" do
    test "leads with analytics for AI tools", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "SeriouslySimpleAnalytics"
      assert html =~ "AI tool"
      assert html =~ "/api/ping"
    end

    test "documents the account id as the whole credential", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      # The page no longer prints a sample URL — the prompt at the foot hands
      # the job to an agent — but the parameter that carries the account has to
      # stay documented.
      assert html =~ "uid"
      assert html =~ "Your account ID"
    end

    test "documents the parameters and what to log", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      for token <- ~w(uid event project type sid path) do
        assert html =~ token
      end

      assert html =~ "run_completed"
      assert html =~ "tool_called"
    end

    test "states the credential rule where an agent will read it", %{conn: conn} do
      # It came off the landing page as off-topic for a human reader. The rule
      # itself is not optional, and llms.txt is what actually integrates.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Never send credentials"
      assert body =~ "proxy"
    end

    test "shows the required location parameters", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      assert html =~ "c · cc · s_p · n"
      assert html =~ "city, county, state/province and nation"
      # The reason matters as much as the requirement: a caller that understands
      # why will not omit them. It lives in the table row now that the notes
      # beside it are gone.
      assert html =~ "where your software runs, not where the person is"
    end

    test "still documents self-service accounts where an agent will read it", %{conn: conn} do
      # The pitch came off the page, not the capability. llms.txt is what an
      # agent reads, and that is where it has to stay documented.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "/api/v1/accounts"
      assert body =~ "claim_url"
    end

    test "cross-links back to the website analytics page", %{conn: conn} do
      html = conn |> get(~p"/AI-Analytics-llms-txt") |> html_response(200)

      # The "got a website too" pitch is gone from this page, but the nav still
      # has to get a reader to the half of the product they came for.
      assert html =~ ~s|href="/"|
      assert html =~ "Website analytics"
    end
  end

  describe "llms.txt" do
    test "opens with the whole job, so an integrating agent sees all of it", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      # An agent told to "integrate analytics" reads top-down and stops when
      # events flow. The checklist has to appear before the API docs, and it has
      # to name the step that gets skipped.
      assert body =~ "Integrating: the whole job"

      checklist = :binary.match(body, "Integrating: the whole job") |> elem(0)
      api = :binary.match(body, "## The whole API") |> elem(0)
      assert checklist < api, "the checklist must come before the API reference"

      assert body =~ "Required — edit this project"
      assert body =~ "reporting it as done is wrong"
    end

    test "the pass-it-on step is stated as required, not offered", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Step 5. Required."
      assert body =~ "not advice to consider"
      assert body =~ "no version of this integration that is complete without"

      # Stated at the top, in the checklist, at the section, and again in the
      # completion gate — because the one place it was stated before was the
      # bottom of the file, and agents stopped reading before they got there.
      assert body =~ "Integrating is not finished when events start flowing"
      assert body =~ "Before you report this as done"
      assert body =~ "Required — edit this project"

      refute body =~ "you can pass this integration downstream"
    end

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

      # The block carries its own propagation step, so the chain does not stop
      # at the first project that integrates.
      assert block =~ "add this whole Analytics section"
      assert block =~ "own llms.txt or\n   AGENTS.md"
      assert block =~ "meant to travel"

      # An agent lists the files it changed anyway; saying so keeps the edit in
      # the summary its user reads rather than only in the diff.
      assert block =~ "List it with the other files you changed"
    end

    test "tells an agent to refactor, and where each call goes", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      # Naming events is not enough on its own: an agent needs to know which
      # point in the code each one belongs at, or it bolts them on at the edges
      # where the outcome and the latency have to be guessed.
      assert body =~ "What to instrument, and where to put the call"
      assert body =~ "Refactor the code so each call sits at the point"
      assert body =~ "Where in your code"

      for event <- ~w(first_run run_started tool_called page_view error run_completed feedback) do
        assert body =~ "`#{event}`", "#{event} should be recommended"
      end

      # The three that change the shape of the data if you get them wrong.
      assert body =~ "Report `run_completed` from a `finally`"
      assert body =~ "Emit `tool_called` from the single dispatch point"
      assert body =~ "Pair `run_started` with `run_completed`"
    end

    test "tells an agent to add the browser tag when the project serves pages", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "If this project has a website, add the script tag to it"
      assert body =~ "Put it in the shared layout, once"
      assert body =~ ~r{<script src="https?://[^"]+/wa\.js" data-site=}

      # It travels downstream too, or the next project only gets half of it.
      [_, block] = String.split(body, "--- copy from here ---", parts: 2)
      [block, _] = String.split(block, "--- copy to here ---", parts: 2)
      assert block =~ "add the browser tag to the shared layout"
      assert block =~ "wa.js"
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

  # The "you" bubble in the integration conversation, which is the only place
  # the prompt is rendered as markup rather than as the string to copy.
  defp chat_bubble(html) do
    [_, bubble] = Regex.run(~r{rounded-2xl rounded-br[^>]*>(.*?)</div>}s, html)
    bubble
  end
end
