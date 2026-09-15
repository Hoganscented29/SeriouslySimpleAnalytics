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
    # Who the session is about, in the caller's own terms — see the ping API's
    # `user` parameter. Nil for every browser visit.
    field :user_id, :string
    field :user_traits, :map, default: %{}

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

    # The hostname the visit happened on, for accounts whose tag is deployed
    # across more than one domain.
    field :host, :string
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

    # What the browser could tell us about the machine, the network and the
    # person's stated preferences. All optional: an old browser reports less,
    # and a missing value is a fact rather than an error.
    field :hardware_concurrency, :integer
    field :device_memory, :float
    field :max_touch_points, :integer
    field :color_depth, :integer
    field :screen_orientation, :string
    field :connection_type, :string
    field :connection_downlink, :float
    field :connection_rtt, :integer
    field :save_data, :boolean
    field :prefers_dark, :boolean
    field :prefers_reduced_motion, :boolean
    field :languages, :string
    field :cookies_enabled, :boolean
    field :ua_platform, :string
    field :ua_platform_version, :string
    field :ua_mobile, :boolean
    field :ua_brands, :string

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
    field :ip_masked, :string

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
