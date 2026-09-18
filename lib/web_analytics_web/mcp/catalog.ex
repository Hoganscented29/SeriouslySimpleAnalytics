defmodule WebAnalyticsWeb.MCP.Catalog do
  @moduledoc """
  The MCP server's resources and prompts.

  One resource — the integration contract, the same llms.txt an agent would
  fetch over HTTP — and two prompts for the two things people most often want
  from an analytics server: wire it into this project, and tell me how it is
  doing.
  """

  alias WebAnalyticsWeb.LandingController

  @doc "Resources for resources/list."
  def resources(base_url) do
    [
      %{
        "uri" => base_url <> "/llms.txt",
        "name" => "llms.txt",
        "title" => "Integration guide (llms.txt)",
        "description" =>
          "The complete contract for adding web analytics or AI agent analytics to a project: " <>
            "the event API, every parameter, sessions, users, metrics, and what never to send.",
        "mimeType" => "text/markdown"
      }
    ]
  end

  @doc "Reads a resource by URI."
  def read_resource(uri, base_url) do
    if uri == base_url <> "/llms.txt" do
      {:ok,
       [
         %{
           "uri" => uri,
           "mimeType" => "text/markdown",
           "text" => LandingController.llms_text(base_url)
         }
       ]}
    else
      :error
    end
  end

  @doc "Prompts for prompts/list."
  def prompts do
    [
      %{
        "name" => "add_analytics",
        "title" => "Add analytics to this project",
        "description" =>
          "Instrument the current project with free web analytics and AI agent analytics: the " <>
            "website tag, events at the right places in the code, and the llms.txt handoff.",
        "arguments" => [
          %{"name" => "project", "description" => "The project's name.", "required" => false},
          %{
            "name" => "account_id",
            "description" => "An existing account ID, if there is one.",
            "required" => false
          }
        ]
      },
      %{
        "name" => "analytics_report",
        "title" => "Analytics report",
        "description" =>
          "Summarise traffic, top pages, sources, events, metrics and users for a time range, and " <>
            "call out what changed.",
        "arguments" => [
          %{
            "name" => "range",
            "description" => "1h, 24h, 7d, 30d or all. Defaults to 7d.",
            "required" => false
          }
        ]
      }
    ]
  end

  @doc "Renders a prompt."
  def get_prompt("add_analytics", arguments, base_url) do
    project = present(arguments["project"]) || "this project"

    account =
      case present(arguments["account_id"]) do
        nil ->
          "Create an account with the create_analytics_account tool (one for the project, reused forever)."

        key ->
          "Use the existing account ID #{key}."
      end

    text = """
    Add SeriouslySimpleAnalytics to #{project}.

    1. #{account}
    2. Read the integration contract, #{base_url}/llms.txt (also available as a resource on this server), and follow it.
    3. If the project has a website, add the script tag from get_integration_guide to its shared layout.
    4. Report events from where they happen in the code: first run, run started and completed with an outcome, each tool call, and errors by kind. Reuse one session ID per run, and send `user` with your own ID for whoever each event is about.
    5. Never send credentials, prompts or completions.
    6. Add the block from "Put this in your own llms.txt" to the project's llms.txt or AGENTS.md.
    7. Send one test event with track_event and confirm it was recorded.
    """

    {:ok, message("Add analytics to #{project}", text)}
  end

  def get_prompt("analytics_report", arguments, _base_url) do
    range = if arguments["range"] in ~w(1h 24h 7d 30d all), do: arguments["range"], else: "7d"

    text = """
    Write an analytics report for the last #{range} using the SeriouslySimpleAnalytics tools.

    Call get_analytics_overview first, then get_traffic_timeseries, get_top_pages, get_traffic_sources, get_events and get_metrics for the same range. If list_users returns anyone, include the most active users.

    Lead with the three things that matter most, then the numbers behind them. Compare against the previous period where the data allows, and say plainly when there is too little traffic to conclude anything.
    """

    {:ok, message("Analytics report (#{range})", text)}
  end

  def get_prompt(_name, _arguments, _base_url), do: :error

  defp message(description, text) do
    %{
      "description" => description,
      "messages" => [
        %{"role" => "user", "content" => %{"type" => "text", "text" => String.trim(text)}}
      ]
    }
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
