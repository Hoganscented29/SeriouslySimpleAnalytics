defmodule WebAnalytics.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  def change do
    # Deliberately not settable through any form or changeset cast — the only
    # way to grant it is `mix ssa.admin`, run by someone with shell access to
    # the box. An admin sees every account's data, so it should not be reachable
    # from anything an HTTP request can touch.
    alter table(:users) do
      add :admin, :boolean, null: false, default: false
    end

    create index(:users, [:admin], where: "admin", name: :users_admin_index)
  end
end
