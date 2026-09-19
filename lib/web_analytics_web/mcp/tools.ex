defmodule WebAnalyticsWeb.MCP.Tools do
  @moduledoc """
  The tools the MCP server offers.

  Two kinds, split by what they need:

    * **Writing** — create an account, record an event, get the integration
      guide. No key, exactly like the HTTP API: an account ID is public, so
      anything it allows is something anyone could already do with a GET.
    * **Reading** — every report. These need the account's API key in the
      `Authorization` header, because a report is the one thing an account ID
      must never unlock.

  Every tool is listed to every caller, key or not. The list is then the same
  for everyone, so it caches, and a model that has not been given a key can
  still see what one would let it do — and is told how to get one when it tries.

  Descriptions are written for the model choosing between tools: what the tool
  answers, not how it is built.
  """

  alias WebAnalytics.Analytics
  alias WebAnalytics.ApiKeys
  alias WebAnalytics.Ingest.Ping
  alias WebAnalyticsWeb.AccountProvisioning

  @ranges ~w(1h 24h 7d 30d all)

  @report_filters %{
    "range" => %{
      "type" => "string",
      "enum" => @ranges,
      "default" => "7d",
      "description" => "Time window: last hour, 24 hours, 7 days, 30 days, or all time."
    },
    "project" => %{
      "type" => "string",
      "description" =>
        "Only this project — the AI tool, app or agent reporting under the account. See get_account for the names."
    },
    "domain" => %{
      "type" => "string",
      "description" =>
        "Only this website hostname, for an account whose tag runs on several domains."
    },
    "user" => %{
      "type" => "string",
      "description" => "Only this identified user — the `user` ID sent with events."
    },
    "include_bots" => %{
      "type" => "boolean",
      "default" => false,
      "description" =>
        "Include crawler and bot visits to the website. Off by default so reports show people."
    }
  }

  @read %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @doc "Tool definitions for tools/list, in a fixed order."
  def definitions do
    Enum.map(tools(), fn tool ->
      Map.take(tool, ~w(name title description inputSchema annotations))
    end)
  end

  @doc "Calls a tool. Returns `{:ok, CallToolResult}` or `{:error, :unknown_tool}`."
  def call(name, arguments, ctx) do
    case Enum.find(tools(), &(&1["name"] == name)) do
      nil ->
        {:error, :unknown_tool}

      %{"access" => :key} = tool ->
        with_account(ctx, fn site -> run(tool["name"], arguments, Map.put(ctx, :site, site)) end)

      tool ->
        run(tool["name"], arguments, ctx)
    end
  end

  defp tools do
    [
      %{
        "name" => "create_analytics_account",
        "title" => "Create a free analytics account",
        "access" => :open,
        "description" =>
          "Create a free analytics account, no card required and no signup form, for web analytics " <>
            "and AI agent analytics. Returns the account ID used to track events and install the " <>
            "website tag, an API key for reading reports through this server, and a one-time claim " <>
            "link to the dashboard (or emails a sign-in link when `email` is given). Create one " <>
            "account per project and reuse it — never one per run.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "project" => %{
              "type" => "string",
              "description" => "Name of the website, app or AI tool being tracked."
            },
            "email" => %{
              "type" => "string",
              "description" =>
                "Optional. The address of the person who will read the dashboard; a sign-in link is mailed there."
            }
          },
          "required" => ["project"]
        },
        "annotations" => %{
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false,
          "openWorldHint" => false
        }
      },
      %{
        "name" => "track_event",
        "title" => "Track an event, pageview or metric",
        "access" => :open,
        "description" =>
          "Record one analytics event: a pageview, a tool call, a signup, a purchase, an error — " <>
            "anything that happened in a website, app or AI agent. Numeric attributes are summed " <>
            "and charted as metrics (revenue, tokens, sats); `user` attributes the event to a person " <>
            "or account for per-user analytics. Events sharing a session_id form one session with " <>
            "page flow. Send the amount for this one event, never a running total, and never " <>
            "credentials, prompts or completions.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "account_id" => %{
              "type" => "string",
              "description" =>
                "The account ID (acct_…). Optional when an API key is sent: its account is used."
            },
            "event" => %{
              "type" => "string",
              "description" =>
                "What happened, e.g. page_view, tool_called, run_completed, signup, purchase, error. " <>
                  "page_view with a path is recorded as a real pageview."
            },
            "project" => %{
              "type" => "string",
              "description" =>
                "Which website, app or AI tool this is. Keeps projects separate in reports."
            },
            "user" => %{
              "type" => "string",
              "description" =>
                "Your own stable ID for who the event is about — an account, customer or mailbox ID. " <>
                  "Prefer an opaque ID to an email address."
            },
            "user_identifiers" => %{
              "type" => "object",
              "additionalProperties" => %{"type" => ["string", "number", "boolean"]},
              "description" =>
                "Other identifiers for that user, e.g. {\"domain\": \"acme.com\", \"plan\": \"pro\"}. Shown beside the user."
            },
            "attributes" => %{
              "type" => "object",
              "additionalProperties" => %{"type" => ["string", "number", "boolean"]},
              "description" =>
                "Any dimensions or quantities, e.g. {\"tool\": \"search\", \"latency_ms\": 420, \"usd\": 19.99}. " <>
                  "Numbers are summed and graphed. Up to 20."
            },
            "session_id" => %{
              "type" => "string",
              "description" =>
                "Groups events into one session: a run, conversation or visit. Without it, events are grouped per user over 30 minutes."
            },
            "path" => %{
              "type" => "string",
              "description" => "A page, screen or step, e.g. /checkout."
            },
            "title" => %{
              "type" => "string",
              "description" => "A human-readable name for the path."
            },
            "city" => %{"type" => "string", "description" => "The user's city."},
            "county" => %{"type" => "string", "description" => "The user's county."},
            "state" => %{"type" => "string", "description" => "The user's state or province."},
            "country" => %{
              "type" => "string",
              "description" => "The user's country, as a name or ISO code."
            },
            "channel" => %{
              "type" => "string",
              "default" => "ai",
              "description" => "ai for an AI tool or agent, web for a website."
            },
            "agent_name" => %{
              "type" => "string",
              "description" => "The AI or tool doing the reporting, e.g. Claude Code."
            },
            "referrer" => %{"type" => "string", "description" => "Where this came from."}
          },
          "required" => ["event"]
        },
        "annotations" => %{
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false,
          "openWorldHint" => false
        }
      },
      %{
        "name" => "get_integration_guide",
        "title" => "Get the tracking code and API",
        "access" => :open,
        "description" =>
          "How to add analytics to a project permanently: the one-line website tracking script " <>
            "(a free Google Analytics alternative), the event API URL " <>
            "for AI agents, CLIs and backends, and the config to connect this MCP server to Claude, " <>
            "Cursor, VS Code or other MCP clients.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "account_id" => %{
              "type" => "string",
              "description" => "Fill the account ID into the snippets."
            },
            "project" => %{
              "type" => "string",
              "description" => "Fill the project name into the snippets."
            },
            "kind" => %{
              "type" => "string",
              "enum" => ["website", "ai_tool", "both"],
              "default" => "both",
              "description" => "A website, an AI tool or backend, or both."
            }
          }
        },
        "annotations" => @read
      },
      read_tool(
        "get_account",
        "Account, projects and domains",
        "Which account the API key belongs to, and the projects, website domains and traffic " <>
          "channels reporting into it — the values the other reports' project and domain filters take.",
        %{}
      ),
      read_tool(
        "get_analytics_overview",
        "Traffic overview",
        "Website and app traffic summary: sessions, unique visitors, identified users, pageviews, " <>
          "bounce rate, average engagement time, scroll depth, clicks and outbound links, with the " <>
          "top pages, top referrers, channels, devices and countries. The best first call for " <>
          "\"how is my site doing?\".",
        %{}
      ),
      read_tool(
        "get_traffic_timeseries",
        "Visits over time",
        "Sessions and pageviews bucketed over the time range, for spotting trends, spikes and drops in traffic.",
        %{
          "buckets" => %{
            "type" => "integer",
            "minimum" => 4,
            "maximum" => 96,
            "default" => 24,
            "description" => "How many time buckets to split the range into."
          }
        }
      ),
      read_tool(
        "get_top_pages",
        "Top pages",
        "Most viewed pages with views, sessions, average time on page, scroll depth, clicks, entrances " <>
          "and exit rate, plus the top landing pages and exit pages.",
        %{
          "limit" => limit_schema(25),
          "group_by" => %{
            "type" => "string",
            "enum" => ["path", "title"],
            "default" => "path",
            "description" => "Group by URL path or by page title."
          }
        }
      ),
      read_tool(
        "get_traffic_sources",
        "Traffic sources and audience",
        "Break sessions down by one dimension: referrer, UTM source, medium or campaign, browser, " <>
          "operating system, device type, language, country, region, city or channel. Answers " <>
          "\"where does my traffic come from?\" and \"who are my visitors?\".",
        %{
          "dimension" => %{
            "type" => "string",
            "enum" => Map.keys(dimensions()) |> Enum.sort(),
            "default" => "referrer",
            "description" => "What to break sessions down by."
          },
          "limit" => limit_schema(15)
        }
      ),
      read_tool(
        "get_events",
        "Custom events",
        "Custom events by count, sessions and first and last seen — tool calls, signups, purchases, " <>
          "errors, conversions. Name one `event` to also get its attributes' commonest values and " <>
          "its volume over time.",
        %{
          "event" => %{"type" => "string", "description" => "One event name to drill into."},
          "limit" => limit_schema(30)
        }
      ),
      read_tool(
        "get_metrics",
        "Metrics: revenue, tokens, counts",
        "Custom numeric metrics: revenue, tokens, sats, PRs, latency, or any counter you define, " <>
          "summed from event attributes — each with total, count, average, minimum and maximum. " <>
          "Name a `key` to chart it per hour or per day.",
        %{
          "key" => %{
            "type" => "string",
            "description" => "One metric to chart over time, e.g. usd."
          },
          "granularity" => %{
            "type" => "string",
            "enum" => ["hour", "day"],
            "default" => "day",
            "description" => "Bucket size for the chart."
          }
        }
      ),
      read_tool(
        "list_users",
        "Identified users",
        "Every identified user — events sent with `user` — with sessions, events, pageviews, " <>
          "projects, locations, first and last seen, and their other identifiers. For user " <>
          "analytics, customer activity and finding the most engaged accounts.",
        %{
          "sort" => %{
            "type" => "string",
            "enum" => ["recent", "sessions", "events"],
            "default" => "recent",
            "description" => "Most recently active, most sessions, or most events first."
          },
          "limit" => limit_schema(50)
        }
      ),
      read_tool(
        "get_user_activity",
        "One user's activity",
        "Everything one identified user did: a profile with their identifiers and totals, a " <>
          "timeline of their events with attributes, what they did most, and the metrics they " <>
          "generated.",
        %{"limit" => limit_schema(50)},
        ["user"]
      ),
      read_tool(
        "get_live_visitors",
        "Live visitors right now",
        "Real-time analytics: who is on the website or using the AI tool right now — active " <>
          "sessions and visitors in the last 30 seconds and 30 minutes, with the page or event " <>
          "each is on. Ignores range.",
        %{}
      ),
      read_tool(
        "get_page_flow",
        "Page flow and user journeys",
        "How visitors move through a site or app: the busiest page-to-page transitions and the " <>
          "most common three-step journeys, for funnel and navigation analysis.",
        %{"limit" => limit_schema(20)}
      ),
      read_tool(
        "get_ai_crawler_traffic",
        "AI crawler and bot traffic",
        "Which AI crawlers and bots visit the website — GPTBot, ClaudeBot, PerplexityBot, " <>
          "Google-Extended and others — how often, and which pages they read. For AI search " <>
          "visibility and LLM crawler monitoring.",
        %{"limit" => limit_schema(25)}
      )
    ]
  end

  defp read_tool(name, title, description, extra, required \\ []) do
    %{
      "name" => name,
      "title" => title,
      "access" => :key,
      "description" => description <> " Needs the account's API key.",
      "inputSchema" =>
        %{"type" => "object", "properties" => Map.merge(@report_filters, extra)}
        |> then(fn schema ->
          if required == [], do: schema, else: Map.put(schema, "required", required)
        end),
      "annotations" => @read
    }
  end

  defp limit_schema(default) do
    %{
      "type" => "integer",
      "minimum" => 1,
      "maximum" => 200,
      "default" => default,
      "description" => "Most rows to return."
    }
  end

  defp dimensions do
    %{
      "referrer" => :referrer_host,
      "utm_source" => :utm_source,
      "utm_medium" => :utm_medium,
      "utm_campaign" => :utm_campaign,
      "browser" => :browser,
      "os" => :os,
      "device" => :device_type,
      "language" => :language,
      "country" => :country,
      "region" => :region,
      "city" => :city,
      "channel" => :channel
    }
  end

  # -- access --------------------------------------------------------------

  defp with_account(%{auth: :valid, site: site}, fun) when not is_nil(site), do: fun.(site)

  defp with_account(%{auth: :invalid} = ctx, _fun) do
    error(
      "The API key in the Authorization header is not valid or has been revoked. Create a new " <>
        "one on #{ctx.base_url}/getting-started, under MCP server."
    )
  end

  defp with_account(ctx, _fun) do
    error(
      "Reading reports needs the account's API key, sent as `Authorization: Bearer #{ApiKeys.prefix()}…`. " <>
        "Create one on #{ctx.base_url}/getting-started under MCP server, or use the api_key returned " <>
        "by create_analytics_account. Tracking events does not need one."
    )
  end

  # -- writing -------------------------------------------------------------

  defp run("create_analytics_account", args, ctx) do
    params = %{"project" => string(args["project"]), "email" => string(args["email"])}

    case AccountProvisioning.create(params, ctx.ip) do
      {:ok, body, site} ->
        data =
          case ApiKeys.create(site, "Created through MCP") do
            {:ok, token, _key} ->
              Map.merge(body, %{
                api_key: token,
                api_key_usage:
                  "Send as the header `Authorization: Bearer #{token}` to read this account's reports. " <>
                    "It is shown once: store it with the account ID."
              })

            _ ->
              body
          end

        ok(data, "Created account #{site.key}.")

      {:error, _reason, body} ->
        error(body.message, body)
    end
  end

  defp run("track_event", args, ctx) do
    account_id = string(args["account_id"]) || (ctx[:site] && ctx.site.key)

    cond do
      is_nil(account_id) ->
        error("track_event needs account_id (or an API key, whose account is used).")

      is_nil(string(args["event"])) ->
        error("track_event needs an event name.")

      true ->
        {params, ignored} = ping_params(args, account_id)

        case Ping.submit(params, ip: ctx.ip, headers: Map.get(ctx, :headers, [])) do
          {:ok, _site} ->
            ok(
              %{
                recorded: true,
                account_id: account_id,
                event: params["event"],
                ignored_attributes: ignored
              },
              "Recorded #{params["event"]}."
            )

          # Without a key, an unknown account gets the same answer as a real
          # one, like the HTTP API: this must not become a way to test whether
          # an account ID exists. Holding that account's key proves ownership,
          # and then a typo is worth pointing out.
          :unknown_account ->
            if ctx[:site] && ctx.site.key == account_id do
              error("Account #{account_id} does not exist.")
            else
              ok(
                %{
                  accepted: true,
                  account_id: account_id,
                  event: params["event"],
                  ignored_attributes: ignored
                },
                "Accepted #{params["event"]}. It is recorded if #{account_id} is a real account ID."
              )
            end
        end
    end
  end

  defp run("get_integration_guide", args, ctx) do
    base = ctx.base_url
    key = string(args["account_id"]) || (ctx[:site] && ctx.site.key) || "YOUR_ACCOUNT_ID"
    project = string(args["project"]) || "my-project"
    kind = if args["kind"] in ["website", "ai_tool"], do: args["kind"], else: "both"

    website = ~s|<script src="#{base}/wa.js" data-site="#{key}" defer></script>|

    ping =
      "#{base}/api/ping?uid=#{key}&type=ai&project=#{URI.encode_www_form(project)}" <>
        "&event=run_started&sid=SESSION_ID&user=USER_ID&c=CITY&s_p=STATE&n=COUNTRY"

    mcp = %{
      "url" => base <> "/mcp",
      "claude_code" =>
        "claude mcp add --transport http seriouslysimpleanalytics #{base}/mcp " <>
          "--header \"Authorization: Bearer YOUR_API_KEY\"",
      "json_config" => %{
        "mcpServers" => %{
          "seriouslysimpleanalytics" => %{
            "type" => "http",
            "url" => base <> "/mcp",
            "headers" => %{"Authorization" => "Bearer YOUR_API_KEY"}
          }
        }
      }
    }

    data =
      %{
        account_id: key,
        docs: base <> "/llms.txt",
        dashboard: base <> "/dashboard",
        mcp_server: mcp
      }
      |> then(fn d ->
        if kind in ["website", "both"], do: Map.put(d, :website_script_tag, website), else: d
      end)
      |> then(fn d ->
        if kind in ["ai_tool", "both"], do: Map.put(d, :event_api_url, ping), else: d
      end)

    guide =
      [
        kind in ["website", "both"] &&
          "Website: put this tag in the shared layout, before </head>. One tag covers every page.\n\n    #{website}",
        kind in ["ai_tool", "both"] &&
          "AI tool, CLI or backend: fetch this URL once per event (GET or POST, 204 response, never retry). " <>
            "Reuse one sid per run, send user= for per-user analytics, and add any attribute as a parameter.\n\n    #{ping}",
        "Full contract, including what never to send: #{base}/llms.txt"
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n\n")

    ok(data, guide)
  end

  # -- reading -------------------------------------------------------------

  defp run("get_account", args, ctx) do
    f = filters(ctx.site, Map.put_new(args, "range", "all"))

    ok(
      %{
        account_id: ctx.site.key,
        name: ctx.site.name,
        projects: Analytics.projects(f),
        domains: Analytics.domains(f),
        channels: Analytics.channels(f)
      },
      "Account #{ctx.site.key} (#{ctx.site.name})."
    )
  end

  defp run("get_analytics_overview", args, ctx) do
    f = filters(ctx.site, args)
    totals = Analytics.overview(f)

    ok(
      %{
        range: f.range,
        totals: Map.drop(totals, [:bounces]),
        top_pages:
          f
          |> Analytics.pages(10)
          |> Enum.map(&Map.take(&1, [:name, :views, :sessions, :dwell_ms, :exit_rate])),
        top_referrers: Analytics.session_breakdown(f, :referrer_host, 10),
        channels: Analytics.channels(f),
        devices: Analytics.session_breakdown(f, :device_type, 5),
        countries: Analytics.session_breakdown(f, :country, 10)
      },
      "#{totals.sessions} sessions, #{totals.visitors} visitors and #{totals.pageviews} pageviews (#{f.range})."
    )
  end

  defp run("get_traffic_timeseries", args, ctx) do
    f = filters(ctx.site, args)
    buckets = integer(args["buckets"], 24, 4, 96)
    ok(%{range: f.range, series: Analytics.timeseries(f, buckets)}, "Sessions over #{f.range}.")
  end

  defp run("get_top_pages", args, ctx) do
    f = filters(ctx.site, args)
    limit = integer(args["limit"], 25, 1, 200)

    ok(
      %{
        range: f.range,
        group_by: f.group_by,
        pages: Analytics.pages(f, limit),
        landing_pages: Analytics.entries(f),
        exit_pages: Analytics.exits(f)
      },
      "Top pages (#{f.range})."
    )
  end

  defp run("get_traffic_sources", args, ctx) do
    f = filters(ctx.site, args)

    dimension =
      if Map.has_key?(dimensions(), args["dimension"]), do: args["dimension"], else: "referrer"

    limit = integer(args["limit"], 15, 1, 200)

    ok(
      %{
        range: f.range,
        dimension: dimension,
        rows: Analytics.session_breakdown(f, Map.fetch!(dimensions(), dimension), limit)
      },
      "Sessions by #{dimension} (#{f.range})."
    )
  end

  defp run("get_events", args, ctx) do
    f = filters(ctx.site, args)
    limit = integer(args["limit"], 30, 1, 200)
    name = string(args["event"])

    data = %{range: f.range, events: Analytics.events(f, limit)}

    data =
      if name do
        Map.merge(data, %{
          event: name,
          attributes: Analytics.event_attributes(f, name),
          over_time: Analytics.event_timeseries(f, name)
        })
      else
        data
      end

    ok(data, "Events (#{f.range}).")
  end

  defp run("get_metrics", args, ctx) do
    f = filters(ctx.site, args)
    granularity = if args["granularity"] == "hour", do: :hour, else: :day
    key = string(args["key"])
    metrics = Analytics.metrics(f)

    data = %{range: f.range, metrics: metrics}

    data =
      if key do
        Map.merge(data, %{
          key: key,
          granularity: granularity,
          series: Analytics.metric_series(f, key, granularity: granularity)
        })
      else
        data
      end

    ok(data, "#{length(metrics)} numeric metric(s) (#{f.range}).")
  end

  defp run("list_users", args, ctx) do
    f = filters(ctx.site, args)
    sort = Enum.find(Analytics.user_sorts(), :recent, &(Atom.to_string(&1) == args["sort"]))
    users = Analytics.users(f, integer(args["limit"], 50, 1, 200), sort)

    ok(
      %{range: f.range, sort: sort, users: users},
      "#{length(users)} identified user(s) (#{f.range})."
    )
  end

  defp run("get_user_activity", args, ctx) do
    case string(args["user"]) do
      nil ->
        error("get_user_activity needs a user ID. list_users shows them.")

      user ->
        f = filters(ctx.site, Map.put(args, "user", user))

        case Analytics.user_profile(f) do
          nil ->
            error(
              "No activity from user #{user} in #{f.range}. Try range \"all\", or list_users."
            )

          profile ->
            timeline =
              f
              |> Analytics.recent_events(integer(args["limit"], 50, 1, 200))
              |> Enum.map(&Map.take(&1, [:at, :name, :path, :attrs, :project, :session_token]))

            ok(
              %{
                range: f.range,
                profile: profile,
                timeline: timeline,
                top_events: Analytics.events(f, 15),
                metrics: Analytics.metrics(f)
              },
              "#{user}: #{profile.sessions} session(s), #{profile.events} event(s) (#{f.range})."
            )
        end
    end
  end

  defp run("get_live_visitors", args, ctx) do
    live = ctx.site |> filters(args) |> Analytics.active_now()

    sessions =
      Enum.map(live.sessions_list, fn s ->
        Map.take(s, [
          :started_at,
          :last_seen_at,
          :user_id,
          :project,
          :channel,
          :entry_path,
          :exit_path,
          :referrer_host,
          :pageview_count,
          :dwell_ms,
          :last_event,
          :events,
          :city,
          :country,
          :browser,
          :device_type
        ])
      end)

    ok(
      live |> Map.drop([:sessions_list]) |> Map.put(:sessions, sessions),
      "#{live.live_sessions} active in the last 30 seconds, #{live.sessions} in the last 30 minutes."
    )
  end

  defp run("get_page_flow", args, ctx) do
    f = filters(ctx.site, args)
    limit = integer(args["limit"], 20, 1, 200)

    ok(
      %{
        range: f.range,
        transitions: Analytics.flow(f, limit),
        journeys: Analytics.journeys(f, min(limit, 25))
      },
      "Page flow (#{f.range})."
    )
  end

  defp run("get_ai_crawler_traffic", args, ctx) do
    f = filters(ctx.site, args)
    limit = integer(args["limit"], 25, 1, 200)

    ok(
      %{
        range: f.range,
        overview: Analytics.crawler_overview(f),
        crawlers: Analytics.crawlers_by_name(f, limit),
        kinds: Analytics.crawlers_by_kind(f),
        pages: Analytics.crawler_pages(f, limit)
      },
      "Crawler traffic (#{f.range})."
    )
  end

  # -- helpers -------------------------------------------------------------

  defp filters(site, args) do
    Analytics.filters(site.id, %{
      range: if(args["range"] in @ranges, do: args["range"], else: "7d"),
      project: string(args["project"]),
      host: string(args["domain"]),
      user: string(args["user"]),
      exclude_crawlers: args["include_bots"] != true,
      group_by: if(args["group_by"] == "title", do: :title, else: :path)
    })
  end

  # The tool's readable argument names, translated into the ping API's own, so
  # the event is recorded by exactly the code a GET /api/ping would reach.
  defp ping_params(args, account_id) do
    named = %{
      "uid" => account_id,
      "event" => string(args["event"]),
      "project" => string(args["project"]),
      "user" => scalar(args["user"]),
      "sid" => string(args["session_id"]),
      "path" => string(args["path"]),
      "title" => string(args["title"]),
      "city" => string(args["city"]),
      "county" => string(args["county"]),
      "state" => string(args["state"]),
      "country" => string(args["country"]),
      "type" => string(args["channel"]),
      "name" => string(args["agent_name"]),
      "ref" => string(args["referrer"])
    }

    identifiers =
      for {key, value} <- object(args["user_identifiers"]), scalar(value), into: %{} do
        {"user_" <> key, scalar(value)}
      end

    # An attribute named like a reserved parameter would silently change what
    # the event means — `name` would rename the reporting tool — so those are
    # dropped and reported back rather than passed through.
    {attributes, ignored} =
      object(args["attributes"])
      |> Enum.filter(fn {_key, value} -> scalar(value) end)
      |> Enum.split_with(fn {key, _value} -> key not in Ping.reserved() end)

    params =
      named
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(Map.new(attributes, fn {key, value} -> {key, scalar(value)} end))
      |> Map.merge(identifiers)

    {params, Enum.map(ignored, &elem(&1, 0))}
  end

  defp object(value) when is_map(value), do: value
  defp object(_), do: %{}

  defp scalar(value) when is_binary(value), do: string(value)

  defp scalar(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp scalar(_), do: nil

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string(_), do: nil

  defp integer(value, _default, low, high) when is_integer(value),
    do: value |> max(low) |> min(high)

  defp integer(_value, default, _low, _high), do: default

  defp ok(data, summary) do
    data = jsonable(data)

    {:ok,
     %{
       "content" => [
         %{"type" => "text", "text" => summary <> "\n\n" <> Jason.encode!(data, pretty: true)}
       ],
       "structuredContent" => data
     }}
  end

  # A failed tool call is a result the model reads, not a protocol error: it
  # can fix the arguments and try again.
  defp error(message, data \\ nil) do
    result = %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
    {:ok, if(data, do: Map.put(result, "structuredContent", jsonable(data)), else: result)}
  end

  @doc false
  def jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def jsonable(%Date{} = value), do: Date.to_iso8601(value)
  def jsonable(%Decimal{} = value), do: value |> Decimal.round(4) |> Decimal.to_float()

  def jsonable(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.reject(fn {_key, value} -> match?(%Ecto.Association.NotLoaded{}, value) end)
    |> jsonable()
  end

  def jsonable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)

  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()

  def jsonable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  def jsonable(value), do: value
end
