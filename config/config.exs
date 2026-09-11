# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :web_analytics,
  ecto_repos: [WebAnalytics.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :web_analytics, WebAnalyticsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WebAnalyticsWeb.ErrorHTML, json: WebAnalyticsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WebAnalytics.PubSub,
  live_view: [signing_salt: "xt9yzR1v"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  web_analytics: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  web_analytics: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Salt for the day-rotating IP hash. Raw IPs are never stored. This value is for
# development only — `config/runtime.exs` replaces it in production, because a
# salt that ships in the repo is not a salt.
config :web_analytics, ip_salt: "web-analytics-dev-salt"

# Write buffering for the collect endpoint. The tracker beacons once a second
# per visitor, so consecutive beacons from one session are merged into a single
# transaction on each flush.
config :web_analytics, WebAnalytics.Ingest.Collector,
  flush_interval_ms: 1_000,
  max_queue: 20_000

# Dwell-time anomaly filtering. These only decide how sessions are *labelled* —
# the dashboard toggle decides whether the label is applied to a report.
config :web_analytics, :anomaly,
  enabled: true,
  interval_ms: 30_000,
  window_days: 7,
  batch_size: 500,
  min_sample: 30,
  z_threshold: 3.5,
  min_dwell_ms: 1_000,
  fast_page_ms: 700,
  hyper_pages_per_second: 1.0,
  idle_tab_ms: 14_400_000,
  idle_active_ratio: 0.02,
  max_dwell_ms: 43_200_000,
  stale_tick_count: 60

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
