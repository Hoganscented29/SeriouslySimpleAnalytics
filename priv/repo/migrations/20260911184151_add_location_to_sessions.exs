defmodule WebAnalytics.Repo.Migrations.AddLocationToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :country_code, :string
      add :country, :string
      # State, province, or whatever the country's first-level division is.
      add :region, :string
      add :region_code, :string
      add :city, :string
      add :latitude, :float
      add :longitude, :float
      # Radius the source claims the coordinates are good to, in kilometres.
      add :accuracy_km, :integer
      # Which of the resolvers produced this: a CDN name, "mmdb", or "timezone".
      # Kept so the dashboard can distinguish a city-level fix from a
      # country-level guess rather than presenting both as equally certain.
      add :geo_source, :string
    end

    create index(:sessions, [:site_id, :country_code, :started_at])
    create index(:sessions, [:site_id, :country_code, :region])
    create index(:sessions, [:site_id, :city])
  end
end
