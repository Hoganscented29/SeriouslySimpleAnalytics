defmodule WebAnalytics.Fixtures do
  @moduledoc "Helpers for building sites and beacon payloads in tests."

  alias WebAnalytics.Sites

  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  def site_fixture(attrs \\ %{}) do
    key = "site-#{System.unique_integer([:positive])}"

    {:ok, site} =
      attrs
      |> Enum.into(%{key: key, name: "Test Site", domain: "example.com"})
      |> Sites.create_site()

    site
  end

  @doc "A site owned by `user`, as the dashboard requires."
  def user_site_fixture(user, attrs \\ %{}) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    {:ok, site} =
      attrs
      |> Map.put_new("key", "site-#{System.unique_integer([:positive])}")
      |> Map.put_new("name", "Test Site")
      |> Map.put_new("domain", "example.com")
      |> then(&Sites.create_site_for_user(user, &1))

    site
  end

  @doc "A beacon payload with sensible defaults; `events` replaces the event list."
  def payload(site, events, opts \\ []) do
    %{
      "k" => site.key,
      "s" => Keyword.get(opts, :token, "token-#{System.unique_integer([:positive])}"),
      "v" => Keyword.get(opts, :visitor, "visitor-1"),
      "t" => Keyword.get(opts, :now, 1_000_000),
      "e" => events
    }
  end

  def init_event(overrides \\ %{}) do
    Map.merge(
      %{
        "n" => "init",
        "t" => 1_000_000,
        "ua" => @ua,
        "ref" => "https://news.ycombinator.com/item?id=1",
        "sw" => 2560,
        "sh" => 1440,
        "lang" => "en-US",
        "tz" => "America/New_York"
      },
      overrides
    )
  end

  def pageview_event(seq, path, overrides \\ %{}) do
    Map.merge(
      %{"n" => "pv", "t" => 1_000_000, "seq" => seq, "path" => path, "title" => "Page #{seq}"},
      overrides
    )
  end

  def tick_event(pv_seq, overrides \\ %{}) do
    Map.merge(
      %{
        "n" => "tick",
        "t" => 1_000_000,
        "i" => 1,
        "pv" => pv_seq,
        "a" => 1,
        "sp" => 50,
        "spx" => 800,
        "d" => 1_000,
        "am" => 1_000,
        "pd" => 1_000,
        "pa" => 1_000
      },
      overrides
    )
  end

  def click_event(overrides \\ %{}) do
    Map.merge(
      %{
        "n" => "click",
        "t" => 1_000_000,
        "pv" => 1,
        "k" => "click",
        "tag" => "button",
        "id" => "cta",
        "cls" => ["btn", "btn-primary"],
        "txt" => "Get started",
        "trig" => "click"
      },
      overrides
    )
  end

  def user_agent, do: @ua
end
