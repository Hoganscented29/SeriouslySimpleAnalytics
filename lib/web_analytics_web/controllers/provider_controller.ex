defmodule WebAnalyticsWeb.ProviderController do
  @moduledoc """
  One long-form page per AI crawler provider.

  People arrive at these pages with a provider-specific question — what the user
  agent looks like, which robots.txt token controls it, whether a visit means
  training or retrieval — so each provider gets its own page rather than a row
  in a shared table.

  The slug comes from the route's assigns, which means the route list and the
  content registry cannot drift apart: a page can only exist if both agree.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalytics.Crawlers.Provider
  alias WebAnalytics.Sites

  def show(conn, _params) do
    provider = Provider.fetch(conn.assigns.provider_slug)
    base_url = conn |> url(~p"/") |> String.trim_trailing("/")

    conn
    |> assign(:page_title, Provider.title(provider))
    |> assign(:page_description, provider.description)
    |> assign(:canonical_path, Provider.path(provider))
    |> assign(:structured_data, Provider.structured_data(provider, base_url))
    |> assign(:provider, provider)
    |> assign(:base_url, base_url)
    |> assign(:site_key, demo_site_key())
    |> render(:show)
  end

  def index(conn, _params) do
    conn
    |> assign(:page_title, "AI Crawler Analytics — every major AI crawler, named")
    |> assign(
      :page_description,
      "Free analytics for AI crawlers. See which pages ClaudeBot, GPTBot, PerplexityBot, " <>
        "Bytespider, CCBot and the rest take from your site, and what to do about it."
    )
    |> assign(:canonical_path, "/ai-crawler-analytics")
    |> assign(:providers, Provider.all())
    |> render(:index)
  end

  defp demo_site_key do
    case Sites.list_sites() do
      [site | _] -> site.key
      [] -> "YOUR_ACCOUNT_ID"
    end
  end
end
