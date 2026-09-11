defmodule Mix.Tasks.Ssa.Account do
  @moduledoc """
  Creates an account, or shows the ones that exist.

      mix ssa.account                     # list accounts
      mix ssa.account "My Site"           # create one, generating the ID
      mix ssa.account "My Site" --key abc # create one with a chosen ID

  The account ID is what goes in `uid=` on the ping API and `data-site=` in the
  browser snippet. It is public by design — it identifies an account and grants
  nothing else — so it is safe to print and to paste into a page.
  """
  @shortdoc "Creates or lists analytics accounts"

  use Mix.Task

  alias WebAnalytics.Sites

  # Only the configuration, not the application. Booting the whole app to insert
  # one row would start the ingest buffer, the classifier and a ~120MB GeoIP
  # load, and would interleave their startup logs with this task's output — which
  # matters because `--quiet` exists so a script can read the account ID from
  # stdout.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [key: :string, quiet: :boolean])

    Logger.configure(level: :warning)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(WebAnalytics.Repo, fn _repo ->
        case argv do
          [] -> list(opts)
          [name | _] -> create(name, opts)
        end
      end)

    :ok
  end

  defp list(opts) do
    case Sites.list_sites() do
      [] ->
        unless opts[:quiet] do
          Mix.shell().info("No accounts yet. Create one:  mix ssa.account \"My Site\"")
        end

      sites ->
        if opts[:quiet] do
          # One ID per line, for a script to read.
          Enum.each(sites, &Mix.shell().info(&1.key))
        else
          Mix.shell().info("Accounts:")
          Enum.each(sites, fn site -> Mix.shell().info("  #{site.key}\t#{site.name}") end)
        end
    end
  end

  defp create(name, opts) do
    key = opts[:key] || generate_key()

    case Sites.create_site(%{key: key, name: name}) do
      {:ok, site} ->
        if opts[:quiet] do
          Mix.shell().info(site.key)
        else
          Mix.shell().info("Created account #{site.key} (#{site.name})")
        end

      {:error, changeset} ->
        Mix.raise("Could not create the account: #{inspect(changeset.errors)}")
    end
  end

  # Short, unambiguous, and safe in a URL — it ends up in query strings and in
  # other people's HTML.
  defp generate_key do
    "acct_" <>
      (:crypto.strong_rand_bytes(9)
       |> Base.url_encode64(padding: false)
       |> String.replace(["-", "_"], "")
       |> binary_part(0, 10)
       |> String.downcase())
  end
end
