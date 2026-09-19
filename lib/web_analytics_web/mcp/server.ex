defmodule WebAnalyticsWeb.MCP.Server do
  @moduledoc """
  The Model Context Protocol server: SeriouslySimpleAnalytics as tools an AI
  assistant can call.

  Transport-free — it takes one decoded JSON-RPC message and a context, and
  returns an HTTP status with a body — so the protocol can be tested without a
  connection and `WebAnalyticsWeb.MCPController` stays a thin shell.

  Two eras of the protocol are spoken at once, because clients in the wild are
  on both:

    * **Stateless (2026-07-28).** No handshake. Every request carries its
      protocol version in `params._meta`, `server/discover` replaces
      `initialize`, and every result says `resultType: "complete"`.
    * **Handshake (2024-11-05 to 2025-11-25).** `initialize` negotiates a
      version, notifications are acknowledged with 202, and `ping` exists.

  A request is modern if and only if it carries
  `io.modelcontextprotocol/protocolVersion` in its `_meta`. That field is
  required in the new era and unknown in the old one, so it cannot misfire.

  The server holds no session state in either era. Tools, resources and prompts
  are the same for every caller; what an API key changes is which account the
  reading tools answer for, and that is decided per request.
  """

  alias WebAnalyticsWeb.MCP.Catalog
  alias WebAnalyticsWeb.MCP.Tools

  @version "1.0.0"
  @modern_versions ["2026-07-28"]
  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  # A day. The tool list only changes with a deploy, and a deploy bumps nothing
  # a client could see sooner than that anyway.
  @list_ttl_ms 86_400_000

  @doc "This server's version, as published to the MCP Registry."
  def version, do: @version

  @doc "Every protocol version this server speaks, newest first."
  def supported_versions, do: @modern_versions ++ @legacy_versions

  @doc "The server's identity, as MCP `Implementation`."
  def server_info(base_url) do
    %{
      "name" => "seriouslysimpleanalytics",
      "title" => "SeriouslySimpleAnalytics — Web & AI Agent Analytics",
      "version" => @version,
      "websiteUrl" => base_url <> "/analytics-mcp-server",
      "icons" => [
        %{
          "src" => base_url <> "/images/logo.svg",
          "mimeType" => "image/svg+xml",
          "sizes" => ["any"]
        }
      ]
    }
  end

  @doc "What the server tells a model about itself."
  def capabilities, do: %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}

  @doc """
  Handles one JSON-RPC message.

  `ctx` is a map with `:base_url`, `:ip`, `:headers` (lowercased names),
  `:site` (the account an API key unlocked, or nil) and `:auth` (`:none`,
  `:valid` or `:invalid`).

  Returns `{status, body}`; a nil body means the response has none.
  """
  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, ctx) when is_binary(method) do
    params = if is_map(message["params"]), do: message["params"], else: %{}
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}

    request = %{
      id: message["id"],
      notification?: not Map.has_key?(message, "id"),
      method: method,
      params: params
    }

    case meta["io.modelcontextprotocol/protocolVersion"] do
      version when is_binary(version) -> modern(request, version, ctx)
      _ -> legacy(request, ctx)
    end
  end

  # A client's answer to a request this server never sends. Acknowledged the
  # way the handshake era says to acknowledge any response.
  def handle(%{"jsonrpc" => "2.0", "id" => _} = message, _ctx)
      when is_map_key(message, "result") or is_map_key(message, "error") do
    {202, nil}
  end

  def handle(_message, _ctx) do
    {400, error(nil, -32600, "Invalid Request: expected a JSON-RPC 2.0 request object")}
  end

  # -- 2026-07-28 ----------------------------------------------------------

  defp modern(request, version, ctx) do
    cond do
      mismatch?(ctx, "mcp-protocol-version", version) ->
        {400, error(request.id, -32020, "MCP-Protocol-Version header does not match _meta")}

      mismatch?(ctx, "mcp-method", request.method) ->
        {400, error(request.id, -32020, "Mcp-Method header does not match the request method")}

      name_mismatch?(ctx, request) ->
        {400, error(request.id, -32020, "Mcp-Name header does not match the request")}

      version not in @modern_versions ->
        {400,
         error(request.id, -32022, "Unsupported protocol version", %{
           "supported" => supported_versions(),
           "requested" => version
         })}

      # This revision defines no client notifications over HTTP; accepting one
      # costs nothing and rejecting it helps nobody.
      request.notification? ->
        {202, nil}

      true ->
        case dispatch(request, ctx, :modern) do
          {:ok, result} ->
            {200, reply(request.id, complete(result, ctx))}

          {:error, :method_not_found} ->
            {404, error(request.id, -32601, "Method not found: #{request.method}")}

          {:error, code, message} ->
            {200, error(request.id, code, message)}
        end
    end
  end

  # The header only has to agree with the body when it is sent at all: a
  # client too old to send it is handled by the version check, not here.
  defp mismatch?(ctx, header, expected) do
    case header(ctx, header) do
      nil -> false
      value -> value != expected
    end
  end

  defp name_mismatch?(ctx, %{method: method, params: params})
       when method in ["tools/call", "prompts/get", "resources/read"] do
    expected = params["name"] || params["uri"]

    case header(ctx, "mcp-name") do
      nil -> false
      # Values that are not header-safe arrive Base64-wrapped; those are not
      # compared rather than guessed at.
      "=?base64?" <> _ -> false
      value -> value != expected
    end
  end

  defp name_mismatch?(_ctx, _request), do: false

  defp complete(result, ctx) do
    result
    |> Map.put("resultType", "complete")
    |> Map.update(
      "_meta",
      %{"io.modelcontextprotocol/serverInfo" => server_info(ctx.base_url)},
      fn meta ->
        Map.put(meta, "io.modelcontextprotocol/serverInfo", server_info(ctx.base_url))
      end
    )
  end

  # -- 2024-11-05 through 2025-11-25 --------------------------------------

  defp legacy(request, ctx) do
    header_version = header(ctx, "mcp-protocol-version")

    cond do
      header_version && header_version not in @legacy_versions ->
        {400,
         error(request.id, -32600, "Unsupported MCP-Protocol-Version: #{header_version}", %{
           "supported" => supported_versions()
         })}

      request.notification? ->
        {202, nil}

      true ->
        case dispatch(request, ctx, :legacy) do
          {:ok, result} ->
            {200, reply(request.id, result)}

          {:error, :method_not_found} ->
            {200, error(request.id, -32601, "Method not found: #{request.method}")}

          {:error, code, message} ->
            {200, error(request.id, code, message)}
        end
    end
  end

  # -- methods -------------------------------------------------------------

  defp dispatch(%{method: "initialize", params: params}, ctx, :legacy) do
    requested = params["protocolVersion"]
    version = if requested in @legacy_versions, do: requested, else: hd(@legacy_versions)

    {:ok,
     %{
       "protocolVersion" => version,
       "capabilities" => capabilities(),
       "serverInfo" => server_info(ctx.base_url),
       "instructions" => instructions()
     }}
  end

  defp dispatch(%{method: "ping"}, _ctx, :legacy), do: {:ok, %{}}

  defp dispatch(%{method: "server/discover"}, _ctx, _era) do
    {:ok,
     cacheable(%{
       "supportedVersions" => supported_versions(),
       "capabilities" => capabilities(),
       "instructions" => instructions()
     })}
  end

  defp dispatch(%{method: "tools/list"}, _ctx, era) do
    {:ok, maybe_cacheable(%{"tools" => Tools.definitions()}, era)}
  end

  defp dispatch(%{method: "tools/call", params: params}, ctx, _era) do
    case params do
      %{"name" => name} when is_binary(name) ->
        arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

        case Tools.call(name, arguments, ctx) do
          {:ok, result} -> {:ok, result}
          {:error, :unknown_tool} -> {:error, -32602, "Unknown tool: #{name}"}
        end

      _ ->
        {:error, -32602, "tools/call needs a tool name"}
    end
  end

  defp dispatch(%{method: "resources/list"}, ctx, era) do
    {:ok, maybe_cacheable(%{"resources" => Catalog.resources(ctx.base_url)}, era)}
  end

  defp dispatch(%{method: "resources/templates/list"}, _ctx, era) do
    {:ok, maybe_cacheable(%{"resourceTemplates" => []}, era)}
  end

  defp dispatch(%{method: "resources/read", params: params}, ctx, era) do
    case Catalog.read_resource(params["uri"], ctx.base_url) do
      {:ok, contents} ->
        {:ok, maybe_cacheable(%{"contents" => contents}, era, 3_600_000)}

      :error ->
        # -32002 before 2026-07-28, Invalid Params after.
        {:error, if(era == :modern, do: -32602, else: -32002),
         "Resource not found: #{params["uri"]}"}
    end
  end

  defp dispatch(%{method: "prompts/list"}, _ctx, era) do
    {:ok, maybe_cacheable(%{"prompts" => Catalog.prompts()}, era)}
  end

  defp dispatch(%{method: "prompts/get", params: params}, ctx, _era) do
    case Catalog.get_prompt(params["name"], params["arguments"] || %{}, ctx.base_url) do
      {:ok, prompt} -> {:ok, prompt}
      :error -> {:error, -32602, "Unknown prompt: #{params["name"]}"}
    end
  end

  defp dispatch(_request, _ctx, _era), do: {:error, :method_not_found}

  defp maybe_cacheable(result, era, ttl \\ @list_ttl_ms)
  defp maybe_cacheable(result, :modern, ttl), do: cacheable(result, ttl)
  defp maybe_cacheable(result, :legacy, _ttl), do: result

  # Nothing listed differs by caller, so shared caches may keep it.
  defp cacheable(result, ttl \\ @list_ttl_ms) do
    Map.merge(result, %{"ttlMs" => ttl, "cacheScope" => "public"})
  end

  @doc "Guidance a client may put in front of the model."
  def instructions do
    """
    SeriouslySimpleAnalytics is free, unlimited web analytics and AI agent analytics.

    Writing needs no key: create_analytics_account gives an account ID (and an API key), \
    track_event records an event, a pageview or a numeric metric for any account ID, and \
    get_integration_guide returns the website script tag and the event API for wiring a \
    project up permanently.

    Reading reports needs the account's API key as an `Authorization: Bearer ssa_…` header. \
    Start with get_analytics_overview; narrow any report with range, project, domain or user. \
    get_metrics sums numbers sent with events (revenue, sats, tokens); list_users and \
    get_user_activity show individual behaviour for events sent with `user`.

    Never put credentials, prompts or completions in event attributes.\
    """
  end

  # -- JSON-RPC ------------------------------------------------------------

  defp header(ctx, name) do
    case List.keyfind(Map.get(ctx, :headers, []), name, 0) do
      {_, value} when value != "" -> value
      _ -> nil
    end
  end

  defp reply(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @doc false
  def error(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end
end
