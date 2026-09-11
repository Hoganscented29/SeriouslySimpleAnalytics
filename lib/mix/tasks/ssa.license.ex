defmodule Mix.Tasks.Ssa.License do
  @moduledoc """
  Generates, issues and checks deployment keys.

      mix ssa.license keygen                    # create your licensor keypair, once
      mix ssa.license issue "Acme Ltd"          # mint a key for a customer
      mix ssa.license issue "Trial" --days 30   # ...that expires
      mix ssa.license check                     # verify the key in your environment
      mix ssa.license check SSA1.…              # verify a specific key

  ## Running keygen

  Do this once. It writes the public key into `config/license.exs`, which is
  committed, and the private key to `priv/licensor_private_key`, which is not.

  **Back the private key up somewhere you will still have it in five years.**
  Losing it means you can never issue another key that existing builds accept,
  and every deployment you have already sold keeps working while every future
  one has to be shipped a rebuilt version with a new public key. There is no
  recovery path; the public key is the only thing that validates signatures and
  it cannot be reversed.
  """
  @shortdoc "Generates, issues and checks deployment keys"

  use Mix.Task

  alias WebAnalytics.License

  @private_key_path "priv/licensor_private_key"
  @config_path "config/license.exs"

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [days: :integer, id: :string])

    case argv do
      ["keygen" | _] -> keygen()
      ["issue", name | _] -> issue(name, opts)
      ["issue"] -> Mix.raise(~s(Who is it for?  mix ssa.license issue "Acme Ltd"))
      ["check"] -> check(License.key_from_env())
      ["check", key | _] -> check(key)
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  defp keygen do
    if File.exists?(@private_key_path) do
      Mix.raise("""
      #{@private_key_path} already exists.

      Generating a new keypair would invalidate every key you have already
      issued. If you really mean to, move the existing file aside first.
      """)
    end

    {public, private} = License.generate_keypair()

    File.mkdir_p!(Path.dirname(@private_key_path))
    File.write!(@private_key_path, private <> "\n")
    File.chmod!(@private_key_path, 0o600)

    File.write!(@config_path, """
    import Config

    # Licensor public key. Written by `mix ssa.license keygen`.
    #
    # This is the public half and is meant to be committed — it only verifies
    # signatures, it cannot create them. The private half is in
    # #{@private_key_path}, is gitignored, and must never be published: anyone
    # holding it can mint keys this build will accept.
    config :web_analytics, :license, public_key: "#{public}"
    """)

    Mix.shell().info("""

    Keypair generated.

      public   #{@config_path}            (commit this)
      private  #{@private_key_path}  (never commit this; back it up)

    Back the private key up now, somewhere you will still have in five years.
    If you lose it you can never issue another key that today's builds accept.

    Issue yourself a key to run your own deployment:

      mix ssa.license issue "#{System.get_env("USER") || "me"}"
    """)
  end

  defp issue(name, opts) do
    private =
      case File.read(@private_key_path) do
        {:ok, contents} ->
          String.trim(contents)

        {:error, _} ->
          Mix.raise("""
          No private key at #{@private_key_path}.

          Run `mix ssa.license keygen` first, or restore it from your backup.
          """)
      end

    {:ok, private_bytes} = Base.decode64(private)

    claims =
      %{
        "sub" => name,
        "iat" => System.system_time(:second),
        "jti" => opts[:id] || short_id()
      }
      |> maybe_expire(opts[:days])

    key = License.sign(claims, private_bytes)

    Mix.shell().info("""

    Key for #{name}#{expiry_line(claims)}

    #{key}

    They set it as SSA_LICENSE_KEY, in .env or in their environment.
    """)
  end

  defp check(key) do
    public = License.config()[:public_key]

    case License.verify(key, public) do
      {:ok, claims} ->
        Mix.shell().info("""
        Valid.

          issued to  #{claims["sub"] || "unnamed"}
          issued at  #{format_time(claims["iat"])}
          expires    #{if claims["exp"], do: format_time(claims["exp"]), else: "never"}
          id         #{claims["jti"] || "—"}
        """)

      {:error, reason} ->
        Mix.raise("Not valid: #{License.explain(reason)}.")
    end
  end

  defp maybe_expire(claims, nil), do: claims

  defp maybe_expire(claims, days) do
    Map.put(claims, "exp", System.system_time(:second) + days * 86_400)
  end

  defp expiry_line(%{"exp" => exp}), do: ", expiring #{format_time(exp)}"
  defp expiry_line(_), do: ""

  defp format_time(nil), do: "—"

  defp format_time(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, at} -> Calendar.strftime(at, "%Y-%m-%d")
      _ -> to_string(unix)
    end
  end

  defp short_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
