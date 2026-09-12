defmodule WebAnalytics.Repo.Migrations.CaptureMoreClientContext do
  use Ecto.Migration

  def change do
    # The browser knows a great deal that the tracker was throwing away. None of
    # it can be recovered later — an unrecorded visit is gone — so the cheap
    # move is to record it now and decide what to report on afterwards.
    alter table(:sessions) do
      # What the machine is, which is what "is this site fast enough for them"
      # actually turns on.
      add :hardware_concurrency, :integer
      add :device_memory, :float
      add :max_touch_points, :integer
      add :color_depth, :integer
      add :screen_orientation, :string

      # What the network is. A page that is fine on fibre and unusable on 3G
      # looks identical in every report that does not have this.
      add :connection_type, :string
      add :connection_downlink, :float
      add :connection_rtt, :integer
      add :save_data, :boolean

      # What the person asked their browser for.
      add :prefers_dark, :boolean
      add :prefers_reduced_motion, :boolean
      add :languages, :string
      add :cookies_enabled, :boolean

      # Client hints, which browsers are moving to as the user agent string is
      # frozen and progressively stripped of detail.
      add :ua_platform, :string
      add :ua_platform_version, :string
      add :ua_mobile, :boolean
      add :ua_brands, :string
    end

    alter table(:pageviews) do
      # Stored rather than parsed out of url on demand, which is the mistake
      # this table already made once.
      add :host, :string
      add :protocol, :string
      add :port, :integer

      # Why the page loaded, and how long each stage of it took.
      add :navigation_type, :string
      add :ttfb_ms, :integer
      add :dom_interactive_ms, :integer
      add :dom_content_loaded_ms, :integer
      add :load_ms, :integer
      add :fcp_ms, :integer
      add :lcp_ms, :integer
      add :transfer_bytes, :integer
    end

    create index(:pageviews, [:site_id, :host])
  end
end
