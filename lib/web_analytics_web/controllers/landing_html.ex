defmodule WebAnalyticsWeb.LandingHTML do
  @moduledoc "The public landing page."
  use WebAnalyticsWeb, :html

  # Before embed_templates, which compiles the templates at that point: an
  # import underneath it is not in scope for them.
  import WebAnalyticsWeb.IntegrationComponents,
    only: [
      integration_chat: 1,
      dashboard_preview: 1,
      agent_preview: 1,
      live_proof: 1,
      agent_prompt: 1
    ]

  embed_templates "landing_html/*"

  @ai_path "/AI-Analytics-llms-txt"

  @doc "Canonical path of the AI analytics landing page."
  def ai_path, do: @ai_path

  attr :current_scope, :map, default: nil
  attr :active, :atom, default: :web, values: [:web, :ai]

  @doc """
  The header shared by both landing pages.

  The two pages sell different products to different people, but they are one
  account and one dashboard, so the header is the thing that has to say so.
  """
  def site_header(assigns) do
    ~H"""
    <header class="border-b border-base-300 bg-base-100">
      <div class="mx-auto max-w-6xl px-4 sm:px-6 h-16 flex items-center gap-6">
        <a href={~p"/"} class="flex items-center gap-2 font-semibold">
          <span class="w-2.5 h-2.5 rounded-full bg-primary inline-block" /> SeriouslySimpleAnalytics
        </a>
        <nav class="hidden md:flex items-center gap-5 text-sm text-base-content/70">
          <a
            href={~p"/"}
            class={["hover:text-primary", @active == :web && "text-primary font-medium"]}
          >
            Website analytics
          </a>
          <a
            href={ai_path()}
            class={["hover:text-primary", @active == :ai && "text-primary font-medium"]}
          >
            AI tool analytics
          </a>
          <a href={~p"/llms.txt"} class="hover:text-primary font-mono text-xs">llms.txt</a>
        </nav>
        <span class="flex-1" />
        <.auth_links current_scope={@current_scope} />
      </div>
    </header>
    """
  end

  attr :current_scope, :map, default: nil

  @doc "Sign-in or dashboard links, depending on whether anyone is signed in."
  def auth_links(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.link
        :if={@current_scope && @current_scope.user}
        navigate={~p"/dashboard"}
        class="btn btn-primary btn-sm"
      >
        Dashboard
      </.link>
      <.link
        :if={!(@current_scope && @current_scope.user)}
        navigate={~p"/users/log-in"}
        class="btn btn-ghost btn-sm"
      >
        Sign in
      </.link>
      <.link
        :if={!(@current_scope && @current_scope.user)}
        navigate={~p"/users/register"}
        class="btn btn-primary btn-sm"
      >
        Create free account
      </.link>
    </div>
    """
  end

  attr :current_scope, :map, default: nil
  attr :class, :string, default: "btn btn-primary"

  @doc """
  The primary call to action.

  Someone already signed in has no use for a signup button, and showing one
  reads as though the page has not noticed them.
  """
  def cta(assigns) do
    ~H"""
    <.link :if={@current_scope && @current_scope.user} navigate={~p"/dashboard"} class={@class}>
      Open your dashboard
    </.link>
    <.link
      :if={!(@current_scope && @current_scope.user)}
      navigate={~p"/users/register"}
      class={@class}
    >
      Create a free account
    </.link>
    """
  end

  @doc "The footer shared by both landing pages."
  def site_footer(assigns) do
    ~H"""
    <footer class="border-t border-base-300">
      <div class="mx-auto max-w-6xl px-4 sm:px-6 py-8 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
        <span class="text-base-content/60">SeriouslySimpleAnalytics</span>
        <span class="text-base-content/30">·</span>
        <a href={~p"/"} class="link link-hover">Website analytics</a>
        <a href={ai_path()} class="link link-hover">AI tool analytics</a>
        <.link navigate={~p"/dashboard"} class="link link-hover">Dashboard</.link>
        <a href={~p"/llms.txt"} class="link link-hover font-mono text-xs">llms.txt</a>
        <span class="flex-1" />
        <a
          href="mailto:me@LoganBesecker.com?subject=Business%20development%20inquiry"
          class="link link-hover font-medium"
        >
          Business development inquiries
        </a>
      </div>
    </footer>
    """
  end

  @doc "The install snippet, for sites that also want browser tracking."
  def script_tag(base_url, site_key) do
    ~s|<script src="#{base_url}/wa.js" data-site="#{site_key}" defer></script>|
  end

  @doc """
  AI crawlers the classifier recognises by name.

  Listed on the page because "we detect AI crawlers" is a claim, and naming them
  is the evidence for it.
  """
  def ai_crawlers do
    [
      {"GPTBot", "OpenAI"},
      {"ChatGPT-User", "OpenAI"},
      {"OAI-SearchBot", "OpenAI"},
      {"ClaudeBot", "Anthropic"},
      {"Claude-User", "Anthropic"},
      {"PerplexityBot", "Perplexity"},
      {"Google-Extended", "Google"},
      {"Applebot-Extended", "Apple"},
      {"Meta-ExternalAgent", "Meta"},
      {"Bytespider", "ByteDance"},
      {"CCBot", "Common Crawl"},
      {"Amazonbot", "Amazon"},
      {"cohere-ai", "Cohere"},
      {"Diffbot", "Diffbot"}
    ]
  end
end
