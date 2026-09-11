defmodule WebAnalytics.Crawlers.Provider do
  @moduledoc """
  One AI provider's crawler, and everything a site owner might want to know
  about it.

  Each provider gets a page of its own because the questions people arrive with
  are provider-specific — what the user agent looks like, which robots.txt token
  controls it, whether a visit means training or retrieval, whether blocking it
  costs you referrals. A generic "AI crawlers" page answers none of those.

  Content is data rather than markup so the pages stay consistent with each
  other and with `WebAnalytics.Ingest.Crawler`, which is what actually does the
  detecting. If a bot is added to the classifier, its page should be added here.
  """

  @enforce_keys [:slug, :name, :vendor, :description, :lede, :agents, :sections]
  defstruct [
    :slug,
    :name,
    :vendor,
    :description,
    :lede,
    :agents,
    :sections,
    keyword: nil,
    robots_tokens: [],
    facts: [],
    faq: [],
    related_note: nil
  ]

  @type body_element ::
          {:p, String.t()}
          | {:h3, String.t()}
          | {:ul, [String.t()]}
          | {:ol, [String.t()]}
          | {:code, String.t()}
          | {:note, String.t()}

  @type t :: %__MODULE__{}

  # Slugs are literals here rather than read out of each module, so the router
  # can generate its routes at compile time without dragging every content
  # module into its dependency graph.
  @registry [
    {"claude-bot", WebAnalytics.Crawlers.Providers.Anthropic},
    {"gptbot", WebAnalytics.Crawlers.Providers.OpenAI},
    {"perplexitybot", WebAnalytics.Crawlers.Providers.Perplexity}
    # Google-Extended, Applebot-Extended, Meta-ExternalAgent, Bytespider, CCBot
    # and Amazonbot are recognised by the classifier and appear in the crawler
    # report; they do not have pages of their own yet. Adding one is a module
    # here and a line above.
  ]

  @doc "Every provider page, in the order they should be listed."
  def all, do: Enum.map(@registry, fn {_slug, module} -> module.provider() end)

  @doc "Every slug, for route generation at compile time."
  def slugs, do: Enum.map(@registry, &elem(&1, 0))

  @doc "One provider by slug, or nil."
  def fetch(slug), do: Enum.find(all(), &(&1.slug == slug))

  @doc "The others, for cross-linking at the foot of a page."
  def others(%__MODULE__{slug: slug}), do: Enum.reject(all(), &(&1.slug == slug))

  @doc "The public path for a provider page."
  def path(%__MODULE__{slug: slug}), do: path(slug)
  def path(slug) when is_binary(slug), do: "/#{slug}-analytics"

  @doc "The page title, which is also the primary keyword phrase."
  def title(%__MODULE__{} = provider) do
    "#{keyword(provider)} — Analytics for #{provider.name}"
  end

  @doc "The keyword this page is written around."
  def keyword(%__MODULE__{keyword: nil, name: name}), do: "#{name} Analytics"
  def keyword(%__MODULE__{keyword: keyword}), do: keyword

  @doc """
  FAQPage structured data, so the questions can surface in search directly.

  Built from the same `faq` list the page renders, because structured data that
  disagrees with the visible page is worse than none at all.
  """
  def structured_data(%__MODULE__{} = provider, base_url) do
    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "WebPage",
          "@id" => base_url <> path(provider),
          "name" => title(provider),
          "description" => provider.description,
          "isPartOf" => %{"@type" => "WebSite", "name" => "SeriouslySimpleAnalytics"}
        },
        %{
          "@type" => "FAQPage",
          "mainEntity" =>
            Enum.map(provider.faq, fn {question, answer} ->
              %{
                "@type" => "Question",
                "name" => question,
                "acceptedAnswer" => %{"@type" => "Answer", "text" => answer}
              }
            end)
        }
      ]
    }
    |> Jason.encode!()
  end
end
