defmodule WebAnalytics.Tracking.Event do
  @moduledoc """
  An auto-captured interaction — mostly clicks. Element identity is split into
  `el_id`, `classes` and `selector` so clicks can be grouped by any of them.
  """
  use Ecto.Schema

  schema "events" do
    belongs_to :site, WebAnalytics.Sites.Site
    belongs_to :session, WebAnalytics.Tracking.Session
    belongs_to :pageview, WebAnalytics.Tracking.Pageview

    field :type, :string
    field :name, :string
    field :occurred_at, :utc_datetime_usec

    field :path, :string
    field :title, :string

    field :tag, :string
    field :el_id, :string
    field :classes, {:array, :string}, default: []
    field :class_raw, :string
    field :el_name, :string
    field :el_role, :string
    field :el_type, :string
    field :text, :string
    field :selector, :string
    field :data_attrs, :map, default: %{}

    field :href, :string
    field :href_host, :string
    field :href_path, :string
    field :outbound, :boolean, default: false
    field :new_tab, :boolean, default: false
    field :trigger, :string

    field :viewport_x, :integer
    field :viewport_y, :integer
    field :page_x, :integer
    field :page_y, :integer
    field :scroll_pct, :integer
    field :ms_since_pageview, :integer

    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
