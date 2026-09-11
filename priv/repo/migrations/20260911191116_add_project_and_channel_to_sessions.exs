defmodule WebAnalytics.Repo.Migrations.AddProjectAndChannelToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      # One account can instrument many things. `project` separates them —
      # an AI tool, a CLI, a website — without needing a site per thing.
      add :project, :string
      # Where the telemetry came from: "web" for the browser tracker, "ai" for
      # an AI tool reporting its own usage, or whatever the caller says.
      add :channel, :string
    end

    create index(:sessions, [:site_id, :project, :started_at])
    create index(:sessions, [:site_id, :channel, :started_at])
  end
end
