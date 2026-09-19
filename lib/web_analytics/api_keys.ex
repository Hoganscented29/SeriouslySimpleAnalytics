defmodule WebAnalytics.ApiKeys do
  @moduledoc """
  Read access to an account's reports, for programs.

  The account ID is public — it sits in the page source of every tracked site —
  so it can only ever be allowed to write. Reading a report back needs a
  secret, and this is it: an MCP client sends one as a bearer token.

  Keys are random, shown once, and stored only as a SHA-256 hash. A hash rather
  than bcrypt because the key is 256 random bits, not a password: nothing about
  it can be guessed, so a slow hash would only slow down every request that
  presents one.
  """
  import Ecto.Query

  alias WebAnalytics.ApiKeys.ApiKey
  alias WebAnalytics.Repo
  alias WebAnalytics.Sites.Site

  @prefix "ssa_"
  @max_active 20
  # Writing last_used_at on every request would turn each read into a write.
  # Once a minute is plenty to answer "is this key still in use?".
  @touch_after_seconds 60

  @doc "The literal every key starts with, so a leaked one is recognisable."
  def prefix, do: @prefix

  @doc """
  Mints a key for `site`. Returns `{:ok, token, api_key}` — the token is the
  only copy there will ever be.
  """
  def create(%Site{} = site, name \\ nil) do
    if count_active(site) >= @max_active do
      {:error, :too_many}
    else
      token = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      %ApiKey{}
      |> Ecto.Changeset.change(%{
        site_id: site.id,
        name: name |> to_string() |> String.trim() |> String.slice(0, 80) |> default_name(),
        prefix: String.slice(token, 0, 12),
        token_hash: hash(token)
      })
      |> Repo.insert()
      |> case do
        {:ok, key} -> {:ok, token, key}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp default_name(""), do: "API key"
  defp default_name(name), do: name

  @doc """
  The site a presented token unlocks, or `:error` for anything that is not a
  live key — unknown, revoked or malformed alike, so a caller cannot tell which.
  """
  def authenticate(@prefix <> _ = token) do
    query =
      from k in ApiKey,
        join: s in assoc(k, :site),
        where: k.token_hash == ^hash(token) and is_nil(k.revoked_at),
        select: {k, s}

    case Repo.one(query) do
      nil ->
        :error

      {key, site} ->
        touch(key)
        {:ok, site}
    end
  end

  def authenticate(_token), do: :error

  @doc "Keys for a site, newest first, revoked ones included."
  def list(%Site{id: site_id}) do
    Repo.all(from k in ApiKey, where: k.site_id == ^site_id, order_by: [desc: k.id])
  end

  @doc "Revokes one of `site`'s keys. A key belonging to another site is not found."
  def revoke(%Site{id: site_id}, id) do
    case Repo.get_by(ApiKey, id: id, site_id: site_id) do
      nil ->
        {:error, :not_found}

      %ApiKey{revoked_at: nil} = key ->
        key |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update()

      key ->
        {:ok, key}
    end
  end

  defp count_active(%Site{id: site_id}) do
    Repo.aggregate(
      from(k in ApiKey, where: k.site_id == ^site_id and is_nil(k.revoked_at)),
      :count
    )
  end

  defp touch(%ApiKey{last_used_at: last} = key) do
    now = DateTime.utc_now()

    if is_nil(last) or DateTime.diff(now, last) >= @touch_after_seconds do
      Repo.update_all(from(k in ApiKey, where: k.id == ^key.id), set: [last_used_at: now])
    end

    :ok
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
