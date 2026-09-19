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

  alias WebAnalytics.ApiKeys
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
    site = resolve_site(socket.assigns.sites, params["site"])

    {:noreply,
     socket
     |> assign(:site, site)
     |> assign(:api_keys, ApiKeys.list(site))
     # The one moment a key exists in readable form. Kept only in this socket,
     # so navigating away or reloading is the end of it.
     |> assign(:new_token, nil)}
  end

  @impl true
  def handle_event("create_api_key", params, socket) do
    case ApiKeys.create(socket.assigns.site, params["name"]) do
      {:ok, token, _key} ->
        {:noreply,
         socket
         |> assign(:new_token, token)
         |> assign(:api_keys, ApiKeys.list(socket.assigns.site))}

      {:error, :too_many} ->
        {:noreply,
         put_flash(socket, :error, "Revoke an unused key first — an account can have 20.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create a key.")}
    end
  end

  def handle_event("revoke_api_key", %{"id" => id}, socket) do
    ApiKeys.revoke(socket.assigns.site, id)
    {:noreply, assign(socket, :api_keys, ApiKeys.list(socket.assigns.site))}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  defp resolve_site(sites, key) do
    Enum.find(sites, List.first(sites), &(&1.key == key))
  end

  defp base_url, do: url(~p"/") |> String.trim_trailing("/")

  defp snippet(site, endpoint) do
    ~s|<script src="#{endpoint}/wa.js" data-site="#{site.key}" defer></script>|
  end

  defp claude_command(endpoint, token) do
    "claude mcp add --transport http seriouslysimpleanalytics #{endpoint}/mcp " <>
      "--header \"Authorization: Bearer #{token}\""
  end

  defp agent_prompt(site, endpoint) do
    WebAnalyticsWeb.DashboardLive.agent_prompt(site, endpoint)
  end
end
