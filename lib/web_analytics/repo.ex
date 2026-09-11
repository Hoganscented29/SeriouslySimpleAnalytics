defmodule WebAnalytics.Repo do
  use Ecto.Repo,
    otp_app: :web_analytics,
    adapter: Ecto.Adapters.Postgres
end
