defmodule WebAnalytics.Sites do
  @moduledoc """
  Tracked properties and the settings handed to their JS snippet.
  """

  import Ecto.Query, warn: false

  alias WebAnalytics.Repo
  alias WebAnalytics.Sites.Cache
  alias WebAnalytics.Sites.Site

  @default_settings %{
    "heartbeat_seconds" => 1,
    "crawler_heartbeat_seconds" => 10,
    "heartbeat_fast_ticks" => 400,
    "heartbeat_slow_seconds" => 15,
    "capture_clicks" => true,
    "capture_forms" => true,
    "capture_password_fields" => false,
    "capture_scroll" => true,
    "idle_timeout_seconds" => 30,
    "session_timeout_minutes" => 30
  }

  @doc "Default tracker settings merged under every site's own overrides."
  def default_settings, do: @default_settings

  def list_sites do
    Repo.all(from s in Site, order_by: [asc: s.name])
  end

  @doc "Sites belonging to one user."
  def list_sites_for_user(%{id: user_id}) do
    Repo.all(from s in Site, where: s.user_id == ^user_id, order_by: [asc: s.name])
  end

  @doc """
  Returns the user's sites, creating a first one if they have none.

  Called wherever a signed-in user needs an account ID, so that every route into
  the product — the dashboard, the API, a magic link — produces a usable ID
  rather than an empty page telling them to make one.
  """
  def ensure_site_for_user!(user, attrs \\ %{}) do
    case list_sites_for_user(user) do
      [] ->
        {:ok, site} = create_site_for_user(user, attrs)
        [site]

      sites ->
        sites
    end
  end

  @doc "Creates a site owned by a user, generating the account ID."
  def create_site_for_user(user, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("key", generate_key())
      |> Map.put_new("name", default_site_name(user))

    %Site{user_id: user.id}
    |> Site.changeset(attrs)
    |> Repo.insert()
    |> tap_invalidate()
  end

  @doc """
  Marks a site as claimed by the person it was created for.

  An account made through the API belongs to an email address that has not
  proved it wants it yet; claiming is what turns that into an account someone
  actually owns.
  """
  def claim_site(%Site{} = site) do
    site
    |> Site.changeset(%{"claimed_at" => DateTime.utc_now()})
    |> Repo.update()
    |> tap_invalidate()
  end

  @doc "Whether a site was created on someone's behalf and not yet claimed."
  def unclaimed?(%Site{claimed_at: nil, user_id: user_id}), do: not is_nil(user_id)
  def unclaimed?(_site), do: false

  @doc """
  A short, URL-safe account ID.

  It travels in query strings and in other people's HTML, so it avoids anything
  that needs escaping and anything easily misread aloud.
  """
  def generate_key, do: "acct_" <> random_body(10)

  # `-` and `_` are dropped because a key gets read aloud and pasted into places
  # that treat them as word boundaries. Dropping them shortens the string by an
  # unpredictable amount, so draw far more than is needed and redraw on the rare
  # occasion that too little survives — truncating blindly can crash.
  defp random_body(length) do
    candidate =
      :crypto.strong_rand_bytes(length * 2)
      |> Base.url_encode64(padding: false)
      |> String.replace(["-", "_"], "")
      |> String.downcase()

    if byte_size(candidate) >= length do
      binary_part(candidate, 0, length)
    else
      random_body(length)
    end
  end

  defp default_site_name(%{email: email}) when is_binary(email) do
    email |> String.split("@") |> List.first() |> Kernel.<>("'s site")
  end

  defp default_site_name(_user), do: "My site"

  def get_site!(id), do: Repo.get!(Site, id)

  def get_site_by_key(key) when is_binary(key), do: Repo.get_by(Site, key: key)
  def get_site_by_key(_), do: nil

  @doc """
  Key lookup on the ingest hot path, memoised in ETS.

  Every beacon carries a site key, so this runs once per request; hitting
  Postgres for it would dominate the write path.
  """
  def fetch_site_by_key(key) when is_binary(key) do
    case Cache.get(key) do
      {:ok, site} ->
        site

      :miss ->
        case get_site_by_key(key) do
          nil -> nil
          site -> Cache.put(key, site)
        end
    end
  end

  def fetch_site_by_key(_), do: nil

  def create_site(attrs) do
    %Site{}
    |> Site.changeset(attrs)
    |> Repo.insert()
    |> tap_invalidate()
  end

  def update_site(%Site{} = site, attrs) do
    site
    |> Site.changeset(attrs)
    |> Repo.update()
    |> tap_invalidate()
  end

  def delete_site(%Site{} = site) do
    site |> Repo.delete() |> tap_invalidate()
  end

  @doc "Site settings with defaults filled in, ready to serialise into the snippet."
  def settings_for(%Site{settings: settings}) do
    Map.merge(@default_settings, settings || %{})
  end

  defp tap_invalidate({:ok, %Site{} = site} = result) do
    Cache.delete(site.key)
    result
  end

  defp tap_invalidate(result), do: result
end
