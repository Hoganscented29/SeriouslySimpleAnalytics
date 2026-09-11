defmodule WebAnalytics.Repo.Migrations.CreateSites do
  use Ecto.Migration

  def change do
    create table(:sites) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :domain, :string

      # Per-site tracker configuration, handed to the JS snippet at load time.
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sites, [:key])
  end
end
