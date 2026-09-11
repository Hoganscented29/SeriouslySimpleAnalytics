defmodule WebAnalyticsWeb.AccountController do
  @moduledoc """
  Self-service account creation, for agents.

      POST /api/v1/accounts

  An AI tool that reads `llms.txt` can call this, get an account id back, and
  start reporting events in the same run. Requiring a human to stop and fill in
  a signup form first is the thing most likely to end an integration before it
  starts, so there is no form, no key exchange and no auth header here.

  Two shapes, depending on whether a human is reachable:

    * with `email` — the magic link is mailed to that address and never returned
      in the response, so the address still has to be controlled by whoever ends
      up signing in;
    * without `email` — the account is anonymous and the response carries a
      one-time claim link, which is then the only way into it.
  """
  use WebAnalyticsWeb, :controller

  require Logger

  alias WebAnalytics.Accounts
  alias WebAnalytics.RateLimiter
  alias WebAnalytics.Sites

  # Generous enough that a developer retrying by hand never notices, low enough
  # that a script cannot fill the users table.
  @limit 5
  @window_ms 3_600_000

  def create(conn, params) do
    case RateLimiter.hit({:account_create, client_ip(conn)}, @limit, @window_ms) do
      :ok -> provision(conn, params)
      {:error, retry_after} -> rate_limited(conn, retry_after)
    end
  end

  def options(conn, _params), do: send_resp(conn, 204, "")

  defp provision(conn, params) do
    email = normalize_email(params["email"] || params["contact"])
    key = Sites.generate_key()

    cond do
      email && Accounts.get_user_by_email(email) ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "email_taken",
          message: "That email already has an account. Sign in to see its account id.",
          login_url: url(~p"/users/log-in")
        })

      true ->
        do_provision(conn, email, key, params)
    end
  end

  defp do_provision(conn, email, key, params) do
    # A reserved TLD, so an anonymous account can satisfy the unique-email
    # constraint without ever addressing mail at a real person.
    login_email = email || "#{key}@unclaimed.invalid"
    site_attrs = %{"key" => key, "name" => site_name(params)}

    case Accounts.provision_account(%{email: login_email}, site_attrs) do
      {:ok, user, site, token} ->
        respond_created(conn, user, site, token, email)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid",
          message: "Could not create an account.",
          details: errors(changeset)
        })
    end
  end

  defp respond_created(conn, user, site, token, email) do
    body = %{
      uid: site.key,
      account_id: site.key,
      project: site.name,
      dashboard_url: url(~p"/dashboard"),
      docs_url: url(~p"/llms.txt"),
      ping_url: ping_url(site)
    }

    body =
      if email do
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

        Map.merge(body, %{
          claim: "emailed",
          message: "Account created. A sign-in link was emailed to #{email}."
        })
      else
        Map.merge(body, %{
          claim: "link",
          claim_url: url(~p"/users/log-in/#{token}"),
          message:
            "Account created. Give claim_url to a human to open the dashboard — " <>
              "it is the only way in, so store it or set an email in settings."
        })
      end

    conn
    |> put_status(:created)
    |> json(body)
  end

  defp ping_url(site) do
    url(~p"/api/ping?#{[uid: site.key, type: "ai", project: site.name, event: "page_view"]}")
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{
      error: "rate_limited",
      message: "Too many accounts created from this address. Try again later.",
      retry_after: retry_after
    })
  end

  defp site_name(params) do
    case params["project"] || params["name"] do
      value when is_binary(value) ->
        case value |> String.trim() |> String.slice(0, 80) do
          "" -> "My project"
          trimmed -> trimmed
        end

      _ ->
        "My project"
    end
  end

  defp normalize_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      email -> email
    end
  end

  defp normalize_email(_), do: nil

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
