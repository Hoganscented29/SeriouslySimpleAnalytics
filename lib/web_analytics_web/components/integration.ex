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
