defmodule WebAnalytics.IngestTest do
  use WebAnalytics.DataCase, async: true

  import WebAnalytics.Fixtures

  alias WebAnalytics.Ingest
  alias WebAnalytics.Repo
  alias WebAnalytics.Tracking.Event
  alias WebAnalytics.Tracking.FormCapture
  alias WebAnalytics.Tracking.Pageview
  alias WebAnalytics.Tracking.Session

  setup do
    %{site: site_fixture()}
  end

  defp submit(site, events, opts \\ []) do
    {:ok, id} =
      Ingest.submit_sync(site, payload(site, events, opts), received_at: DateTime.utc_now())

    id
  end

  defp pageviews(session_id) do
    Repo.all(from p in Pageview, where: p.session_id == ^session_id, order_by: p.seq)
  end

  test "rolls a visit up onto the session", %{site: site} do
    id =
      submit(site, [
        init_event(),
        pageview_event(1, "/"),
        tick_event(1, %{"d" => 1_000, "am" => 1_000, "sp" => 30}),
        tick_event(1, %{"i" => 2, "d" => 2_000, "am" => 2_000, "sp" => 70}),
        click_event(),
        click_event(%{"k" => "outbound", "out" => 1, "href" => "https://example.org/x"})
      ])

    session = Repo.get!(Session, id)

    assert session.tick_count == 2
    assert session.active_tick_count == 2
    assert session.dwell_ms == 2_000
    assert session.max_scroll_pct == 70
    assert session.click_count == 2
    assert session.outbound_count == 1
    assert session.pageview_count == 1
    assert session.entry_path == "/"
    assert session.browser == "Chrome"
    assert session.referrer_host == "news.ycombinator.com"
  end

  test "keeps the highest scroll depth even when a later beacon reports less", %{site: site} do
    token = "scroll-token"

    submit(site, [pageview_event(1, "/"), tick_event(1, %{"sp" => 90, "spx" => 2_000})],
      token: token
    )

    id = submit(site, [tick_event(1, %{"i" => 2, "sp" => 10, "spx" => 100})], token: token)

    assert %{max_scroll_pct: 90} = Repo.get!(Session, id)
    assert [%{max_scroll_pct: 90, max_scroll_px: 2_000}] = pageviews(id)
  end

  test "links pageviews into a flow by both path and title", %{site: site} do
    id =
      submit(site, [
        pageview_event(1, "/", %{"title" => "Home"}),
        pageview_event(2, "/pricing", %{"title" => "Pricing", "fp" => "/", "ft" => "Home"}),
        pageview_event(3, "/thanks", %{
          "title" => "Thanks",
          "fp" => "/pricing",
          "ft" => "Pricing"
        })
      ])

    assert [first, second, third] = pageviews(id)

    assert first.from_path == nil
    assert first.to_path == "/pricing"
    assert first.to_title == "Pricing"
    assert first.entrance
    refute first.exit

    assert second.from_path == "/"
    assert second.from_title == "Home"
    assert second.to_path == "/thanks"
    assert second.to_title == "Thanks"

    assert third.from_title == "Pricing"
    assert third.to_path == nil
    assert third.exit
  end

  test "links a flow that arrives across separate beacons", %{site: site} do
    token = "split-token"

    submit(site, [pageview_event(1, "/", %{"title" => "Home"})], token: token)

    id =
      submit(
        site,
        [pageview_event(2, "/next", %{"title" => "Next", "fp" => "/", "ft" => "Home"})],
        token: token
      )

    assert [first, second] = pageviews(id)
    assert first.to_path == "/next"
    refute first.exit
    assert second.from_path == "/"
  end

  test "does not duplicate a session or pageview when a beacon is replayed", %{site: site} do
    events = [init_event(), pageview_event(1, "/"), tick_event(1)]
    token = "replay-token"

    id = submit(site, events, token: token)
    ^id = submit(site, events, token: token)

    assert Repo.aggregate(from(s in Session, where: s.id == ^id), :count) == 1
    assert length(pageviews(id)) == 1
  end

  test "attaches clicks to the pageview they happened on", %{site: site} do
    id =
      submit(site, [
        pageview_event(1, "/"),
        pageview_event(2, "/pricing", %{"fp" => "/"}),
        click_event(%{"pv" => 2, "id" => "buy"})
      ])

    event = Repo.one(from e in Event, where: e.session_id == ^id)

    assert event.path == "/pricing"
    assert event.el_id == "buy"
    assert event.classes == ["btn", "btn-primary"]
  end

  test "resolves a click against a pageview opened in an earlier beacon", %{site: site} do
    token = "late-click"
    submit(site, [pageview_event(1, "/docs")], token: token)
    id = submit(site, [click_event(%{"pv" => 1, "id" => "late"})], token: token)

    event = Repo.one(from e in Event, where: e.session_id == ^id)
    assert event.path == "/docs"
    assert event.el_id == "late"
  end

  test "stores form captures with their field detail", %{site: site} do
    id =
      submit(site, [
        pageview_event(1, "/signup"),
        %{
          "n" => "form",
          "t" => 1_000_000,
          "pv" => 1,
          "st" => "abandoned",
          "fid" => "signup",
          "act" => "/subscribe",
          "mth" => "POST",
          "tfi" => 1_200,
          "dur" => 8_000,
          "flds" => [
            %{
              "name" => "email",
              "type" => "email",
              "value" => "a@b.com",
              "filled" => 1,
              "changes" => 3
            },
            %{"name" => "note", "type" => "textarea", "value" => nil, "filled" => 0}
          ]
        }
      ])

    capture = Repo.one(from c in FormCapture, where: c.session_id == ^id)

    assert capture.status == "abandoned"
    assert capture.path == "/signup"
    assert capture.form_method == "post"
    assert capture.field_count == 2
    assert capture.filled_count == 1
    assert capture.data == %{"email" => "a@b.com"}
    assert Repo.get!(Session, id).form_count == 1
  end

  test "closes out the session on the end beacon", %{site: site} do
    id =
      submit(site, [
        pageview_event(1, "/"),
        %{"n" => "end", "t" => 1_000_000, "pv" => 1, "d" => 9_000, "am" => 6_000, "sp" => 95}
      ])

    session = Repo.get!(Session, id)
    assert session.dwell_ms == 9_000
    assert session.active_ms == 6_000
    assert session.max_scroll_pct == 95
    assert session.ended_at
  end

  test "creates a session from a beacon that carries no init", %{site: site} do
    id = submit(site, [pageview_event(1, "/late"), tick_event(1)])

    session = Repo.get!(Session, id)
    assert session.entry_path == "/late"
    refute session.bot_ua
    assert session.browser == nil
  end

  test "clears the anomaly verdict whenever the session moves", %{site: site} do
    token = "reclassify"
    id = submit(site, [pageview_event(1, "/")], token: token)

    Repo.update_all(from(s in Session, where: s.id == ^id),
      set: [classified_at: DateTime.utc_now(), anomalous: true]
    )

    submit(site, [tick_event(1)], token: token)

    assert %{classified_at: nil} = Repo.get!(Session, id)
  end

  test "rejects a beacon with no session token", %{site: site} do
    assert Ingest.submit_sync(site, %{"s" => nil, "e" => []}) ==
             {:error, :missing_session_token}
  end

  test "hashes IPs into an unrecoverable, per-day value", %{site: site} do
    hash = Ingest.hash_ip("203.0.113.9", site)

    assert byte_size(hash) == 32
    refute hash =~ "203"
    assert hash == Ingest.hash_ip("203.0.113.9", site)
    refute hash == Ingest.hash_ip("203.0.113.10", site)
    assert Ingest.hash_ip(nil, site) == nil
  end
end
