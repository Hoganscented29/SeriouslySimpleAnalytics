# Generates demo traffic for the dashboard.
#
#     mix run priv/repo/seeds.exs
#
# Everything is pushed through the real ingest pipeline rather than inserted
# directly, so the seeded data exercises the same normalisation, rollup and
# classification paths that live traffic does. A deliberate minority of the
# sessions are anomalous — one per rule — so the filter toggle has something to
# show on both settings.

alias WebAnalytics.Analytics.AnomalyWorker
alias WebAnalytics.Geo
alias WebAnalytics.Ingest
alias WebAnalytics.Sites

require Logger

Logger.configure(level: :warning)
:rand.seed(:exsss, {17, 42, 99})

# Seeded traffic is geolocated through the real resolver, so the data exercises
# the same path live beacons do rather than being written straight in.
case Geo.Database.reload() do
  {:ok, description} -> IO.puts("GeoIP: #{description}")
  {:error, _} -> IO.puts("GeoIP: no database — seeded locations will fall back to time zone")
end

site =
  case Sites.get_site_by_key("demo") do
    nil ->
      {:ok, site} = Sites.create_site(%{key: "demo", name: "Demo Site", domain: "localhost"})
      site

    site ->
      site
  end

pages = [
  {"/", "Acme — Home"},
  {"/pricing", "Acme — Pricing"},
  {"/docs", "Acme — Docs"},
  {"/thanks", "Acme — Thanks"}
]

journeys = [
  ["/"],
  ["/", "/pricing"],
  ["/", "/docs"],
  ["/", "/pricing", "/thanks"],
  ["/", "/docs", "/pricing"],
  ["/", "/docs", "/pricing", "/thanks"],
  ["/pricing", "/"],
  ["/docs"]
]

# Real public addresses spread across regions. Weighted so the mix looks like
# ordinary traffic rather than a uniform sample of the planet.
client_ips =
  List.duplicate("8.8.8.8", 6) ++
    List.duplicate("104.244.42.1", 5) ++
    List.duplicate("128.30.2.26", 4) ++
    List.duplicate("45.33.32.156", 4) ++
    List.duplicate("13.107.42.14", 3) ++
    List.duplicate("199.232.69.5", 3) ++
    List.duplicate("208.67.222.222", 3) ++
    List.duplicate("9.9.9.9", 2) ++
    List.duplicate("151.101.65.69", 4) ++
    List.duplicate("1.1.1.1", 3) ++
    List.duplicate("139.130.4.5", 2) ++
    List.duplicate("5.9.0.1", 3) ++
    List.duplicate("213.73.91.35", 2) ++
    List.duplicate("62.210.16.6", 3) ++
    List.duplicate("80.80.80.80", 2) ++
    List.duplicate("91.198.174.192", 2) ++
    ["77.88.8.8", "223.5.5.5", "168.95.1.1", "200.221.11.100", "196.10.52.29", "202.12.27.33"]

referrers = [
  nil,
  "https://news.ycombinator.com/item?id=1",
  "https://www.google.com/search?q=analytics",
  "https://x.com/someone/status/1",
  "https://elixirforum.com/t/thread"
]

agents = [
  {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
   2560, 1440},
  {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
   1920, 1080},
  {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
   1440, 900},
  {"Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
   390, 844},
  {"Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/122.0", 1920, 1080}
]

buttons = [
  {"button", "cta-primary", ["btn", "btn-primary"], "Get started"},
  {"button", "cta-secondary", ["btn"], "Watch demo"},
  {"a", "nav-pricing", ["btn"], "See pricing"},
  {"button", "signup-submit", ["btn", "btn-primary"], "Create account"},
  {"a", "nav-docs", ["btn", "btn-ghost"], "Read the docs"}
]

outbound = [
  {"https://elixir-lang.org/", "elixir-lang.org", "link-elixir"},
  {"https://www.phoenixframework.org/", "www.phoenixframework.org", "link-phoenix"},
  {"https://github.com/phoenixframework/phoenix", "github.com", "link-github"},
  {"https://hexdocs.pm/phoenix", "hexdocs.pm", "link-hexdocs"}
]

title_for = fn path -> Enum.find_value(pages, path, fn {p, t} -> p == path && t end) end
pick = fn list -> Enum.random(list) end

# Builds one full visit and pushes it through ingest as the browser would.
emit = fn opts ->
  started_at = opts.started_at
  token = "seed-" <> Integer.to_string(System.unique_integer([:positive]))
  {ua, screen_w, screen_h} = opts.agent
  referrer = opts.referrer

  base = System.system_time(:millisecond)

  init = %{
    "n" => "init",
    "t" => base,
    "ref" => referrer,
    "ua" => ua,
    "bot" => Map.get(opts, :bot_signal),
    "hb" => Map.get(opts, :heartbeat_ms, 1_000),
    "sw" => screen_w,
    "sh" => screen_h,
    "vw" => screen_w - 200,
    "vh" => screen_h - 300,
    "dpr" => 2,
    "lang" => "en-US",
    "tz" => "America/Los_Angeles",
    "utm" =>
      if(referrer && String.contains?(referrer, "news.ycombinator"),
        do: %{"source" => "hn", "medium" => "social", "campaign" => "launch"},
        else: %{}
      )
  }

  per_page = max(div(opts.dwell_ms, max(length(opts.journey), 1)), 1)

  {events, _} =
    opts.journey
    |> Enum.with_index(1)
    |> Enum.flat_map_reduce({0, nil}, fn {path, seq}, {elapsed, previous} ->
      scroll = opts.scroll.()
      ticks = opts.ticks_for.(per_page)

      tick_events =
        for index <- 1..max(ticks, 1) do
          progress = index / max(ticks, 1)

          %{
            "n" => "tick",
            "t" => base + elapsed + round(per_page * progress),
            "i" => index,
            "pv" => seq,
            "a" => if(opts.active?, do: 1, else: 0),
            "sp" => round(scroll * progress),
            "spx" => round(scroll * progress * 24),
            "dh" => 2400,
            "d" => elapsed + round(per_page * progress),
            "am" => if(opts.active?, do: round((elapsed + per_page * progress) * 0.8), else: 0),
            "pd" => round(per_page * progress),
            "pa" => if(opts.active?, do: round(per_page * progress * 0.8), else: 0)
          }
        end

      pageview = %{
        "n" => "pv",
        "t" => base + elapsed,
        "seq" => seq,
        "path" => path,
        "title" => title_for.(path),
        "url" => "http://localhost:4013" <> path,
        "vh" => screen_h - 300,
        "dh" => 2400,
        "ref" => if(seq == 1, do: referrer, else: "http://localhost:4013" <> previous),
        "fp" => previous,
        "ft" => previous && title_for.(previous)
      }

      clicks =
        if opts.clicks? and :rand.uniform() < 0.7 do
          {tag, id, classes, text} = pick.(buttons)

          [
            %{
              "n" => "click",
              "t" => base + elapsed + div(per_page, 2),
              "pv" => seq,
              "k" => "click",
              "tag" => tag,
              "id" => id,
              "cls" => classes,
              "clsr" => Enum.join(classes, " "),
              "txt" => text,
              "sel" => "main>#{tag}##{id}",
              "sp" => scroll,
              "ms" => div(per_page, 2),
              "data" => %{"testid" => id}
            }
          ]
        else
          []
        end

      outbound_clicks =
        if opts.clicks? and :rand.uniform() < 0.25 do
          {href, host, id} = pick.(outbound)

          [
            %{
              "n" => "click",
              "t" => base + elapsed + div(per_page, 2) + 50,
              "pv" => seq,
              "k" => "outbound",
              "tag" => "a",
              "id" => id,
              "cls" => ["btn", "out-link"],
              "clsr" => "btn out-link",
              "txt" => host,
              "href" => href,
              "host" => host,
              "hpath" => URI.parse(href).path,
              "out" => 1,
              "nt" => 1,
              "trig" => "mousedown",
              "sp" => scroll,
              "ms" => div(per_page, 2)
            }
          ]
        else
          []
        end

      form =
        if path == "/pricing" and opts.clicks? and :rand.uniform() < 0.5 do
          submitted? = :rand.uniform() < 0.55
          name = pick.(["Ada Lovelace", "Grace Hopper", "Alan Turing", "Katherine Johnson"])
          plan = pick.(["starter", "pro", "enterprise"])

          [
            %{
              "n" => "form",
              "t" => base + elapsed + per_page - 100,
              "pv" => seq,
              "st" => if(submitted?, do: "submitted", else: "abandoned"),
              "fid" => "signup",
              "fnm" => "signup",
              "act" => "/signup",
              "mth" => "post",
              "sel" => "form#signup",
              "cls" => ["signup-form"],
              "tfi" => 2_000 + :rand.uniform(6_000),
              "dur" => 5_000 + :rand.uniform(30_000),
              "flds" => [
                %{
                  "name" => "full_name",
                  "id" => "full_name",
                  "type" => "text",
                  "label" => "Full name",
                  "value" => name,
                  "filled" => true,
                  "changes" => 1 + :rand.uniform(4),
                  "focus_ms" => 1_000 + :rand.uniform(5_000)
                },
                %{
                  "name" => "email",
                  "id" => "email",
                  "type" => "email",
                  "label" => "Work email",
                  "value" =>
                    name
                    |> String.downcase()
                    |> String.replace(" ", ".")
                    |> Kernel.<>("@example.com"),
                  "filled" => true,
                  "changes" => 1 + :rand.uniform(3),
                  "focus_ms" => 1_000 + :rand.uniform(4_000)
                },
                %{
                  "name" => "password",
                  "id" => "password",
                  "type" => "password",
                  "label" => "Password",
                  "value" => "never-stored",
                  "masked" => true,
                  "filled" => submitted?,
                  "changes" => 1,
                  "focus_ms" => 900
                },
                %{
                  "name" => "plan",
                  "id" => "plan",
                  "type" => "select-one",
                  "label" => "Plan",
                  "value" => plan,
                  "filled" => true,
                  "changes" => 1,
                  "focus_ms" => 600
                },
                %{
                  "name" => "seats",
                  "id" => "seats",
                  "type" => "text",
                  "label" => "Seats",
                  "value" => if(submitted?, do: to_string(:rand.uniform(50)), else: nil),
                  "filled" => submitted?,
                  "changes" => if(submitted?, do: 2, else: 0),
                  "focus_ms" => 400
                }
              ]
            }
          ]
        else
          []
        end

      {[pageview] ++ tick_events ++ clicks ++ outbound_clicks ++ form, {elapsed + per_page, path}}
    end)

  last_seq = length(opts.journey)
  final_scroll = opts.scroll.()

  ending = %{
    "n" => "end",
    "t" => base + opts.dwell_ms,
    "pv" => last_seq,
    "d" => opts.dwell_ms,
    "am" => if(opts.active?, do: round(opts.dwell_ms * 0.8), else: 0),
    "pd" => per_page,
    "pa" => if(opts.active?, do: round(per_page * 0.8), else: 0),
    "sp" => final_scroll
  }

  payload = %{
    "k" => site.key,
    "s" => token,
    "v" => opts.visitor,
    "t" => base + opts.dwell_ms,
    "e" => [init] ++ events ++ [ending]
  }

  location =
    case Map.get(opts, :ip) do
      nil -> nil
      ip -> Geo.resolve(ip: ip)
    end

  Ingest.submit_sync(site, payload, received_at: started_at, location: location)
end

now = DateTime.utc_now()
visitors = for _ <- 1..90, do: Ecto.UUID.generate()

IO.puts("Seeding normal traffic...")

for index <- 1..220 do
  minutes_ago = :rand.uniform(7 * 24 * 60)
  journey = pick.(journeys)

  emit.(%{
    started_at: DateTime.add(now, -minutes_ago * 60, :second),
    journey: journey,
    # Dwell is log-normal in practice. Drawn per page and multiplied by the
    # journey length, so a longer visit takes proportionally longer rather than
    # cramming more pages into the same seconds.
    dwell_ms: (round(:math.exp(9.8 + :rand.normal() * 0.8)) * length(journey)) |> max(3_000),
    scroll: fn -> 25 + :rand.uniform(75) end,
    ticks_for: fn per_page -> per_page |> div(1000) |> min(25) |> max(2) end,
    active?: true,
    clicks?: true,
    agent: pick.(agents),
    referrer: pick.(referrers),
    ip: pick.(client_ips),
    visitor: Enum.at(visitors, rem(index, length(visitors)))
  })
end

IO.puts("Seeding anomalous traffic...")

# One batch per dwell rule the classifier implements, so every reason has an
# example. Bots are deliberately absent — they are seeded below as crawlers,
# which is a separate axis with its own filter and report.
anomalies = [
  # No measurable dwell at all
  %{
    count: 5,
    dwell_ms: 600,
    journey: ["/"],
    active?: false,
    clicks?: false,
    ticks: 0,
    agent: pick.(agents)
  },
  # Impossibly fast multi-page crawl
  %{
    count: 5,
    dwell_ms: 1_200,
    journey: ["/", "/pricing", "/docs", "/thanks"],
    active?: false,
    clicks?: false,
    ticks: 1,
    agent: pick.(agents)
  },
  # Tab parked open for most of a day
  %{
    count: 4,
    dwell_ms: 6 * 3_600_000,
    journey: ["/docs"],
    active?: false,
    clicks?: false,
    ticks: 80,
    agent: pick.(agents)
  },
  # Beyond any plausible visit length
  %{
    count: 3,
    dwell_ms: 20 * 3_600_000,
    journey: ["/"],
    active?: false,
    clicks?: false,
    ticks: 90,
    agent: pick.(agents)
  },
  # Heartbeats with no engagement at all
  %{
    count: 4,
    dwell_ms: 400_000,
    journey: ["/"],
    active?: false,
    clicks?: false,
    ticks: 70,
    agent: pick.(agents)
  }
]

for spec <- anomalies, _ <- 1..spec.count do
  emit.(%{
    started_at: DateTime.add(now, -:rand.uniform(7 * 24 * 60) * 60, :second),
    journey: spec.journey,
    dwell_ms: spec.dwell_ms,
    scroll: fn -> 0 end,
    ticks_for: fn _ -> spec.ticks end,
    active?: spec.active?,
    clicks?: spec.clicks?,
    agent: spec.agent,
    referrer: nil,
    ip: pick.(client_ips),
    visitor: Ecto.UUID.generate()
  })
end

IO.puts("Seeding crawler traffic...")

# Automated clients, sampled at the 10-second heartbeat the tracker drops to
# when it detects them. Covers the kinds worth telling apart in the report.
crawler_agents = [
  {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.1; +https://openai.com/gptbot",
   nil, 9},
  {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ClaudeBot/1.0; +claudebot@anthropic.com",
   nil, 7},
  {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot",
   nil, 4},
  {"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)", nil, 8},
  {"Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)", nil, 5},
  {"Mozilla/5.0 (compatible; Bytespider; spider-feedback@bytedance.com)", nil, 4},
  {"Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)", nil, 3},
  {"Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)", nil, 3},
  {"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36",
   "headless", 3},
  {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
   "webdriver", 2},
  {"curl/8.4.0", nil, 2}
]

for {ua, signal, count} <- crawler_agents, _ <- 1..count do
  # Crawlers move fast and deep: many pages, little time on each.
  journey = Enum.take_random(Enum.map(pages, &elem(&1, 0)), 1 + :rand.uniform(3))
  dwell = 2_000 + :rand.uniform(20_000)

  emit.(%{
    started_at: DateTime.add(now, -:rand.uniform(7 * 24 * 60) * 60, :second),
    journey: journey,
    dwell_ms: dwell,
    scroll: fn -> 0 end,
    # At a 10s heartbeat, a 20s visit produces two beats, not twenty.
    ticks_for: fn per_page -> per_page |> div(10_000) |> max(1) end,
    active?: false,
    clicks?: false,
    agent: {ua, 1024, 768},
    referrer: nil,
    ip: pick.(client_ips),
    visitor: Ecto.UUID.generate(),
    bot_signal: signal,
    heartbeat_ms: 10_000
  })
end

IO.puts("Classifying...")
classified = AnomalyWorker.classify_all()

IO.puts("Seeded. #{classified} sessions classified. Site key: #{site.key}")
