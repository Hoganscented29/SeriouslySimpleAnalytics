defmodule Mix.Tasks.Ssa.Login do
  @shortdoc "Prints a fresh sign-in link, or sets a password"

  @moduledoc """
  Gets you into an account from the shell, when email cannot.

      mix ssa.login me@example.com                  # a fresh sign-in link
      mix ssa.login me@example.com --password SECRET  # set a password instead

  Sign-in links are single use and expire, which is correct and also means the
  one sitting in the log has probably been spent. This mints a new one and
  prints it, without needing a working mail provider — the situation every
  deployment is in before its provider is configured.

  Setting a password logs out every existing session, which is the same thing
  the settings page does. A password is worth having as a standing fallback:
  unlike a link, it does not expire the moment it is used.
  """
  use Mix.Task

  # Enough to reach the database. Booting the whole application would load the
  # ~120MB GeoIP database to print one URL.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [password: :string, url: :string])

    Application.ensure_all_started(:ssl)

    case rest do
      [email | _] ->
        Ecto.Migrator.with_repo(WebAnalytics.Repo, fn _repo ->
          case WebAnalytics.Accounts.get_user_by_email(email) do
            nil ->
              Mix.raise("No user with the email #{email}. Register first at /users/register.")

            user ->
              act(user, opts)
          end
        end)

      [] ->
        Mix.shell().info("""
        Usage:
          mix ssa.login EMAIL                     print a fresh sign-in link
          mix ssa.login EMAIL --password SECRET   set a password instead
          mix ssa.login EMAIL --url https://host  override the link's base URL
        """)
    end
  end

  defp act(user, opts) do
    case opts[:password] do
      nil -> print_link(user, opts)
      password -> set_password(user, password)
    end
  end

  defp print_link(user, opts) do
    # Built the same way the application builds it, so the link works against
    # this deployment rather than against whatever the default host is.
    base = opts[:url] || base_url()

    # Deliberately not through the notifier: mail is usually the reason someone
    # is running this, and routing the rescue through the broken part would
    # need a mail provider, a started endpoint, and an HTTP client — none of
    # which this task boots.
    token = WebAnalytics.Accounts.create_login_token(user)

    Mix.shell().info("""

    Sign-in link for #{user.email} — single use, and it expires:

      #{base}/users/log-in/#{token}

    Nothing was emailed. If the link is wrong for this deployment, pass
    --url https://your-host to override it.
    """)
  end

  defp set_password(user, password) do
    case WebAnalytics.Accounts.update_user_password(user, %{password: password}) do
      {:ok, _user} ->
        Mix.shell().info("""

        Password set for #{user.email}. Every existing session was logged out.
        Sign in at /users/log-in with the email and password.
        """)

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
            end)
          end)

        Mix.raise("Could not set the password: #{inspect(errors)}")
    end
  end

  defp base_url do
    config = Application.get_env(:web_analytics, WebAnalyticsWeb.Endpoint, [])
    url = Keyword.get(config, :url, [])

    scheme = Keyword.get(url, :scheme, "http")
    host = Keyword.get(url, :host, "localhost")

    # In prod runtime.exs sets :url fully. In dev it does not, and the port the
    # server actually listens on is the one under :http — without this the task
    # prints a link to port 80 on a box serving 4000.
    port =
      Keyword.get(url, :port) ||
        get_in(config, [:http, :port]) ||
        if(scheme == "https", do: 443, else: 80)

    if (scheme == "https" and port == 443) or (scheme == "http" and port == 80) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end
