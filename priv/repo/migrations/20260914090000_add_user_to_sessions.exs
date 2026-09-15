defmodule WebAnalytics.Repo.Migrations.AddUserToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      # The caller's own ID for the person or account a session is about. Set
      # through the event API, never invented here.
      add :user_id, :string
      # The other identifiers that came with it — user_domain, user_address —
      # merged across the session so the Users tab can show them without
      # scanning events.
      add :user_traits, :map, null: false, default: %{}
    end

    # Partial: most sessions are anonymous browser visits and have no user, and
    # every query that uses this index asks for one user or for all identified
    # ones.
    create index(:sessions, [:site_id, :user_id, :started_at], where: "user_id IS NOT NULL")
  end
end
