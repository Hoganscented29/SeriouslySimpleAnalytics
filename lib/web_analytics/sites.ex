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
