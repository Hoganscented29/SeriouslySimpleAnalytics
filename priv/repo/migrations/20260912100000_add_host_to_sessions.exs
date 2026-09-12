defmodule WebAnalytics.Repo.Migrations.AddHostToSessions do
  use Ecto.Migration

  def up do
    # One account can carry the same tag across several hostnames — a marketing
    # site and an app, staging and production. Until now the host of the page
    # being viewed was only recoverable by parsing pageviews.url, which is a
    # sequential scan and a string split on every query that wants to group by
    # it. Stored once at ingest, it indexes.
    alter table(:sessions) do
      add :host, :string
    end

    # Backfill from the URL of each session's first pageview, which is the same
    # thing ingest will record from now on.
    execute """
    UPDATE sessions s
    SET host = sub.host
    FROM (
      SELECT DISTINCT ON (p.session_id)
             p.session_id,
             split_part(split_part(regexp_replace(p.url, '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''), '/', 1), ':', 1) AS host
      FROM pageviews p
      WHERE p.url IS NOT NULL
      ORDER BY p.session_id, p.entered_at, p.id
    ) sub
    WHERE sub.session_id = s.id AND sub.host <> ''
    """

    create index(:sessions, [:site_id, :host])
  end

  def down do
    drop index(:sessions, [:site_id, :host])

    alter table(:sessions) do
      remove :host
    end
  end
end
