defmodule WebAnalyticsWeb.ClientIP do
  @moduledoc """
  The address a request came from.

  `x-forwarded-for` is client-controlled and only trusted when the deployment
  says it sits behind a proxy that overwrites it (`SSA_TRUST_PROXY`). Behind
  one, the socket address is the proxy's own — every visitor would share it —
  so ignoring the header there is as wrong as trusting it anywhere else.

  The address is never stored raw: callers salt and hash it, or mask it.
  """
  import Plug.Conn

  @doc "The client address as a string, or nil if the connection has none."
  def get(conn) do
    if Application.get_env(:web_analytics, :trust_proxy_headers, false) do
      case get_req_header(conn, "x-forwarded-for") do
        [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
        [] -> remote_ip(conn)
      end
    else
      remote_ip(conn)
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: nil}), do: nil
  defp remote_ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
