defmodule WebAnalytics.Tracking.Session do
  @moduledoc """
  One visit. Rolled up continuously from heartbeats rather than rebuilt from
  raw events, so the dashboard can read totals without aggregating.
  """
  use Ecto.Schema

  schema "sessions" do
    belongs_to :site, WebAnalytics.Sites.Site

    field :token, :string
    field :visitor_token, :string
    field :project, :string
    field :channel, :string
    field :agent_name, :string
    field :contact_email, :string

    field :started_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    field :dwell_ms, :integer, default: 0
    field :active_ms, :integer, default: 0
    field :tick_count, :integer, default: 0
    field :active_tick_count, :integer, default: 0
    field :pageview_count, :integer, default: 0
    field :click_count, :integer, default: 0
    field :outbound_count, :integer, default: 0
    field :form_count, :integer, default: 0
    field :max_scroll_pct, :integer, default: 0

    field :entry_path, :string
    field :entry_title, :string
    field :exit_path, :string
    field :exit_title, :string

    field :referrer, :string
    field :referrer_host, :string
    field :utm_source, :string
    field :utm_medium, :string
    field :utm_campaign, :string
    field :utm_term, :string
    field :utm_content, :string

    field :user_agent, :string
    field :browser, :string
    field :browser_version, :string
    field :os, :string
    field :device_type, :string
    field :bot_ua, :boolean, default: false

    field :crawler, :boolean, default: false
    field :crawler_kind, :string
    field :crawler_name, :string
    field :client_signal, :string
    field :heartbeat_ms, :integer

    field :screen_w, :integer
    field :screen_h, :integer
    field :viewport_w, :integer
    field :viewport_h, :integer
    field :device_pixel_ratio, :float
    field :language, :string
    field :timezone, :string
    field :ip_hash, :string

    field :country_code, :string
    field :country, :string
    field :region, :string
    field :region_code, :string
    field :county, :string
    field :city, :string
    field :latitude, :float
    field :longitude, :float
    field :accuracy_km, :integer
    field :geo_source, :string

    field :anomalous, :boolean, default: false
    field :anomaly_score, :float
    field :anomaly_reasons, {:array, :string}, default: []
    field :classified_at, :utc_datetime_usec

    has_many :pageviews, WebAnalytics.Tracking.Pageview
    has_many :events, WebAnalytics.Tracking.Event

    timestamps(type: :utc_datetime_usec)
  end
end
