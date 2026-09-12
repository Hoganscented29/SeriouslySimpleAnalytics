defmodule WebAnalyticsWeb.Plugs.CrawlerReport do
  @moduledoc """
  Records crawlers that visit this deployment's own pages.

  The browser tag cannot see them. GPTBot and ClaudeBot fetch HTML and never
  execute JavaScript, so no beacon is ever sent and the visit is invisible to
  any JavaScript analytics, this one included.

  A hosted tracker has no way around that for somebody else's site — the request
  goes to their origin and never touches this server. But this *is* our origin
  for our own pages, so here the gap closes: the request arrives, it carries a
  user agent, and reporting it is a few lines rather than a log pipeline. That
  is exactly the recipe the crawler pages tell readers to run at their own
  origin, so we run it ourselves.

  Off unless `SSA_SELF_SITE_KEY` names an account, same as the tag.
  """
  import Plug.Conn

  alias WebAnalytics.Ingest
  alias WebAnalytics.Ingest.Crawler
  alias WebAnalytics.Sites

  @behaviour Plug

  # Consecutive fetches from the same crawler inside this window are one
  # session, which is what makes the pages and flow reports mean anything for a
  # crawl. Matches the ping endpoint's window.
  @session_window_seconds 1_800

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with key when is_binary(key) <- Application.get_env(:web_analytics, :self_site_key),
         [user_agent | _] <- get_req_header(conn, "user-agent"),
         true <- maybe_automated?(user_agent),
         %{crawler: true} = verdict <- Crawler.classify(user_agent),
         site when not is_nil(site) <- Sites.fetch_site_by_key(key) do
      report(conn, site, user_agent, verdict)
    end

    conn
  rescue
    # Telemetry must never be the reason a page fails to render.
    _ -> conn
  end

  # A cheap gate before the full ordered pattern list, which is around a hundred
  # regexes. Every human request would otherwise pay for them to find nothing.
  defp maybe_automated?(user_agent) do
    String.contains?(String.downcase(user_agent), [
      "bot",
      "crawl",
      "spider",
      "scrape",
      "archiver",
      "fetcher",
      "curl",
      "wget",
      "python",
      "http",
      "headless",
      "lighthouse",
      "monitoring",
      "preview"
    ])
  end

  defp report(conn, site, user_agent, verdict) do
    now = DateTime.utc_now()
    ip = client_ip(conn)
    ip_hash = Ingest.hash_ip(ip, site)
    unix_ms = DateTime.to_unix(now, :millisecond)

    payload = %{
      "k" => site.key,
      "s" => session_token(site, user_agent, ip_hash, now),
      "t" => unix_ms,
      "e" => [
        %{
          "n" => "init",
          "t" => unix_ms,
          "ua" => user_agent,
          "ref" => referrer(conn),
          # Says plainly where this came from: the server saw it, not the tag.
          "bot" => "server"
        },
        %{
          "n" => "pv",
          "t" => unix_ms,
          "path" => conn.request_path,
          "url" => Plug.Conn.request_url(conn),
          "host" => conn.host,
          "proto" => to_string(conn.scheme),
          "port" => conn.port
        }
      ]
    }

    Ingest.submit(site, payload,
      received_at: now,
      ip_hash: ip_hash,
      location: Ingest.locate(conn.req_headers, ip),
      agent_name: verdict.name
    )
  end

  # One session per crawler per half hour, so a crawl reads as a crawl rather
  # than as several hundred one-page visits.
  defp session_token(site, user_agent, ip_hash, now) do
    window = div(DateTime.to_unix(now), @session_window_seconds)

    :crypto.hash(:sha256, "#{site.id}|#{user_agent}|#{ip_hash}|#{window}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp referrer(conn) do
    case get_req_header(conn, "referer") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp client_ip(conn) do
    if Application.get_env(:web_analytics, :trust_proxy_headers, false) do
      case get_req_header(conn, "x-forwarded-for") do
        [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
        [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end
    else
      conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
