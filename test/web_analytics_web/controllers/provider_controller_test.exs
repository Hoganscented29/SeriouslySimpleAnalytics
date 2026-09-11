defmodule WebAnalyticsWeb.ProviderControllerTest do
  use WebAnalyticsWeb.ConnCase, async: true

  alias WebAnalytics.Crawlers.Provider
  alias WebAnalytics.Ingest.Crawler

  describe "each provider page" do
    test "renders, and leads with its keyword", %{conn: conn} do
      for provider <- Provider.all() do
        html = conn |> get(Provider.path(provider)) |> html_response(200)

        assert html =~ Provider.keyword(provider)
        assert html =~ "Analytics for #{provider.name}"
        assert html =~ provider.vendor
      end
    end

    test "carries the long-form content it promises", %{conn: conn} do
      for provider <- Provider.all() do
        html = conn |> get(Provider.path(provider)) |> html_response(200)

        # The pages exist to rank, so a page that quietly lost its body is a
        # regression worth failing on rather than noticing months later.
        assert word_count(provider) >= 5000,
               "#{provider.name} is #{word_count(provider)} words, under the 5000 it should carry"

        for section <- provider.sections, do: assert(html =~ section.heading)
        for {question, _} <- provider.faq, do: assert(html =~ escape(question))
      end
    end

    test "names every user agent it documents, and the classifier agrees", %{conn: conn} do
      for provider <- Provider.all() do
        html = conn |> get(Provider.path(provider)) |> html_response(200)

        for agent <- provider.agents do
          assert html =~ agent.token

          # A page documenting an agent the classifier does not recognise would
          # promise a report that never appears.
          assert %{kind: "ai"} = Crawler.classify(agent.example),
                 "#{agent.token} is documented but not classified as an AI crawler"
        end
      end
    end

    test "carries the SEO head tags", %{conn: conn} do
      for provider <- Provider.all() do
        html = conn |> get(Provider.path(provider)) |> html_response(200)

        assert html =~ ~s|name="description"|
        assert html =~ ~s|rel="canonical"|
        assert html =~ Provider.path(provider)
        assert html =~ "application/ld+json"
        assert html =~ "FAQPage"
      end
    end

    test "cross-links to the others and back to the index", %{conn: conn} do
      for provider <- Provider.all() do
        html = conn |> get(Provider.path(provider)) |> html_response(200)

        assert html =~ ~s|href="/ai-crawler-analytics"|

        for other <- Provider.others(provider) do
          assert html =~ ~s|href="#{Provider.path(other)}"|
        end
      end
    end

    test "offers the install snippet and a way to sign up", %{conn: conn} do
      provider = hd(Provider.all())
      html = conn |> get(Provider.path(provider)) |> html_response(200)

      assert html =~ "/wa.js"
      assert html =~ "data-site="
      assert html =~ ~s|href="/users/register"|
    end
  end

  describe "index" do
    test "lists every provider page", %{conn: conn} do
      html = conn |> get(~p"/ai-crawler-analytics") |> html_response(200)

      for provider <- Provider.all() do
        assert html =~ ~s|href="#{Provider.path(provider)}"|
        assert html =~ Provider.keyword(provider)
      end
    end
  end

  describe "the Claude Bot page" do
    test "is the flagship, on the path and keyword asked for", %{conn: conn} do
      html = conn |> get(~p"/claude-bot-analytics") |> html_response(200)

      assert html =~ "Claude Bot Analytics"
      assert html =~ "Analytics for Claude Bot"

      for token <- ~w(ClaudeBot Claude-User Claude-SearchBot) do
        assert html =~ token
      end
    end
  end

  defp word_count(provider) do
    ([provider.lede, provider.description] ++
       Enum.flat_map(provider.sections, fn section ->
         [section.heading | Enum.flat_map(section.body, &text/1)]
       end) ++
       Enum.flat_map(provider.faq, fn {question, answer} -> [question, answer] end) ++
       Enum.map(provider.agents, & &1.purpose))
    |> Enum.flat_map(&String.split(&1, ~r/\s+/, trim: true))
    |> length()
  end

  defp text({tag, value}) when tag in [:p, :h3, :note, :code], do: [value]
  defp text({tag, items}) when tag in [:ul, :ol], do: items
  defp text(_), do: []

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
