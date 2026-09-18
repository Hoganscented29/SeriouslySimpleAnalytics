defmodule WebAnalyticsWeb.AccountController do
  @moduledoc """
  Self-service account creation, for agents.

      POST /api/v1/accounts

  The rules live in `WebAnalyticsWeb.AccountProvisioning`, shared with the MCP
  server; this is the HTTP shape around them.
  """
  use WebAnalyticsWeb, :controller

  alias WebAnalyticsWeb.AccountProvisioning
  alias WebAnalyticsWeb.ClientIP

  def create(conn, params) do
    case AccountProvisioning.create(params, ClientIP.get(conn)) do
      {:ok, body, _site} ->
        conn |> put_status(:created) |> json(body)

      {:error, :email_taken, body} ->
        conn |> put_status(:conflict) |> json(body)

      {:error, :invalid, body} ->
        conn |> put_status(:unprocessable_entity) |> json(body)

      {:error, {:rate_limited, retry_after}, body} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(body)
    end
  end

  def options(conn, _params), do: send_resp(conn, 204, "")
end
