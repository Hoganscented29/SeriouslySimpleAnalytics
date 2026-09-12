defmodule WebAnalyticsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use WebAnalyticsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  This site's own tracking tag.

  An analytics product that does not measure itself is taking its customers'
  word for whether it works. Rendered only when SSA_SELF_SITE_KEY names an
  account, so a clone or a self-hosted copy reports nowhere by default rather
  than into ours.
  """
  def self_tracking(assigns) do
    assigns = assign(assigns, :key, Application.get_env(:web_analytics, :self_site_key))

    ~H"""
    <script :if={@key} src={~p"/wa.js"} data-site={@key} defer>
    </script>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-300 bg-base-100">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 h-14 flex items-center gap-6">
        <a href={~p"/dashboard"} class="flex items-center gap-2 font-semibold">
          <span class="w-2.5 h-2.5 rounded-full bg-primary inline-block" /> SeriouslySimpleAnalytics
        </a>
        <nav class="flex items-center gap-4 text-sm">
          <.link navigate={~p"/dashboard"} class="hover:text-primary">Dashboard</.link>
          <.link href={~p"/"} class="hover:text-primary">Home</.link>
          <.link
            :if={@current_scope && WebAnalytics.Accounts.admin?(@current_scope.user)}
            navigate={~p"/admin"}
            class="hover:text-primary font-medium"
          >
            Admin
          </.link>
        </nav>
        <div class="flex-1" />
        <div :if={@current_scope} class="hidden sm:flex items-center gap-3 text-sm">
          <span class="text-base-content/60">{@current_scope.user.email}</span>
          <.link href={~p"/users/settings"} class="link link-hover">Settings</.link>
          <.link href={~p"/users/log-out"} method="delete" class="link link-hover">Log out</.link>
        </div>
        <.theme_toggle />
      </div>
    </header>

    <main class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <footer class="border-t border-base-300 mt-8">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
        <span class="text-base-content/60">SeriouslySimpleAnalytics</span>
        <span class="text-base-content/30">·</span>
        <a
          href="mailto:me@LoganBesecker.com?subject=Business%20development%20inquiry"
          class="link link-hover font-medium"
        >
          Business development inquiries
        </a>
      </div>
    </footer>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
