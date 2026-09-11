defmodule WebAnalyticsWeb.ProviderHTML do
  @moduledoc "Renders the per-provider crawler analytics pages."
  use WebAnalyticsWeb, :html

  import WebAnalyticsWeb.LandingHTML, only: [site_header: 1, site_footer: 1, cta: 1]

  alias WebAnalytics.Crawlers.Provider

  embed_templates "provider_html/*"

  attr :body, :list, required: true
  attr :agents, :list, default: []

  @doc """
  Renders a section body.

  The content is data rather than markup so every provider page is laid out
  identically and a new one cannot arrive with its own idea of what a heading
  looks like.
  """
  def prose(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= for element <- @body do %>
        <p :if={match?({:p, _}, element)} class="text-base-content/80 leading-relaxed">
          {elem(element, 1)}
        </p>

        <h3 :if={match?({:h3, _}, element)} class="text-lg font-medium pt-2">
          {elem(element, 1)}
        </h3>

        <ul :if={match?({:ul, _}, element)} class="list-disc list-outside pl-5 space-y-2">
          <li :for={item <- elem(element, 1)} class="text-base-content/80 leading-relaxed">
            {item}
          </li>
        </ul>

        <ol :if={match?({:ol, _}, element)} class="list-decimal list-outside pl-5 space-y-2">
          <li :for={item <- elem(element, 1)} class="text-base-content/80 leading-relaxed">
            {item}
          </li>
        </ol>

        <pre
          :if={match?({:code, _}, element)}
          class="bg-base-200 rounded p-4 text-xs overflow-x-auto"
        ><code>{elem(element, 1)}</code></pre>

        <div
          :if={match?({:note, _}, element)}
          class="rounded-box border border-warning/40 bg-warning/5 p-4 text-sm text-base-content/80"
        >
          {elem(element, 1)}
        </div>

        <div :if={match?({:agents, _}, element)} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>User agent token</th>
                <th>robots.txt</th>
                <th>What it is for</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={agent <- @agents}>
                <td class="font-mono text-xs whitespace-nowrap">{agent.token}</td>
                <td class="font-mono text-xs whitespace-nowrap">{agent.robots}</td>
                <td class="text-sm text-base-content/70">
                  {agent.purpose}
                  <div class="font-mono text-[11px] text-base-content/50 mt-1 break-all">
                    {agent.example}
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  @doc "The install snippet shown on every provider page."
  def script_tag(base_url, site_key) do
    ~s|<script src="#{base_url}/wa.js" data-site="#{site_key}" defer></script>|
  end

  @doc "A provider's public path."
  def provider_path(provider), do: Provider.path(provider)

  @doc "A provider's page title, which is also its keyword phrase."
  def provider_title(provider), do: Provider.title(provider)

  @doc "The keyword this page is written around."
  def provider_keyword(provider), do: Provider.keyword(provider)

  @doc "The other providers, for cross-linking."
  def other_providers(provider), do: Provider.others(provider)
end
