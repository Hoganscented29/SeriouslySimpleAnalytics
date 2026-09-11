defmodule WebAnalytics.Repo.Migrations.AddContactAndAgentToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      # Supplied by the caller on the ping API. Documented as a breach-contact
      # address, which is why it is a column rather than a generic event
      # attribute: you need to be able to query it, and you need to know it is
      # there.
      add :contact_email, :string

      # Which AI tool is reporting. Distinct from `project`, which is which of
      # the account holder's own things this is.
      add :agent_name, :string
    end

    create index(:sessions, [:site_id, :agent_name])
  end
end
