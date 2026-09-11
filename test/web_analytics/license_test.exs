defmodule WebAnalytics.LicenseTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.License

  setup do
    {public, private} = License.generate_keypair()
    {:ok, private_bytes} = Base.decode64(private)
    %{public: public, private: private_bytes}
  end

  defp issue(claims, private), do: License.sign(claims, private)

  test "accepts a key signed by the matching private key", %{public: public, private: private} do
    key = issue(%{"sub" => "Acme Ltd", "iat" => 1_700_000_000}, private)

    assert {:ok, claims} = License.verify(key, public)
    assert claims["sub"] == "Acme Ltd"
  end

  test "rejects a key signed by a different private key", %{public: public} do
    # The whole point: someone with the public source can read the format, but
    # cannot mint a key without the licensor's private half.
    {_other_public, other_private} = License.generate_keypair()
    {:ok, other_bytes} = Base.decode64(other_private)

    forged = issue(%{"sub" => "Freeloader"}, other_bytes)

    assert {:error, :bad_signature} = License.verify(forged, public)
  end

  test "rejects a key whose payload was edited after signing", %{public: public, private: private} do
    key = issue(%{"sub" => "Trial", "exp" => 1}, private)
    [prefix, _payload, signature] = String.split(key, ".", parts: 3)

    tampered =
      Enum.join(
        [
          prefix,
          Base.url_encode64(Jason.encode!(%{"sub" => "Trial"}), padding: false),
          signature
        ],
        "."
      )

    assert {:error, :bad_signature} = License.verify(tampered, public)
  end

  test "rejects an expired key", %{public: public, private: private} do
    key = issue(%{"sub" => "Lapsed", "exp" => System.system_time(:second) - 60}, private)
    assert {:error, :expired} = License.verify(key, public)
  end

  test "accepts a key that has not expired yet", %{public: public, private: private} do
    key = issue(%{"sub" => "Current", "exp" => System.system_time(:second) + 3600}, private)
    assert {:ok, %{"sub" => "Current"}} = License.verify(key, public)
  end

  test "reports a missing key distinctly from a bad one", %{public: public} do
    assert {:error, :missing} = License.verify(nil, public)
    assert {:error, :missing} = License.verify("", public)
  end

  test "rejects malformed keys rather than crashing", %{public: public} do
    for junk <- [
          "not-a-key",
          "SSA1.only-two-parts",
          "SSA9.abc.def",
          "SSA1..",
          "SSA1.!!!.!!!",
          String.duplicate("A", 5000)
        ] do
      assert {:error, reason} = License.verify(junk, public)
      assert reason in [:malformed, :bad_signature], "#{junk} gave #{inspect(reason)}"
    end
  end

  test "reports an unconfigured build distinctly", %{private: private} do
    key = issue(%{"sub" => "Someone"}, private)

    assert {:error, :unconfigured} = License.verify(key, nil)
    assert {:error, :unconfigured} = License.verify(key, "")
  end

  test "a truncated key fails rather than being silently accepted", %{
    public: public,
    private: private
  } do
    key = issue(%{"sub" => "Acme"}, private)
    truncated = binary_part(key, 0, byte_size(key) - 10)

    assert {:error, _} = License.verify(truncated, public)
  end

  test "explains every failure in words an operator can act on" do
    for reason <- [:missing, :malformed, :bad_signature, :expired, :unconfigured] do
      explanation = License.explain(reason)
      assert is_binary(explanation) and explanation != ""
      refute explanation =~ ~r/^[a-z_]+$/, "#{reason} explanation is just the atom"
    end
  end

  test "tolerates padding and both base64 alphabets, since keys are pasted by hand", %{
    public: public,
    private: private
  } do
    key = issue(%{"sub" => "Acme"}, private)

    assert {:ok, _} = License.verify(" #{key}\n", public)
    assert {:ok, _} = License.verify(key, Base.encode64(Base.decode64!(public)))
  end
end
