defmodule WebAnalytics.ApiKeys.ApiKey do
  @moduledoc "A secret that lets a program read one account's reports."
  use Ecto.Schema

  schema "api_keys" do
    belongs_to :site, WebAnalytics.Sites.Site

    field :name, :string
    field :prefix, :string
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
