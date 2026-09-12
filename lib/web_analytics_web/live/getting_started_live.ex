defmodule WebAnalyticsWeb.GettingStartedLive do
  @moduledoc """
  How to get data flowing, on a page of its own.

  These instructions used to sit at the bottom of the dashboard, which is the
  wrong place for them twice over: an account with traffic already scrolls past
  them every visit, and an account with none has to scroll past every empty
  chart to reach the one thing it needs. A page you can link someone to — or
  bookmark while you wire it up — is what they were always for.
  """
  use WebAnalyticsWeb, :live_view

  import WebAnalyticsWeb.IntegrationComponents, only: [integration_chat: 1]

  alias WebAnalytics.Sites

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    # Same call the dashboard makes, so arriving here first still gets you an
    # account rather than an instruction to go and make one.
    sites = Sites.ensure_site_for_user!(user)

    {:ok,
     socket
     |> assign(:page_title, "Getting started")
     |> assign(:sites, sites)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :site, resolve_site(socket.assigns.sites, params["site"]))}
  end

  defp resolve_site(sites, key) do
    Enum.find(sites, List.first(sites), &(&1.key == key))
  end

  defp base_url, do: url(~p"/") |> String.trim_trailing("/")

  defp snippet(site, endpoint) do
    ~s|<script src="#{endpoint}/wa.js" data-site="#{site.key}" defer></script>|
  end

  defp agent_prompt(site, endpoint) do
    WebAnalyticsWeb.DashboardLive.agent_prompt(site, endpoint)
  end
end
