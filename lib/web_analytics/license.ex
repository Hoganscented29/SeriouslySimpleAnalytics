defmodule WebAnalytics.License do
  @moduledoc """
  Verifies the deployment key this software refuses to start without.

  ## What this is, and what it is not

  The source is public, so a determined reader can delete this module and
  recompile. Nothing here prevents that, and claiming otherwise would be a lie
  told to the only people who would bother to check.

  What it does do is make the easy path require a key. `git clone && ./install.sh`
  stops at a wall, and getting past it means deliberately editing out a check
  that says, in the file you are editing, that you are not licensed to do this.
  That converts a shrug into a documented, wilful act — which is the difference
  that matters if the Functional Source License is ever enforced.

  So this is a lock on a door, not a wall around a field. Locks are still worth
  fitting.

  ## Why signatures and not a shared secret

  A key that this code can *generate* is a key anyone reading this code can
  generate. So keys are Ed25519 signatures over their own payload: the
  repository carries only the public key, and minting a valid key requires a
  private key that never leaves the licensor.

  ## Key format

      SSA1.<payload>.<signature>

  `payload` is base64url JSON — who it was issued to, when, and optionally when
  it expires. `signature` is Ed25519 over the payload bytes. The payload is
  readable by anyone holding a key, deliberately: a licensee should be able to
  see what they have been granted without asking.
  """

  require Logger

  @prefix "SSA1"

  @doc """
  Checks the configured key and stops the application if it is not valid.

  Called during boot, before any child process starts.
  """
  def enforce! do
    config = config()

    cond do
      not config[:enforce] ->
        :ok

      true ->
        case verify(key_from_env(), config[:public_key]) do
          {:ok, claims} ->
            Logger.info("Licensed to #{claims["sub"] || "unnamed"}#{expiry_note(claims)}")
            :ok

          {:error, reason} ->
            refuse(reason)
        end
    end
  end

  @doc """
  Verifies a key against a public key.

  Returns `{:ok, claims}` or `{:error, reason}`, where reason is one of
  `:missing`, `:malformed`, `:unconfigured`, `:bad_signature` or `:expired`.
  """
  def verify(key, public_key_base64)

  def verify(nil, _public_key), do: {:error, :missing}
  def verify("", _public_key), do: {:error, :missing}

  def verify(_key, blank) when blank in [nil, ""], do: {:error, :unconfigured}

  def verify(key, public_key_base64) when is_binary(key) do
    with {:ok, public_key} <- decode64(public_key_base64),
         [@prefix, payload, signature] <- String.split(String.trim(key), ".", parts: 3),
         {:ok, signature_bytes} <- decode64(signature),
         true <- valid_signature?(payload, signature_bytes, public_key),
         {:ok, claims} <- decode_payload(payload) do
      check_expiry(claims)
    else
      false -> {:error, :bad_signature}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def verify(_key, _public_key), do: {:error, :malformed}

  @doc "Builds a signed key. Used by `mix ssa.license issue`; needs the private key."
  def sign(claims, private_key) when is_map(claims) and is_binary(private_key) do
    payload =
      claims
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signature =
      :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
      |> Base.url_encode64(padding: false)

    Enum.join([@prefix, payload, signature], ".")
  end

  @doc "Generates an Ed25519 keypair as `{public_base64, private_base64}`."
  def generate_keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {Base.encode64(public), Base.encode64(private)}
  end

  @doc "Human-readable explanation of a verification failure."
  def explain(:missing), do: "no key was provided"
  def explain(:malformed), do: "the key is not in the expected format"
  def explain(:bad_signature), do: "the key's signature is not valid for this build"
  def explain(:expired), do: "the key has expired"
  def explain(:unconfigured), do: "this build has no licensor public key compiled in"
  def explain(other), do: to_string(other)

  @doc "The key from the environment, if set."
  def key_from_env, do: System.get_env("SSA_LICENSE_KEY")

  @doc "Merged license configuration."
  def config do
    Application.get_env(:web_analytics, :license, [])
    |> Keyword.put_new(:enforce, true)
    |> Keyword.put_new(:public_key, nil)
  end

  # -- internals -----------------------------------------------------------

  defp valid_signature?(payload, signature, public_key) do
    :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  defp decode_payload(payload) do
    with {:ok, json} <- decode64(payload),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_expiry(%{"exp" => exp} = claims) when is_integer(exp) do
    if System.system_time(:second) > exp, do: {:error, :expired}, else: {:ok, claims}
  end

  defp check_expiry(claims), do: {:ok, claims}

  # Keys are pasted by hand into .env files and CI settings, so both base64
  # alphabets are accepted and padding is optional.
  defp decode64(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Base.url_decode64(trimmed, padding: false) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        case Base.decode64(trimmed, padding: false) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :malformed}
        end
    end
  end

  defp decode64(_), do: {:error, :malformed}

  defp expiry_note(%{"exp" => exp}) when is_integer(exp) do
    case DateTime.from_unix(exp) do
      {:ok, at} -> ", expires #{Calendar.strftime(at, "%Y-%m-%d")}"
      _ -> ""
    end
  end

  defp expiry_note(_), do: ""

  # A stacktrace would bury the one thing the operator needs to read.
  defp refuse(reason) do
    IO.puts(:stderr, """

    #{IO.ANSI.red()}#{IO.ANSI.bright()}SeriouslySimpleAnalytics will not start: #{explain(reason)}.#{IO.ANSI.reset()}

    This software requires a deployment key. Set SSA_LICENSE_KEY in your
    environment or in .env:

        export SSA_LICENSE_KEY="SSA1.…"

    If you have a key, check it was copied whole — they are long and a
    truncated one fails the signature check rather than being ignored.

    If you do not have one, contact me@LoganBesecker.com.

    Developing or evaluating? Run in development mode, which does not require a
    key and binds to localhost only:

        ./install.sh --dev

    The licence terms are in LICENSE.md.
    """)

    System.halt(1)
  end
end
