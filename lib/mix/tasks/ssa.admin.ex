defmodule Mix.Tasks.Ssa.Admin do
  @shortdoc "Grants or revokes admin access for a user"

  @moduledoc """
  Grants the admin flag, which unlocks the cross-account dashboard at /admin.

      mix ssa.admin me@example.com
      mix ssa.admin me@example.com --revoke
      mix ssa.admin --list

  This is a shell command rather than a page in the application on purpose. An
  admin sees every account's data, so granting it should require access to the
  box rather than access to a logged-in session.

  The user must already exist — register first, then run this.
  """
  use Mix.Task

  # Enough to talk to the database, without booting the endpoint or loading the
  # ~120MB GeoIP database for what is a single UPDATE.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args, strict: [revoke: :boolean, list: :boolean])

    Application.ensure_all_started(:ssl)

    Ecto.Migrator.with_repo(WebAnalytics.Repo, fn _repo ->
      cond do
        opts[:list] -> list()
        rest == [] -> usage()
        true -> set(hd(rest), !opts[:revoke])
      end
    end)
  end

  defp set(email, admin?) do
    case WebAnalytics.Accounts.set_admin(email, admin?) do
      {:ok, user} ->
        verb = if admin?, do: "now an admin", else: "no longer an admin"
        Mix.shell().info("#{user.email} is #{verb}.")
        if admin?, do: Mix.shell().info("The dashboard is at /admin.")

      {:error, :not_found} ->
        Mix.raise("""
        No user with the email #{email}.

        Register at /users/register first, then run this again.
        """)

      {:error, changeset} ->
        Mix.raise("Could not update #{email}: #{inspect(changeset.errors)}")
    end
  end

  defp list do
    case WebAnalytics.Accounts.list_admins() do
      [] ->
        Mix.shell().info("No admins yet.  mix ssa.admin you@example.com")

      admins ->
        Mix.shell().info("Admins:")
        Enum.each(admins, &Mix.shell().info("  #{&1.email}"))
    end
  end

  defp usage do
    Mix.shell().info("""
    Usage:
      mix ssa.admin EMAIL           grant admin
      mix ssa.admin EMAIL --revoke  take it away
      mix ssa.admin --list          who has it
    """)
  end
end
