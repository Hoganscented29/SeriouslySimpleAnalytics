defmodule WebAnalyticsWeb.LandingHTML do
  @moduledoc "The public landing page."
  use WebAnalyticsWeb, :html

  embed_templates "landing_html/*"

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
