defmodule WebAnalytics.Repo.Migrations.AddCrawlerToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      # Crawlers are a traffic class, not an anomaly: filtered out of the normal
      # reports by default, but kept and reported on separately.
      add :crawler, :boolean, null: false, default: false
      add :crawler_kind, :string
      add :crawler_name, :string
      # What the tracker itself concluded, if anything — `navigator.webdriver`,
      # a headless fingerprint, or a bot user agent seen client-side.
      add :client_signal, :string
      # Heartbeat resolution this session was tracked at, in milliseconds.
      add :heartbeat_ms, :integer
    end

    create index(:sessions, [:site_id, :crawler, :started_at])
    create index(:sessions, [:site_id, :crawler_kind])
  end
end
