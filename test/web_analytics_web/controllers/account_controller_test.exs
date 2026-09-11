defmodule WebAnalyticsWeb.AccountControllerTest do
  use WebAnalyticsWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias WebAnalytics.Accounts
  alias WebAnalytics.RateLimiter
  alias WebAnalytics.Sites

  setup do
    RateLimiter.reset()
    :ok
  end

  describe "POST /api/v1/accounts" do
    test "an agent can provision an account and start reporting in one run", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v1/accounts", %{"project" => "my-agent"})
        |> json_response(201)

      assert body["uid"] =~ ~r/^acct_/
      assert body["account_id"] == body["uid"]
      assert body["project"] == "my-agent"
      assert body["ping_url"] =~ "uid=#{body["uid"]}"
      assert body["docs_url"] =~ "/llms.txt"

      # The id it was handed has to work immediately, or the flow is a lie.
      assert Sites.fetch_site_by_key(body["uid"])
    end

    test "without an email the claim link is the response, and it is the only copy", %{conn: conn} do
      body = conn |> post(~p"/api/v1/accounts", %{}) |> json_response(201)

      assert body["claim"] == "link"
      assert body["claim_url"] =~ "/users/log-in/"
      refute_email_sent()
    end

    test "with an email the claim link is mailed, never returned", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v1/accounts", %{"email" => "dev@example.com"})
        |> json_response(201)

      assert body["claim"] == "emailed"
      refute Map.has_key?(body, "claim_url")
      assert_email_sent(to: [{"", "dev@example.com"}])
    end

    test "the mailed link signs the account in", %{conn: conn} do
      conn |> post(~p"/api/v1/accounts", %{"email" => "dev@example.com"}) |> json_response(201)

      assert_email_sent(fn email ->
        [_, token] = Regex.run(~r"/users/log-in/([^\s\"]+)", email.text_body)
        assert {:ok, {user, _}} = Accounts.login_user_by_magic_link(token)
        assert user.email == "dev@example.com"
      end)
    end

    test "an address that already has an account is not handed a second one", %{conn: conn} do
      conn |> post(~p"/api/v1/accounts", %{"email" => "taken@example.com"}) |> json_response(201)

      body =
        conn
        |> post(~p"/api/v1/accounts", %{"email" => "taken@example.com"})
        |> json_response(409)

      assert body["error"] == "email_taken"
      assert body["login_url"] =~ "/users/log-in"
    end

    test "a script cannot fill the users table", %{conn: conn} do
      for _ <- 1..5, do: assert(conn |> post(~p"/api/v1/accounts", %{}) |> json_response(201))

      conn = post(conn, ~p"/api/v1/accounts", %{})
      body = json_response(conn, 429)

      assert body["error"] == "rate_limited"
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "the account is usable by the ping endpoint straight away", %{conn: conn} do
      body = conn |> post(~p"/api/v1/accounts", %{"project" => "my-agent"}) |> json_response(201)

      conn = get(build_conn(), ~p"/api/ping?uid=#{body["uid"]}&type=ai&event=run_started")
      assert response(conn, 204)
    end

    test "is reachable cross-origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://agent.example")
        |> post(~p"/api/v1/accounts", %{})

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://agent.example"]
    end

    test "a rejected account leaves nothing behind", %{conn: conn} do
      before = length(Sites.list_sites())

      body =
        conn
        |> post(~p"/api/v1/accounts", %{"email" => "not an email"})
        |> json_response(422)

      assert body["error"] == "invalid"
      assert length(Sites.list_sites()) == before
    end
  end
end
