defmodule WebAnalytics.Ingest.Crawler do
  @moduledoc """
  Identifies automated traffic and says what kind it is.

  Crawlers are treated as their own dimension rather than as an anomaly. They
  are not malformed data — a visit from an AI crawler is a real, interesting
  event — they simply do not belong in the same bucket as human sessions. So
  they are filtered out of the ordinary reports by default and get a report of
  their own.

  Matching is ordered most-specific first: `Google-Extended` and
  `Applebot-Extended` are AI training crawlers and must be recognised before the
  generic `Googlebot` and `Applebot` search patterns, and named bots must be
  recognised before the catch-all `bot|crawler|spider` fallback.
  """

  @kinds ~w(ai search preview seo headless automation monitor tool other)

  @patterns [
    # -- AI and LLM crawlers, agents, and training fetchers -----------------
    {~r/GPTBot/i, "ai", "GPTBot"},
    {~r/ChatGPT-User/i, "ai", "ChatGPT-User"},
    {~r/OAI-SearchBot/i, "ai", "OAI-SearchBot"},
    {~r/ClaudeBot/i, "ai", "ClaudeBot"},
    {~r/Claude-Web/i, "ai", "Claude-Web"},
    {~r/Claude-User/i, "ai", "Claude-User"},
    {~r/Claude-SearchBot/i, "ai", "Claude-SearchBot"},
    {~r/anthropic-ai/i, "ai", "Anthropic"},
    {~r/PerplexityBot/i, "ai", "PerplexityBot"},
    {~r/Perplexity-User/i, "ai", "Perplexity-User"},
    {~r/Google-Extended/i, "ai", "Google-Extended"},
    {~r/Applebot-Extended/i, "ai", "Applebot-Extended"},
    {~r/Meta-ExternalAgent/i, "ai", "Meta-ExternalAgent"},
    {~r/Meta-ExternalFetcher/i, "ai", "Meta-ExternalFetcher"},
    {~r/Bytespider/i, "ai", "Bytespider"},
    {~r/CCBot/i, "ai", "CCBot"},
    {~r/cohere-ai/i, "ai", "Cohere"},
    {~r/Diffbot/i, "ai", "Diffbot"},
    {~r/Amazonbot/i, "ai", "Amazonbot"},
    {~r/YouBot/i, "ai", "YouBot"},
    {~r/ImagesiftBot/i, "ai", "ImagesiftBot"},
    {~r/Omgilibot|omgili/i, "ai", "Omgili"},
    {~r/Timpibot/i, "ai", "Timpibot"},
    {~r/FriendlyCrawler/i, "ai", "FriendlyCrawler"},

    # -- Search engines ------------------------------------------------------
    {~r/AdsBot-Google/i, "search", "AdsBot-Google"},
    {~r/Googlebot/i, "search", "Googlebot"},
    {~r/Storebot-Google/i, "search", "Storebot-Google"},
    {~r/BingPreview|bingbot/i, "search", "Bingbot"},
    {~r/Slurp/i, "search", "Yahoo! Slurp"},
    {~r/DuckDuckBot|DuckDuckGo/i, "search", "DuckDuckBot"},
    {~r/Baiduspider/i, "search", "Baiduspider"},
    {~r/Yandex(Bot|Images|Mobile)/i, "search", "YandexBot"},
    {~r/Sogou/i, "search", "Sogou"},
    {~r/SeznamBot/i, "search", "SeznamBot"},
    {~r/Qwantify/i, "search", "Qwantify"},
    {~r/MojeekBot/i, "search", "MojeekBot"},
    {~r/PetalBot/i, "search", "PetalBot"},
    {~r/Applebot/i, "search", "Applebot"},
    {~r/ia_archiver/i, "search", "Internet Archive"},

    # -- Link unfurlers ------------------------------------------------------
    {~r/facebookexternalhit|facebot/i, "preview", "Facebook"},
    {~r/Twitterbot/i, "preview", "Twitterbot"},
    {~r/Slackbot|Slack-ImgProxy/i, "preview", "Slackbot"},
    {~r/Discordbot/i, "preview", "Discordbot"},
    {~r/TelegramBot/i, "preview", "TelegramBot"},
    {~r/WhatsApp/i, "preview", "WhatsApp"},
    {~r/LinkedInBot/i, "preview", "LinkedInBot"},
    {~r/Pinterest(bot)?/i, "preview", "Pinterest"},
    {~r/redditbot/i, "preview", "Redditbot"},
    {~r/Embedly|iframely/i, "preview", "Embedly"},

    # -- SEO and backlink crawlers ------------------------------------------
    {~r/AhrefsBot/i, "seo", "AhrefsBot"},
    {~r/SemrushBot/i, "seo", "SemrushBot"},
    {~r/MJ12bot/i, "seo", "Majestic"},
    {~r/DotBot/i, "seo", "DotBot"},
    {~r/Screaming Frog/i, "seo", "Screaming Frog"},
    {~r/BLEXBot/i, "seo", "BLEXBot"},
    {~r/DataForSeoBot/i, "seo", "DataForSeoBot"},
    {~r/SerpstatBot/i, "seo", "SerpstatBot"},

    # -- Headless browsers and test automation ------------------------------
    {~r/HeadlessChrome/i, "headless", "Headless Chrome"},
    {~r/PhantomJS/i, "headless", "PhantomJS"},
    {~r/Playwright/i, "automation", "Playwright"},
    {~r/Puppeteer/i, "automation", "Puppeteer"},
    {~r/Selenium|WebDriver/i, "automation", "Selenium"},
    {~r/Cypress/i, "automation", "Cypress"},

    # -- Uptime and performance monitoring ----------------------------------
    {~r/Chrome-Lighthouse|Lighthouse|PageSpeed/i, "monitor", "Lighthouse"},
    {~r/Pingdom/i, "monitor", "Pingdom"},
    {~r/UptimeRobot/i, "monitor", "UptimeRobot"},
    {~r/StatusCake/i, "monitor", "StatusCake"},
    {~r/Site24x7/i, "monitor", "Site24x7"},
    {~r/Datadog/i, "monitor", "Datadog"},
    {~r/GTmetrix/i, "monitor", "GTmetrix"},

    # -- HTTP clients and libraries -----------------------------------------
    {~r/curl\//i, "tool", "curl"},
    {~r/Wget/i, "tool", "Wget"},
    {~r/python-requests|aiohttp|httpx|urllib/i, "tool", "Python HTTP"},
    {~r/Scrapy/i, "tool", "Scrapy"},
    {~r/Go-http-client/i, "tool", "Go HTTP"},
    {~r/okhttp/i, "tool", "OkHttp"},
    {~r/Apache-HttpClient/i, "tool", "Apache HttpClient"},
    {~r/PostmanRuntime/i, "tool", "Postman"},
    {~r/axios|node-fetch|undici/i, "tool", "Node HTTP"},
    {~r/Java\//i, "tool", "Java HTTP"},

    # -- Anything else that self-identifies ---------------------------------
    {~r/\bbot\b|bot\/|crawl|spider|scrape|archiver|validator|fetcher|monitoring/i, "other",
     "Unclassified bot"}
  ]

  @labels %{
    "ai" => "AI crawler",
    "search" => "Search engine",
    "preview" => "Link preview",
    "seo" => "SEO crawler",
    "headless" => "Headless browser",
    "automation" => "Browser automation",
    "monitor" => "Uptime monitor",
    "tool" => "HTTP client",
    "other" => "Other bot"
  }

  @doc "Known crawler kinds."
  def kinds, do: @kinds

  @doc "Human-readable name for a crawler kind."
  def label(kind), do: Map.get(@labels, kind, kind)

  @doc "All kinds with their labels."
  def labels, do: @labels

  @doc """
  Classifies a user agent.

  Returns `%{crawler: boolean, kind: String.t() | nil, name: String.t() | nil}`.
  """
  def classify(user_agent) when is_binary(user_agent) and user_agent != "" do
    Enum.find_value(@patterns, miss(), fn {pattern, kind, name} ->
      if Regex.match?(pattern, user_agent) do
        %{crawler: true, kind: kind, name: name}
      end
    end)
  end

  def classify(_), do: miss()

  @doc """
  Merges the server's own verdict with what the client reported about itself.

  The tracker can see things a user agent string cannot — `navigator.webdriver`,
  a missing plugin and language list — so a client that says it is automated is
  believed. It cannot be trusted in the other direction: a crawler that omits
  the flag is still caught by the user-agent match.
  """
  def classify(user_agent, client_signal) do
    case classify(user_agent) do
      %{crawler: true} = verdict ->
        verdict

      _ ->
        case client_signal do
          signal when signal in ["webdriver", "automation"] ->
            %{crawler: true, kind: "automation", name: "Reported by client"}

          "headless" ->
            %{crawler: true, kind: "headless", name: "Reported by client"}

          signal when is_binary(signal) and signal != "" ->
            %{crawler: true, kind: "other", name: "Reported by client"}

          _ ->
            miss()
        end
    end
  end

  defp miss, do: %{crawler: false, kind: nil, name: nil}
end
