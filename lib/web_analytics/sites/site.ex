defmodule WebAnalytics.Sites.Site do
  @moduledoc """
  A tracked property. The `key` is public — it ships inside the JS snippet — so
  it identifies a site but grants nothing beyond the right to send events to it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "sites" do
    field :key, :string
    field :name, :string
    field :domain, :string
    field :settings, :map, default: %{}

    has_many :sessions, WebAnalytics.Tracking.Session

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(site, attrs) do
    site
    |> cast(attrs, [:key, :name, :domain, :settings])
    |> validate_required([:key, :name])
    |> unique_constraint(:key)
  end
end
