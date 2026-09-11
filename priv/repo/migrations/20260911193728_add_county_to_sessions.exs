defmodule WebAnalytics.Repo.Migrations.AddCountyToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      # Between city and state. GeoIP databases do not carry it, so this is only
      # ever populated by a caller that tells us — which is the case the ping
      # API is built for, since a server-side ping's own address says where the
      # tool runs, not where its user is.
      add :county, :string
    end

    create index(:sessions, [:site_id, :county])
  end
end
