defmodule WebAnalytics.Tracking.Pageview do
  @moduledoc """
  A single page in a session. `from_*` and `to_*` are denormalised hops so that
  path-to-path and title-to-title flow can be read without a self join.
  """
  use Ecto.Schema

  schema "pageviews" do
    belongs_to :site, WebAnalytics.Sites.Site
    belongs_to :session, WebAnalytics.Tracking.Session

    field :seq, :integer

    field :path, :string
    field :title, :string
    field :url, :string
    field :host, :string
    field :protocol, :string
    field :port, :integer

    # Navigation Timing, so "the page was slow" stops being an anecdote.
    field :navigation_type, :string
    field :ttfb_ms, :integer
    field :dom_interactive_ms, :integer
    field :dom_content_loaded_ms, :integer
    field :load_ms, :integer
    field :fcp_ms, :integer
    field :lcp_ms, :integer
    field :transfer_bytes, :integer
    field :query, :string
    field :hash, :string

    field :referrer, :string
    field :referrer_host, :string

    field :entered_at, :utc_datetime_usec
    field :left_at, :utc_datetime_usec
    field :dwell_ms, :integer, default: 0
    field :active_ms, :integer, default: 0
    field :tick_count, :integer, default: 0
    field :click_count, :integer, default: 0

    field :max_scroll_pct, :integer, default: 0
    field :max_scroll_px, :integer, default: 0
    field :doc_height, :integer
    field :viewport_h, :integer

    field :from_path, :string
    field :from_title, :string
    field :to_path, :string
    field :to_title, :string
    field :entrance, :boolean, default: false
    field :exit, :boolean, default: false

    has_many :events, WebAnalytics.Tracking.Event

    timestamps(type: :utc_datetime_usec)
  end
end
