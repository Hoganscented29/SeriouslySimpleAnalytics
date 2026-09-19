defmodule WebAnalyticsWeb.AccountProvisioning do
  @moduledoc """
  Self-service account creation, for agents.

  Shared by `POST /api/v1/accounts` and the MCP server's
  `create_analytics_account` tool. An AI tool can call either, get an account
  id back, and start reporting events in the same run. Requiring a human to
  stop and fill in a signup form first is the thing most likely to end an
  integration before it starts, so there is no form and no key exchange.

  Two shapes, depending on whether a human is reachable:

    * with `email` — the magic link is mailed to that address and never
      returned, so the address still has to be controlled by whoever ends up
      signing in;
    * without `email` — the account is anonymous and the result carries a
      one-time claim link, which is then the only way into it.
  """
  use WebAnalyticsWeb, :verified_routes

  alias WebAnalytics.Accounts
  alias WebAnalytics.RateLimiter
  alias WebAnalytics.Sites

  # Generous enough that a developer retrying by hand never notices, low enough
  # that a script cannot fill the users table.
  @limit 5
  @window_ms 3_600_000

  @doc """
  Creates an account for `params` (`project` or `name`, and optionally `email`
  or `contact`), rate limited per client address.

  Returns `{:ok, body, site}`, or `{:error, reason, body}` where reason is
  `:email_taken`, `:invalid` or `{:rate_limited, retry_after_seconds}`. The
  bodies are what the HTTP endpoint returns, so both callers describe an
  outcome in the same words.
  """
  def create(params, client_ip) do
    case RateLimiter.hit({:account_create, client_ip}, @limit, @window_ms) do
      :ok -> provision(params)
      {:error, retry_after} -> {:error, {:rate_limited, retry_after}, rate_limited(retry_after)}
    end
  end

  defp provision(params) do
    email = normalize_email(params["email"] || params["contact"])

    if email && Accounts.get_user_by_email(email) do
      {:error, :email_taken,
       %{
         error: "email_taken",
         message: "That email already has an account. Sign in to see its account id.",
         login_url: url(~p"/users/log-in")
       }}
    else
      do_provision(email, Sites.generate_key(), params)
    end
  end

  defp do_provision(email, key, params) do
    # A reserved TLD, so an anonymous account can satisfy the unique-email
    # constraint without ever addressing mail at a real person.
    login_email = email || "#{key}@unclaimed.invalid"
    site_attrs = %{"key" => key, "name" => site_name(params)}

    case Accounts.provision_account(%{email: login_email}, site_attrs) do
      {:ok, user, site, token} ->
        {:ok, created(user, site, token, email), site}

      {:error, changeset} ->
        {:error, :invalid,
         %{error: "invalid", message: "Could not create an account.", details: errors(changeset)}}
    end
  end

  defp created(user, site, token, email) do
    body = %{
      uid: site.key,
      account_id: site.key,
      project: site.name,
      dashboard_url: url(~p"/dashboard"),
      docs_url: url(~p"/llms.txt"),
      ping_url: ping_url(site)
    }

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
  end

  defp ping_url(site) do
    url(~p"/api/ping?#{[uid: site.key, type: "ai", project: site.name, event: "page_view"]}")
  end

  defp rate_limited(retry_after) do
    %{
      error: "rate_limited",
      message: "Too many accounts created from this address. Try again later.",
      retry_after: retry_after
    }
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
end
