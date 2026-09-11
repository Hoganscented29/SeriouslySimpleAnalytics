defmodule WebAnalytics.Tracking.FormCapture do
  @moduledoc """
  A form the visitor touched, recorded on submit and on abandonment.

  `fields` holds per-field metadata and `data` the flat name => value map.
  """
  use Ecto.Schema

  schema "form_captures" do
    belongs_to :site, WebAnalytics.Sites.Site
    belongs_to :session, WebAnalytics.Tracking.Session
    belongs_to :pageview, WebAnalytics.Tracking.Pageview

    field :status, :string
    field :occurred_at, :utc_datetime_usec

    field :path, :string
    field :title, :string

    field :form_id, :string
    field :form_name, :string
    field :form_action, :string
    field :form_method, :string
    field :form_selector, :string
    field :form_classes, {:array, :string}, default: []

    field :field_count, :integer, default: 0
    field :filled_count, :integer, default: 0
    field :time_to_first_input_ms, :integer
    field :duration_ms, :integer

    field :fields, {:array, :map}, default: []
    field :data, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
