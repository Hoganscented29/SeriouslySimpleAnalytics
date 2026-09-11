defmodule WebAnalyticsWeb.TrackerControllerTest do
  use WebAnalyticsWeb.ConnCase, async: true

  test "serves the tracker script", %{conn: conn} do
    conn = get(conn, ~p"/wa.js")
    body = response(conn, 200)

    assert response_content_type(conn, :js) =~ "javascript"
    assert body =~ "webAnalytics"
    assert body =~ "sendBeacon"
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "max-age"
  end

  test "revalidates with an etag instead of resending the file", %{conn: conn} do
    conn = get(conn, ~p"/wa.js")
    assert [etag] = get_resp_header(conn, "etag")

    cached =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/wa.js")

    assert response(cached, 304) == ""
  end

  test "is reachable cross-origin", %{conn: conn} do
    conn = conn |> put_req_header("origin", "https://tracked-site.example") |> get(~p"/wa.js")

    assert get_resp_header(conn, "access-control-allow-origin") == [
             "https://tracked-site.example"
           ]
  end
end
