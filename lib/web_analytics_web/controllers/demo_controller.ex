defmodule WebAnalyticsWeb.DemoController do
  @moduledoc """
  A small tracked site used to exercise the tracker end to end.

  It deliberately contains the awkward cases: a multi-page path worth following
  as a flow, content long enough for scroll depth to mean something, buttons and
  links that leave the site, and a form that can be either submitted or
  abandoned.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalytics.Sites

  plug :put_demo_site

  def home(conn, _params), do: render(conn, :home)
  def pricing(conn, _params), do: render(conn, :pricing)
  def docs(conn, _params), do: render(conn, :docs)
  def thanks(conn, _params), do: render(conn, :thanks)

  def signup(conn, params) do
    redirect(conn, to: ~p"/demo/thanks?plan=#{params["plan"] || "pro"}")
  end

  # The demo tracks against whichever site key exists, creating one on first
  # visit so the page is never silently un-tracked.
  defp put_demo_site(conn, _opts) do
    site =
      case Sites.fetch_site_by_key("demo") do
        nil ->
          case Sites.create_site(%{key: "demo", name: "Demo Site", domain: "localhost"}) do
            {:ok, site} -> site
            {:error, _} -> Sites.get_site_by_key("demo")
          end

        site ->
          site
      end

    conn
    |> assign(:site_key, site && site.key)
    |> put_root_layout(html: false)
    |> put_layout(html: false)
  end
end
