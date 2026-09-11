defmodule WebAnalytics.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false

      # Client-generated tokens. `token` rotates per visit, `visitor_token` persists.
      add :token, :string, null: false
      add :visitor_token, :string

      add :started_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec

      # Dwell is wall-clock time in the session; active time only counts seconds
      # where the tab was visible and the visitor had interacted recently.
      add :dwell_ms, :integer, null: false, default: 0
      add :active_ms, :integer, null: false, default: 0
      add :tick_count, :integer, null: false, default: 0
      add :active_tick_count, :integer, null: false, default: 0
      add :pageview_count, :integer, null: false, default: 0
      add :click_count, :integer, null: false, default: 0
      add :outbound_count, :integer, null: false, default: 0
      add :form_count, :integer, null: false, default: 0
      add :max_scroll_pct, :integer, null: false, default: 0

      add :entry_path, :string
      add :entry_title, :string
      add :exit_path, :string
      add :exit_title, :string

      add :referrer, :text
      add :referrer_host, :string
      add :utm_source, :string
      add :utm_medium, :string
      add :utm_campaign, :string
      add :utm_term, :string
      add :utm_content, :string

      add :user_agent, :text
      add :browser, :string
      add :browser_version, :string
      add :os, :string
      add :device_type, :string
      add :bot_ua, :boolean, null: false, default: false

      add :screen_w, :integer
      add :screen_h, :integer
      add :viewport_w, :integer
      add :viewport_h, :integer
      add :device_pixel_ratio, :float
      add :language, :string
      add :timezone, :string

      # Raw IPs are never stored; this is a rotating salted hash used only to
      # group obvious duplicates during anomaly scoring.
      add :ip_hash, :string

      # Anomaly classification, recomputed in the background.
      add :anomalous, :boolean, null: false, default: false
      add :anomaly_score, :float
      add :anomaly_reasons, {:array, :string}, null: false, default: []
      add :classified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:site_id, :token])
    create index(:sessions, [:site_id, :started_at])
    create index(:sessions, [:site_id, :anomalous, :started_at])
    create index(:sessions, [:site_id, :visitor_token])
    create index(:sessions, [:site_id, :classified_at])
  end
end
