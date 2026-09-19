defmodule WebAnalytics.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # The first characters of the key, kept so a list of keys can tell them
      # apart. Never enough to use.
      add :prefix, :string, null: false
      # Only the hash. The key itself is shown once, when it is created, and is
      # not recoverable from anything stored here.
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:site_id])
  end
end
