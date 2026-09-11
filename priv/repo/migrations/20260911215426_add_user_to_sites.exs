defmodule WebAnalytics.Repo.Migrations.AddUserToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      # Nullable: sites created before accounts existed have no owner, and the
      # demo site belongs to nobody on purpose.
      add :user_id, references(:users, on_delete: :delete_all)

      # Set when an account was created by the API on someone's behalf and has
      # not yet been claimed by the person whose email it carries.
      add :claimed_at, :utc_datetime_usec
    end

    create index(:sites, [:user_id])
  end
end
