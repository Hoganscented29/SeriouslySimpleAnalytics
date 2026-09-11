defmodule WebAnalytics.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before anything else. A half-started application that then refuses to
    # serve is worse than one that never started: it holds the port, opens
    # database connections, and buries the reason in a log.
    WebAnalytics.License.enforce!()

    children = [
      WebAnalyticsWeb.Telemetry,
      WebAnalytics.Repo,
      {DNSCluster, query: Application.get_env(:web_analytics, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WebAnalytics.PubSub},
      WebAnalytics.RateLimiter,
      WebAnalytics.Sites.Cache,
      WebAnalytics.Geo.Database,
      WebAnalytics.Ingest.Collector,
      WebAnalytics.Analytics.AnomalyWorker,
      # Start to serve requests, typically the last entry
      WebAnalyticsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WebAnalytics.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WebAnalyticsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
