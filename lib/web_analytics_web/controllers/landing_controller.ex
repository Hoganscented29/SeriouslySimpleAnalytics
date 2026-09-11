defmodule WebAnalyticsWeb.LandingController do
  @moduledoc """
  The public landing page and the machine-readable integration guide.

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
    |> assign(:page_title, "Free analytics for AI tools")
    |> assign(:site_key, demo_site_key())
    |> assign(:base_url, base_url(conn))
    |> render(:home)
  end

  # The canonical host is written into priv/docs/llms.txt literally, so the file
  # reads correctly when browsed on GitHub. It is still rewritten per deployment
  # here: a self-hosted instance serving the canonical URL would be telling its
  # own integrators to send their events somewhere else entirely.
  @canonical_url "https://seriouslysimpleanalytics.com"

  def llms(conn, _params) do
    body = String.replace(@llms, @canonical_url, base_url(conn))

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, body)
  end

  defp base_url(conn) do
    conn |> url(~p"/") |> String.trim_trailing("/")
  end

  # The landing page shows a copy-pasteable snippet, so it needs a real key.
  defp demo_site_key do
    case Sites.list_sites() do
      [site | _] -> site.key
      [] -> "YOUR_ACCOUNT_ID"
    end
  end
end
