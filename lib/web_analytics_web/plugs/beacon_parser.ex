defmodule WebAnalyticsWeb.Plugs.BeaconParser do
  @moduledoc """
  Parses JSON beacons posted as `text/plain`.

  `navigator.sendBeacon` with a `text/plain` blob is a CORS *simple request*,
  so it reaches a cross-origin collector without a preflight — which matters
  when the beacon is racing a page teardown and there is no time for two round
  trips. The cost is that the body arrives mislabelled, so it is decoded here.
  """
  @behaviour Plug.Parsers

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "text", "plain", _headers, opts) do
    case read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, decode(body), conn}
      {:error, conn} -> {:ok, %{}, conn}
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      # Anything larger than the configured limit is a malformed or hostile
      # beacon; a real one is a few kilobytes.
      {:more, _partial, conn} ->
        {:error, conn}

      {:error, _reason} ->
        {:error, conn}
    end
  end

  defp decode(""), do: %{}

  defp decode(body) do
    case Phoenix.json_library().decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end
end
