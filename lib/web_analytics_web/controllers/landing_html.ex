defmodule WebAnalyticsWeb.LandingHTML do
  @moduledoc "The public landing page."
  use WebAnalyticsWeb, :html

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

  @doc "The ping URL shown in the hero, with this deployment's host."
  def ping_url(base_url, account_id) do
    "#{base_url}/api/ping?uid=#{account_id}&type=ai&project=my-agent&event=page_view" <>
      "&c=Austin&cc=Travis&s_p=Texas&n=United%20States"
  end

  @doc """
  A worked example of instrumenting one run.

  HEEx reads `{` as interpolation, so anything containing braces is assembled
  here rather than escaped in the template.
  """
  def run_example(base_url, account_id) do
    base =
      "#{base_url}/api/ping?uid=#{account_id}&project=my-agent&sid=run_7f3a" <>
        "&c=Austin&cc=Travis&s_p=Texas&n=US"

    [
      "# a run starts",
      "curl \"#{base}&event=run_started\"",
      "",
      "# it calls a tool",
      "curl \"#{base}&event=tool_called&tool=web_search&latency_ms=420\"",
      "",
      "# and finishes",
      "curl \"#{base}&event=run_completed&outcome=success\""
    ]
    |> Enum.join("\n")
  end

  @doc """
  Creating an account and using it, in two requests.

  Shown as one block because the account id from the first is the whole input to
  the second — an agent reading this needs to see them joined up.
  """
  def account_example(base_url) do
    [
      "# 1. create an account (the email is optional)",
      "curl -X POST \"#{base_url}/api/v1/accounts\" \\",
      "  -d email=you@example.com -d project=my-agent",
      "",
      "# => {\"uid\": \"acct_9f3ab21c04\", \"ping_url\": \"...\", ...}",
      "",
      "# 2. report an event with the id it gave you",
      "curl \"#{base_url}/api/ping?uid=acct_9f3ab21c04&type=ai&project=my-agent" <>
        "&event=run_started&sid=run_7f3a\""
    ]
    |> Enum.join("\n")
  end

  attr :base_url, :string, required: true

  @doc """
  The integration, shown as the conversation it actually is.

  A code block says "copy this into something". That is the wrong instruction
  now: the reader's job is to hand one sentence to an agent and let it read the
  contract itself. Showing the exchange says that in a way a snippet cannot, and
  the file card at the end is the part that matters — it is the step every agent
  so far has skipped.

  Framed as an app window so it reads as something that happened rather than a
  diagram of it, but still markup: selectable, theme-aware, and the line in the
  first bubble is the same string the page tells you to paste. The window is
  `role="img"` because it is an illustration of what an agent does, not a
  recording of a particular run.
  """
  def integration_chat(assigns) do
    ~H"""
    <div
      class="rounded-2xl border border-base-300 bg-base-100 overflow-hidden shadow-sm"
      role="img"
      aria-label={
        "A conversation with a coding agent: you paste one line asking it to read " <>
          "llms.txt and follow it, and the agent reads the contract, creates an account, " <>
          "starts reporting events, and commits the updated llms.txt."
      }
    >
      <!-- title bar -->
      <div class="flex items-center gap-2.5 px-4 py-3 border-b border-base-300 bg-base-200">
        <span class="flex gap-1.5" aria-hidden="true">
          <i class="w-2.5 h-2.5 rounded-full bg-base-300 block"></i>
          <i class="w-2.5 h-2.5 rounded-full bg-base-300 block"></i>
          <i class="w-2.5 h-2.5 rounded-full bg-base-300 block"></i>
        </span>
        <span class="text-xs font-semibold text-base-content/60">Your coding agent</span>
      </div>

      <div class="flex flex-col gap-4 px-4 py-5">
        <!-- you -->
        <div class="flex flex-row-reverse gap-2.5 items-start self-end max-w-[92%]">
          <span class="flex-none w-[30px] h-[30px] rounded-full grid place-items-center text-[9.5px] font-bold uppercase tracking-wide bg-base-300 text-base-content">
            You
          </span>
          <div class="rounded-2xl rounded-br px-4 py-3 text-sm leading-relaxed border border-primary bg-primary/10">
            {agent_prompt(@base_url)}
          </div>
        </div>

        <!-- agent -->
        <div class="flex gap-2.5 items-start self-start max-w-[92%] min-w-0">
          <span class="flex-none w-[30px] h-[30px] rounded-full grid place-items-center text-sm bg-primary text-primary-content">
            ✦
          </span>
          <div class="rounded-2xl rounded-bl px-4 py-3 text-sm leading-relaxed border border-base-300 bg-base-200 min-w-0">
            <p class="text-base-content/60 text-[13.5px] mb-3">
              Read <code class="font-mono">llms.txt</code>
              — the whole contract. No signup form, no key exchange.
            </p>

            <div class="flex flex-col gap-1.5 mb-3">
              <div
                :for={
                  run <- [
                    {"GET", "/llms.txt", "the contract, read first"},
                    {"POST", "/api/v1/accounts", "account created"},
                    {"GET", "/api/ping", "run_started · tool_called · run_completed"}
                  ]
                }
                class="flex items-center gap-2 flex-wrap rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-xs"
              >
                <span class="text-success font-bold" aria-hidden="true">✓</span>
                <span class={[
                  "text-[9.5px] font-bold tracking-wider px-1.5 py-0.5 rounded border bg-base-200",
                  elem(run, 0) == "GET" && "text-success border-success",
                  elem(run, 0) == "POST" && "text-primary border-primary"
                ]}>
                  {elem(run, 0)}
                </span>
                <code class="font-mono font-semibold break-words">{elem(run, 1)}</code>
                <span class="text-base-content/40 text-[11.5px]">{elem(run, 2)}</span>
              </div>
            </div>

            <div class="flex items-center gap-2 flex-wrap mb-2.5">
              <span class="text-[11.5px] font-bold px-2.5 py-0.5 rounded-full bg-success/15 text-success">
                3 event types reporting
              </span>
              <span class="text-[11.5px] font-bold px-2.5 py-0.5 rounded-full bg-base-300 text-base-content/70">
                0 credentials sent
              </span>
            </div>

            <p class="text-[13.5px] text-base-content/60">
              Every parameter checked against the do-not-send list before it went in a URL.
            </p>

            <!-- the step that gets skipped -->
            <div class="flex items-center gap-3 mt-3 rounded-xl border border-success bg-success/10 px-3 py-2.5">
              <span class="flex-none w-[34px] h-[34px] rounded-lg grid place-items-center bg-success text-[9px] font-bold tracking-wide text-success-content">
                TXT
              </span>
              <div class="min-w-0">
                <strong class="block text-sm font-mono">llms.txt</strong>
                <span class="text-base-content/60 text-xs">
                  Analytics section added · committed
                </span>
              </div>
              <span class="ml-auto text-success font-bold text-[11px] uppercase tracking-wider whitespace-nowrap">
                Updated
              </span>
            </div>
          </div>
        </div>
      </div>

      <!-- composer: decorative, but a chat without one does not read as a chat -->
      <div class="flex items-center gap-2.5 px-4 py-3 border-t border-base-300 bg-base-200">
        <span class="flex-1 min-w-0 bg-base-100 border border-base-300 rounded-full px-4 py-2 text-[13.5px] text-base-content/40 truncate">
          Ask it what your busiest hour was…
        </span>
        <span
          class="flex-none w-8 h-8 rounded-full grid place-items-center bg-primary text-primary-content"
          aria-hidden="true"
        >
          ↑
        </span>
      </div>
    </div>
    """
  end

  @doc """
  The prompt to hand a coding agent.

  The integration is a thing to delegate rather than a snippet to paste, so the
  hero shows what is actually worth copying. The host is this deployment's own,
  like every other URL on these pages, so a self-hosted instance does not point
  its readers at somebody else's contract.
  """
  def agent_prompt(base_url) do
    "Please read #{base_url}/llms.txt and follow all the instructions exactly. " <>
      "Update our llms.txt with the instructed changes."
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
