import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :web_analytics, WebAnalytics.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "web_analytics_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :web_analytics, WebAnalyticsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xG2Yf9vVsZcWJc6UsyGRRzO++iGLNMkHa6+jit1ZifElckd+ktOE1uhM5WqY4LA5",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests drive ingest and classification explicitly rather than on a timer.
config :web_analytics, WebAnalytics.Ingest.Collector, flush_interval_ms: 60_000

config :web_analytics, :anomaly, enabled: false, min_sample: 5

# The site cache outlives a sandbox transaction, so a site created and rolled
# back by one test would still be served to the next one that asks for its key.
config :web_analytics, WebAnalytics.Sites.Cache, enabled: false

# Emails are asserted on, never delivered.
config :web_analytics, WebAnalytics.Mailer, adapter: Swoosh.Adapters.Test

# Nothing is delivered here, so no HTTP client is needed.
config :swoosh, :api_client, false
