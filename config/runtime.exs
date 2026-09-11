import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/web_analytics start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :web_analytics, WebAnalyticsWeb.Endpoint, server: true
end

config :web_analytics, WebAnalyticsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4001"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :web_analytics, WebAnalyticsWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      # No `E` modifier on these. The generator emits it, but it only exists in
      # Elixir 1.19 and later, and a sigil is expanded at compile time — so on
      # 1.18 this file fails to compile even in production, where the block it
      # sits in never runs. For patterns matching file paths the modifier
      # changes nothing anyway: it only affects whether `$` matches before a
      # trailing newline, and paths do not contain newlines.
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/web_analytics_web/router\.ex$",
        ~r"lib/web_analytics_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # These messages name .env deliberately. install.sh writes every one of these
  # variables there, so by far the likeliest cause of seeing this is a bare
  # `mix` command in a shell that has not loaded it — and the stock message
  # sends people off to invent a value that already exists three lines away.
  env_hint = """

  install.sh writes this to .env. Load it first:

      . ./.env && mix phx.server

  or use ./bin/server, which loads it for you.
  """

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      #{env_hint}
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :web_analytics, WebAnalytics.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      #{env_hint}
      """

  # The IP salt's whole job is to make the stored hashes unguessable. Left at the
  # compiled-in default it would be a *published* constant, and the IPv4 space is
  # small enough to walk in minutes — every hash would be trivially reversible.
  # Falling back to the secret key base keeps it deployment-specific and
  # high-entropy without adding another variable that has to be remembered.
  config :web_analytics, ip_salt: System.get_env("IP_SALT") || secret_key_base

  host = System.get_env("PHX_HOST") || "example.com"

  # Account email goes through Mailgun.
  #
  # Left unconfigured, delivery is stubbed: the application starts and works, and
  # anything it would have sent is written to the log instead of vanishing. That
  # matters because the mail in question is how people get into their accounts —
  # a silent failure here looks like a broken signup, not a missing setting.
  case System.get_env("MAILGUN_API_KEY") do
    nil ->
      IO.warn("""
      MAILGUN_API_KEY is not set, so account email is stubbed.

      Registration and sign-in links will be written to the log instead of being
      delivered. Set MAILGUN_API_KEY, MAILGUN_DOMAIN and MAIL_FROM in .env to
      turn delivery on.
      """)

      config :web_analytics, WebAnalytics.Mailer, adapter: WebAnalytics.Mailer.Stub

    api_key ->
      config :web_analytics, WebAnalytics.Mailer,
        adapter: Swoosh.Adapters.Mailgun,
        api_key: api_key,
        domain: System.get_env("MAILGUN_DOMAIN") || host,
        base_url: System.get_env("MAILGUN_BASE_URL") || "https://api.mailgun.net/v3"
  end

  # Must be an address on a domain the mail provider has verified, or it refuses
  # to send and registration looks broken rather than misconfigured.
  config :web_analytics,
         :mail_from,
         System.get_env("MAIL_FROM") || "logan@csuitenecessities.com"

  # How this deployment is reached from outside, which is not always https on
  # 443. It matters more here than in most apps: /llms.txt is the integration
  # contract and every endpoint in it is an absolute URL built from these
  # values, so a self-hosted box left on the defaults would hand integrating
  # agents a link to somebody else's domain.
  scheme = System.get_env("PHX_SCHEME") || "https"

  url_port =
    case System.get_env("PHX_PORT") do
      nil -> if scheme == "https", do: 443, else: 80
      value -> String.to_integer(value)
    end

  config :web_analytics, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :web_analytics, WebAnalyticsWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :web_analytics, WebAnalyticsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :web_analytics, WebAnalyticsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
