defmodule WebAnalyticsWeb.LandingController do
  @moduledoc """
  The two public landing pages and the machine-readable integration guide.

  They are split because they sell different things to different people: `/` is
  for someone with a website, `/AI-Analytics-llms-txt` for someone shipping an AI
  tool. One account and one dashboard serves both, so each page says so and
  links across rather than trying to be both at once.

  `/llms.txt` is the same document an AI agent is expected to fetch before
  integrating, following the llmstxt.org convention. It is rendered rather than
  served statically so the endpoint URLs in it are the ones for this deployment
  — an agent that reads it should not have to guess the host.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalytics.Sites

  @llms_path [__DIR__, "..", "..", "..", "priv", "docs", "llms.txt"]
             |> Path.join()
             |> Path.expand()

  @external_resource @llms_path
  @llms File.read!(@llms_path)

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Free website analytics")
    |> assign(:crawler_summary, crawler_summary())
    |> assign(:site_key, sample_account_id())
    |> assign(:base_url, base_url(conn))
    |> render(:home)
  end

  def ai(conn, _params) do
    conn
    |> assign(:page_title, "Free analytics for AI tools")
    |> assign(:site_key, sample_account_id())
    |> assign(:base_url, base_url(conn))
    |> render(:ai)
  end

  def mcp(conn, _params) do
    conn
    |> assign(:page_title, "Free MCP Server for AI Agent Analytics — SeriouslySimpleAnalytics")
    |> assign(
      :page_description,
      "Free, open-source MCP server for web and AI agent analytics. Track events, pageviews " <>
        "and per-user activity, and ask Claude, Cursor, VS Code or ChatGPT about your traffic."
    )
    |> assign(:base_url, base_url(conn))
    |> assign(:tools, WebAnalyticsWeb.MCP.Tools.definitions())
    |> render(:mcp)
  end

  # The canonical host is written into priv/docs/llms.txt literally, so the file
  # reads correctly when browsed on GitHub. It is still rewritten per deployment
  # here: a self-hosted instance serving the canonical URL would be telling its
  # own integrators to send their events somewhere else entirely.
  @canonical_url "https://seriouslysimpleanalytics.com"

  def llms(conn, _params) do
    body = llms_text(base_url(conn))

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, body)
  end

  @doc "llms.txt with this deployment's URL in it. Also served as an MCP resource."
  def llms_text(base_url), do: String.replace(@llms, @canonical_url, base_url)

  # Real numbers from this deployment's own account, or nil when self-tracking
  # is not configured. Nil hides the panel rather than filling it with zeros,
  # since an empty proof is worse than no proof.
  defp crawler_summary do
    with key when is_binary(key) <- Application.get_env(:web_analytics, :self_site_key),
         site when not is_nil(site) <- Sites.fetch_site_by_key(key) do
      case WebAnalytics.Analytics.recent_crawler_summary(site.id) do
        %{total_sessions: 0} -> nil
        summary -> summary
      end
    else
      _ -> nil
    end
  end

  defp base_url(conn) do
    conn |> url(~p"/") |> String.trim_trailing("/")
  end

  # The pages show a copy-pasteable snippet, so it needs a real account id.
  defp sample_account_id do
    case Sites.list_sites() do
      [site | _] -> site.key
      [] -> "YOUR_ACCOUNT_ID"
    end
  end
end
