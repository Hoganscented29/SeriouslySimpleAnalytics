defmodule WebAnalytics.Repo.Migrations.CreatePageviews do
  use Ecto.Migration

  def change do
    create table(:pageviews) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false

      # Position of this pageview within its session, starting at 1.
      add :seq, :integer, null: false

      add :path, :string, null: false
      add :title, :string
      add :url, :text
      add :query, :text
      add :hash, :string

      add :referrer, :text
      add :referrer_host, :string

      add :entered_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec
      add :dwell_ms, :integer, null: false, default: 0
      add :active_ms, :integer, null: false, default: 0
      add :tick_count, :integer, null: false, default: 0
      add :click_count, :integer, null: false, default: 0

      add :max_scroll_pct, :integer, null: false, default: 0
      add :max_scroll_px, :integer, null: false, default: 0
      add :doc_height, :integer
      add :viewport_h, :integer

      # Previous/next hops are denormalised so flow queries stay a single scan.
      # Both path and title are kept so the dashboard can group by either.
      add :from_path, :string
      add :from_title, :string
      add :to_path, :string
      add :to_title, :string
      add :entrance, :boolean, null: false, default: false
      add :exit, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pageviews, [:session_id, :seq])
    create index(:pageviews, [:site_id, :entered_at])
    create index(:pageviews, [:site_id, :path])
    create index(:pageviews, [:site_id, :title])
    create index(:pageviews, [:site_id, :from_path, :path])
    create index(:pageviews, [:site_id, :from_title, :title])
  end
end
