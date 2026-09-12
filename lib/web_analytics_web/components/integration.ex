defmodule WebAnalyticsWeb.IntegrationComponents do
  @moduledoc """
  How this product is integrated, drawn the way it is actually done.

  Shared between the landing pages and the dashboard because it is one act
  described in two places, and two copies of it would drift — the landing page
  telling people to hand a line to an agent while the dashboard still showed a
  snippet to paste.
  """
  use Phoenix.Component
  use WebAnalyticsWeb, :verified_routes

  attr :crawler_summary, :map, default: nil

  @doc """
  What the tag on this page has recorded about the reader, live, beside what it
  recorded about the robots.

  Describing dwell time and scroll depth is abstract. Showing someone their own,
  updating while they read, is the same claim in a form they can check. The
  left half is read straight out of the tag in the browser — no request, no
  round trip, just the state the tag already holds. The right half is this
  site's own crawler traffic over the last day, which the server records
  because the tag cannot see it.
  """
  def live_proof(assigns) do
    ~H"""
    <section class="rounded-2xl border border-base-300 bg-base-100 overflow-hidden" id="live-proof">
      <div class="px-4 py-3 border-b border-base-300 bg-base-200 flex items-center gap-2 flex-wrap">
        <span class="relative flex h-2 w-2" aria-hidden="true">
          <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-60"></span>
          <span class="relative inline-flex rounded-full h-2 w-2 bg-success"></span>
        </span>
        <span class="text-xs font-semibold">This page is running the tag on you right now</span>
        <span class="text-[11px] text-base-content/50">
          — nothing below leaves your browser except what the tag already sends
        </span>
      </div>

      <div class="grid md:grid-cols-2 divide-y md:divide-y-0 md:divide-x divide-base-300">
        <!-- the reader -->
        <div class="p-4">
          <div class="text-[11px] uppercase tracking-wide text-base-content/50 mb-3">
            Your visit, as recorded
          </div>

          <div class="grid grid-cols-2 gap-2">
            <div
              :for={
                {label, id, hint} <- [
                  {"Time on page", "wa-dwell", "dwell"},
                  {"Engaged", "wa-active", "actually reading"},
                  {"Scroll depth", "wa-scroll", "furthest point"},
                  {"Clicks", "wa-clicks", "auto-captured"}
                ]
              }
              class="rounded-lg border border-base-300 px-3 py-2"
            >
              <div class="text-[10px] text-base-content/50">{label}</div>
              <div id={id} class="text-lg font-semibold tabular-nums leading-tight">—</div>
              <div class="text-[10px] text-base-content/40">{hint}</div>
            </div>
          </div>

          <dl class="mt-3 space-y-1 text-[11px]">
            <div
              :for={
                {label, id} <- [
                  {"Page", "wa-path"},
                  {"Viewport", "wa-viewport"},
                  {"Time zone", "wa-tz"},
                  {"Connection", "wa-conn"},
                  {"Platform", "wa-plat"}
                ]
              }
              class="flex justify-between gap-3 py-1 border-b border-base-200 last:border-0"
            >
              <dt class="text-base-content/50 flex-none">{label}</dt>
              <dd id={id} class="font-mono text-right truncate text-base-content/80">—</dd>
            </div>
          </dl>

          <p id="wa-stale" hidden class="text-[10px] text-warning mt-3">
            Your browser has an older copy of the tag cached, so these are not filling in.
            A reload in a few minutes will pick up the current one.
          </p>

          <p class="text-[10px] text-base-content/40 mt-3">
            No cookies, no address stored. Your IP resolves a city in-request and is then
            salted, hashed and discarded.
          </p>
        </div>

        <!-- the robots -->
        <div class="p-4">
          <div class="text-[11px] uppercase tracking-wide text-base-content/50 mb-3">
            Bots that visited this site — last 24 hours
          </div>

          <div :if={@crawler_summary}>
            <div class="grid grid-cols-3 gap-2 mb-3">
              <div
                :for={
                  stat <- [
                    {"Visits", @crawler_summary.total_sessions},
                    {"Pages taken", @crawler_summary.total_pageviews},
                    {"AI crawlers", @crawler_summary.ai_sessions}
                  ]
                }
                class="rounded-lg border border-base-300 px-3 py-2"
              >
                <div class="text-[10px] text-base-content/50">{elem(stat, 0)}</div>
                <div class="text-lg font-semibold tabular-nums leading-tight">
                  {elem(stat, 1)}
                </div>
              </div>
            </div>

            <div class="space-y-1">
              <% peak =
                @crawler_summary.crawlers |> Enum.map(& &1.sessions) |> Enum.max(fn -> 0 end) %>
              <div
                :for={crawler <- @crawler_summary.crawlers}
                class="flex items-center gap-2 text-[11px]"
              >
                <div class="flex-1 min-w-0 relative h-5">
                  <div
                    class={[
                      "absolute inset-y-0 left-0 rounded",
                      crawler.kind == "ai" && "bg-primary/20",
                      crawler.kind != "ai" && "bg-base-300/60"
                    ]}
                    style={"width: #{if peak > 0, do: crawler.sessions * 100 / peak, else: 0}%"}
                  >
                  </div>
                  <span class="relative px-2 font-mono leading-5 truncate block">
                    {crawler.name}
                    <span :if={crawler.kind == "ai"} class="text-primary">· AI</span>
                  </span>
                </div>
                <span class="tabular-nums text-base-content/60 w-8 text-right">
                  {crawler.sessions}
                </span>
              </div>
            </div>

            <p class="text-[10px] text-base-content/40 mt-3">
              These never ran the tag — they fetch HTML and stop. Our server reports them to our
              own account, which is the same few lines the crawler pages tell you to run at
              your origin.
            </p>
          </div>

          <div :if={is_nil(@crawler_summary)} class="text-sm text-base-content/50 py-8 text-center">
            No automated traffic recorded in the last day.
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  A dashboard, drawn.

  The hero has to answer "what do I get" before anyone reads a word, and a
  screenshot would be a binary that goes stale the moment the real thing
  changes. This is markup: theme-aware, selectable, and it costs nothing to
  keep honest.

  The numbers are illustrative — a deployment with real traffic in it, so the
  layout reads as a working tool rather than an empty state. It is `role="img"`
  for that reason: it depicts the product, it is not a report of anything.
  """
  def dashboard_preview(assigns) do
    ~H"""
    <div
      class="rounded-2xl border border-base-300 bg-base-100 overflow-hidden shadow-lg"
      role="img"
      aria-label={
        "An illustration of the dashboard: sessions, visitors, pageviews and dwell time " <>
          "across the top, a bar chart of sessions over the last day, a list of the busiest " <>
          "pages, the AI crawlers seen, and a page-to-page flow diagram."
      }
    >
      <!-- window chrome -->
      <div class="flex items-center gap-2.5 px-4 py-2.5 border-b border-base-300 bg-base-200">
        <span class="flex gap-1.5" aria-hidden="true">
          <i class="w-2.5 h-2.5 rounded-full bg-base-300 block"></i>
          <i class="w-2.5 h-2.5 rounded-full bg-base-300 block"></i>
          <i class="w-2.5 h-2.5 rounded-full bg-base-300 block"></i>
        </span>
        <span class="text-[11px] font-medium text-base-content/50">Analytics</span>
        <span class="flex-1"></span>
        <span class="hidden sm:flex gap-1">
          <span
            :for={{range, active} <- [{"24h", false}, {"7d", true}, {"30d", false}]}
            class={[
              "text-[10px] px-1.5 py-0.5 rounded",
              active && "bg-primary text-primary-content font-medium",
              !active && "text-base-content/40"
            ]}
          >
            {range}
          </span>
        </span>
      </div>

      <div class="p-3 sm:p-4 space-y-3">
        <!-- headline numbers -->
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <div
            :for={
              stat <- [
                {"Sessions", "12,480", "+18%"},
                {"Visitors", "8,204", "+11%"},
                {"Pageviews", "34,201", "+22%"},
                {"Avg dwell", "2m 41s", "1m 09s active"}
              ]
            }
            class="rounded-lg border border-base-300 px-3 py-2"
          >
            <div class="text-[10px] text-base-content/50">{elem(stat, 0)}</div>
            <div class="text-base sm:text-lg font-semibold tabular-nums leading-tight">
              {elem(stat, 1)}
            </div>
            <div class="text-[10px] text-success">{elem(stat, 2)}</div>
          </div>
        </div>

        <!-- sessions over time -->
        <div class="rounded-lg border border-base-300 p-3">
          <div class="flex items-baseline justify-between mb-2">
            <span class="text-[11px] font-medium">Sessions over time</span>
            <span class="text-[10px] text-base-content/40">peak 1,204/hour</span>
          </div>
          <div class="flex items-end gap-[3px] h-16">
            <div
              :for={
                height <- [
                  28,
                  34,
                  22,
                  41,
                  55,
                  48,
                  62,
                  71,
                  58,
                  44,
                  66,
                  83,
                  91,
                  74,
                  68,
                  88,
                  100,
                  79,
                  61,
                  52,
                  47,
                  58,
                  40,
                  33
                ]
              }
              class="flex-1 bg-primary/80 rounded-sm"
              style={"height: #{height}%"}
            >
            </div>
          </div>
        </div>

        <div class="grid sm:grid-cols-2 gap-3">
          <!-- busiest pages -->
          <div class="rounded-lg border border-base-300 p-3">
            <div class="text-[11px] font-medium mb-2">Busiest pages</div>
            <div class="space-y-1.5">
              <div
                :for={
                  {path, count, width} <- [
                    {"/", "9,412", 100},
                    {"/pricing", "4,806", 51},
                    {"/docs/quickstart", "3,271", 35},
                    {"/blog/why-llms-txt", "2,118", 22},
                    {"/changelog", "1,004", 11}
                  ]
                }
                class="flex items-center gap-2"
              >
                <div class="flex-1 min-w-0 relative h-4">
                  <div
                    class="absolute inset-y-0 left-0 bg-primary/15 rounded"
                    style={"width: #{width}%"}
                  >
                  </div>
                  <span class="relative px-1.5 text-[10px] font-mono leading-4 truncate block">
                    {path}
                  </span>
                </div>
                <span class="text-[10px] tabular-nums text-base-content/60 w-10 text-right">
                  {count}
                </span>
              </div>
            </div>
          </div>

          <!-- crawlers -->
          <div class="rounded-lg border border-base-300 p-3">
            <div class="text-[11px] font-medium mb-2">AI crawlers, named</div>
            <div class="space-y-1.5">
              <div
                :for={
                  {name, count} <- [
                    {"ClaudeBot", "1,842"},
                    {"GPTBot", "1,506"},
                    {"PerplexityBot", "744"},
                    {"Bytespider", "389"},
                    {"CCBot", "201"}
                  ]
                }
                class="flex items-center justify-between gap-2"
              >
                <span class="text-[10px] font-mono truncate">{name}</span>
                <span class="text-[10px] tabular-nums text-base-content/60">{count}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- flow -->
        <div class="rounded-lg border border-base-300 p-3">
          <div class="text-[11px] font-medium mb-2">Page-to-page flow</div>
          <div class="flex items-center gap-1.5 overflow-hidden text-[10px] font-mono">
            <span
              :for={{node, index} <- Enum.with_index(["/", "/pricing", "/docs", "/signup"])}
              class="contents"
            >
              <span :if={index > 0} class="text-base-content/25">→</span>
              <span class="px-2 py-1 rounded bg-base-200 whitespace-nowrap">{node}</span>
            </span>
            <span class="text-base-content/25">→</span>
            <span class="px-2 py-1 rounded bg-success/15 text-success whitespace-nowrap">
              converted
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :base_url, :string, required: true
  attr :prompt, :string, default: nil
  attr :creates_account, :boolean, default: true

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
            {@prompt || agent_prompt(@base_url)}
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
                  run <-
                    [{"GET", "/llms.txt", "the contract, read first"}] ++
                      if(@creates_account,
                        do: [{"POST", "/api/v1/accounts", "account created"}],
                        else: []
                      ) ++
                      [{"GET", "/api/ping", "run_started · tool_called · run_completed"}]
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
          Ask it what your busiest hour was<span class="wa-typing" aria-hidden="true"><i class="not-italic inline-block">.</i><i class="not-italic inline-block">.</i><i class="not-italic inline-block">.</i></span>
        </span>
        <span
          class="wa-send flex-none w-8 h-8 rounded-full grid place-items-center bg-primary text-primary-content"
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
    # The reader is signed out, so this says "create an account" where the
    # dashboard's copy names a real one. Naming what to report matters more than
    # it looks: an agent told only to "add analytics" picks its own events, and
    # every integration ends up measuring something different.
    """
    Read #{base_url}/llms.txt and instrument this project with \
    SeriouslySimpleAnalytics. Create an account and set project to this tool's \
    name. Report at least: first run, run started/completed with an outcome, \
    each tool call, and errors by kind. Reuse one sid for the whole run. Never \
    send credentials, prompts or completions. Update our llms.txt with the \
    instructed changes.
    """
    |> String.trim()
  end
end
