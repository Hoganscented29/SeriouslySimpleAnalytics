defmodule WebAnalytics.Ingest.NormalizerTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.Ingest.Normalizer

  @site %{id: 1, key: "test"}
  @received ~U[2026-01-01 12:00:00.000000Z]

  defp normalize(payload, settings \\ %{}) do
    Normalizer.normalize(@site, payload, received_at: @received, settings: settings)
  end

  defp payload(events, extra \\ %{}) do
    Map.merge(%{"k" => "test", "s" => "tok", "t" => 1_000, "e" => events}, extra)
  end

  test "rejects a payload with no session token" do
    assert {:error, :missing_session_token} = normalize(payload([], %{"s" => nil}))
    assert {:error, :missing_session_token} = normalize(payload([], %{"s" => "  "}))
    assert {:error, :invalid_payload} = Normalizer.normalize(@site, "not a map", [])
  end

  test "drops malformed events instead of failing the batch" do
    {:ok, batch} =
      normalize(
        payload([
          %{"n" => "pv", "t" => 1_000, "seq" => 1, "path" => "/ok"},
          %{"n" => "pv", "t" => 1_000, "seq" => 1},
          %{"n" => "unknown-kind", "t" => 1_000},
          "not even a map"
        ])
      )

    assert [%{kind: :pageview, path: "/ok"}] = batch.events
  end

  test "a pageview with no seq asks the server to sequence it" do
    {:ok, batch} =
      normalize(payload([%{"n" => "pv", "t" => 1_000, "path" => "/auto"}]))

    # Anything that is not a browser has no way to know it is on its own fourth
    # page, so omitting seq is a request, not a mistake.
    assert [%{kind: :pageview, path: "/auto", seq: :auto}] = batch.events
  end

  test "truncates strings to their column width" do
    long = String.duplicate("a", 900)

    {:ok, batch} =
      normalize(payload([%{"n" => "pv", "t" => 1_000, "seq" => 1, "path" => long}]))

    assert [%{path: path}] = batch.events
    assert String.length(path) == 255
  end

  test "clamps out-of-range numbers" do
    {:ok, batch} =
      normalize(
        payload([
          %{"n" => "tick", "t" => 1_000, "pv" => 1, "sp" => 5_000, "d" => -50, "a" => 1}
        ])
      )

    assert [%{scroll_pct: 100, session_dwell_ms: 0, active: true}] = batch.events
  end

  test "anchors event times to server receive time using the client delta" do
    {:ok, batch} =
      normalize(
        payload([%{"n" => "pv", "t" => 4_000, "seq" => 1, "path" => "/"}], %{"t" => 5_000})
      )

    # Event was 1s before the client's send time, so it lands 1s before receipt.
    assert [%{at: at}] = batch.events
    assert DateTime.compare(at, DateTime.add(@received, -1_000, :millisecond)) == :eq
  end

  test "ignores absurd client clock skew rather than trusting it" do
    {:ok, batch} =
      normalize(
        payload([%{"n" => "pv", "t" => -999_999_999, "seq" => 1, "path" => "/"}], %{"t" => 0})
      )

    assert [%{at: at}] = batch.events
    assert DateTime.diff(@received, at, :millisecond) == 300_000
  end

  test "masks password fields by default and keeps them out of the flat data map" do
    {:ok, batch} = normalize(payload([form_event()]))

    assert [%{kind: :form, fields: fields, data: data}] = batch.events
    password = Enum.find(fields, &(&1["type"] == "password"))

    assert password["masked"]
    assert password["value"] == nil
    refute Map.has_key?(data, "password")
    assert data["email"] == "a@example.com"
  end

  test "keeps password values only when the site opts in" do
    {:ok, batch} = normalize(payload([form_event()]), %{"capture_password_fields" => true})

    assert [%{fields: fields, data: data}] = batch.events
    password = Enum.find(fields, &(&1["type"] == "password"))

    refute password["masked"]
    assert password["value"] == "secret"
    assert data["password"] == "secret"
  end

  test "honours a client-side mask even when capture is enabled" do
    event =
      form_event(%{
        "flds" => [%{"name" => "ssn", "type" => "text", "masked" => 1, "value" => "x"}]
      })

    {:ok, batch} = normalize(payload([event]), %{"capture_password_fields" => true})

    assert [%{fields: [field], data: data}] = batch.events
    assert field["masked"]
    assert field["value"] == nil
    assert data == %{}
  end

  test "parses the user agent and derives the referrer host" do
    {:ok, batch} =
      normalize(
        payload([
          %{
            "n" => "init",
            "t" => 1_000,
            "ua" => WebAnalytics.Fixtures.user_agent(),
            "ref" => "https://News.YCombinator.com/item?id=1"
          }
        ])
      )

    assert [init] = batch.events
    assert init.browser == "Chrome"
    assert init.os == "macOS"
    assert init.device_type == "desktop"
    refute init.bot_ua
    assert init.referrer_host == "news.ycombinator.com"
  end

  test "flags bot user agents" do
    {:ok, batch} =
      normalize(
        payload([
          %{"n" => "init", "t" => 1_000, "ua" => "Mozilla/5.0 (compatible; Googlebot/2.1)"}
        ])
      )

    assert [%{bot_ua: true}] = batch.events
  end

  test "normalises click element identity" do
    {:ok, batch} =
      normalize(
        payload([
          %{
            "n" => "click",
            "t" => 1_000,
            "pv" => 1,
            "k" => "outbound",
            "tag" => "A",
            "id" => "gh",
            "cls" => ["btn", "btn", "", nil, "link"],
            "href" => "https://github.com/x",
            "out" => 1,
            "data" => %{"testid" => "gh"}
          }
        ])
      )

    assert [click] = batch.events
    assert click.type == "outbound"
    assert click.tag == "a"
    assert click.classes == ["btn", "link"]
    assert click.outbound
    assert click.href_host == "github.com"
    assert click.data_attrs == %{"testid" => "gh"}
  end

  test "falls back to a safe type for unknown click kinds" do
    {:ok, batch} =
      normalize(payload([%{"n" => "click", "t" => 1_000, "pv" => 1, "k" => "../../etc"}]))

    assert [%{type: "click"}] = batch.events
  end

  test "caps the number of events in a batch" do
    events = for seq <- 1..500, do: %{"n" => "pv", "t" => 1_000, "seq" => seq, "path" => "/p"}
    {:ok, batch} = normalize(payload(events))
    assert length(batch.events) == 300
  end

  defp form_event(overrides \\ %{}) do
    Map.merge(
      %{
        "n" => "form",
        "t" => 1_000,
        "pv" => 1,
        "st" => "submitted",
        "fid" => "signup",
        "flds" => [
          %{"name" => "email", "type" => "email", "value" => "a@example.com", "filled" => 1},
          %{"name" => "password", "type" => "password", "value" => "secret", "filled" => 1}
        ]
      },
      overrides
    )
  end
end
