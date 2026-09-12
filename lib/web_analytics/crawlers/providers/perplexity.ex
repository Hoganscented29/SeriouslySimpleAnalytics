defmodule WebAnalytics.Crawlers.Providers.Perplexity do
  @moduledoc "Content for the PerplexityBot analytics page."

  alias WebAnalytics.Crawlers.Provider

  def provider do
    %Provider{
      slug: "perplexitybot",
      name: "PerplexityBot",
      vendor: "Perplexity",
      keyword: "PerplexityBot Analytics",
      description:
        "PerplexityBot Analytics — free analytics for PerplexityBot. See which pages " <>
          "PerplexityBot and Perplexity-User take, how they line up with the referrals " <>
          "Perplexity sends back, and whether your robots.txt rule is doing anything.",
      lede:
        "Perplexity is the AI company whose entire product is built on citing sources, which " <>
          "makes it the one where crawling and referral are most obviously two halves of the " <>
          "same relationship. PerplexityBot Analytics shows you both: what its crawlers take, " <>
          "and what comes back. Free, one script tag, self-hostable.",
      agents: [
        %{
          token: "PerplexityBot",
          robots: "PerplexityBot",
          purpose: "Indexing, so your pages can be surfaced and cited in Perplexity's answers.",
          example:
            "Mozilla/5.0 (compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)"
        },
        %{
          token: "Perplexity-User",
          robots: "Perplexity-User",
          purpose: "A live fetch, made because a person asked something that needed your page.",
          example:
            "Mozilla/5.0 (compatible; Perplexity-User/1.0; +https://perplexity.ai/perplexity-user)"
        }
      ],
      robots_tokens: ~w(PerplexityBot Perplexity-User),
      facts: [
        {"Vendor", "Perplexity"},
        {"Crawlers", "Two, controlled separately"},
        {"Kind", "AI crawler"},
        {"Cites sources", "Yes — referrals are part of the deal"},
        {"Renders JavaScript", "No"},
        {"Publishes IP ranges", "Yes"},
        {"Cost to track it here", "Free"}
      ],
      sections: sections(),
      faq: faq(),
      related_note:
        "Perplexity's citation-first model makes the referral half unusually visible, but the " <>
          "same trade-off exists with every provider. The report covers all of them."
    }
  end

  defp sections do
    [
      %{
        id: "what-it-is",
        heading: "What PerplexityBot is and why it is different",
        body: [
          {:p,
           "Perplexity is an answer engine. You ask it something, it searches, reads, and " <>
             "returns an answer with the sources listed and linked. That product shape has a " <>
             "direct consequence for your site: unlike a pure training crawl, the crawling here " <>
             "exists to feed something that shows your name and links back to you."},
          {:p,
           "That does not automatically make it good for you. A well-cited answer can satisfy " <>
             "a reader completely without a click, and a citation you never get a visit from is " <>
             "worth exactly the branding value of having your name in small type. But it does " <>
             "make the relationship measurable in a way the pure-training case is not. The " <>
             "crawl and the referral are both in your own numbers, and you can put them side by " <>
             "side."},
          {:p,
           "There are two agents. PerplexityBot crawls and indexes so your pages can be " <>
             "surfaced. Perplexity-User fetches a page because somebody asked a question that " <>
             "needed it — a live request with a person waiting. As with every provider running " <>
             "a split like this, the two deserve separate treatment and almost never get it."},
          {:p,
           "PerplexityBot Analytics separates them, counts them, lists the pages each takes, " <>
             "and sits next to the referrer report so you can see what comes back. That " <>
             "pairing is the entire argument for measuring this provider specifically."}
        ]
      },
      %{
        id: "user-agents",
        heading: "The PerplexityBot user agent strings",
        body: [
          {:p,
           "Both agents identify themselves and carry a URL pointing at Perplexity's own " <>
             "documentation. These are the tokens matched here:"},
          {:agents, nil},
          {:p,
           "Match the token case-insensitively, anywhere in the header. Perplexity's user " <>
             "agents have historically included a browser-shaped prefix, which means a detector " <>
             "that treats \"Chrome\" or \"Safari\" in a header as evidence of a human will " <>
             "misfile them as visitors. Specific token first; treat the browser decoration as " <>
             "decoration."},
          {:p,
           "Grepping your own logs, a case-insensitive search for \"perplexity\" catches both " <>
             "agents and the documentation URLs at once. That is convenient for a quick look " <>
             "and unhelpful as a permanent measurement, because it merges the two agents back " <>
             "into a single number and the ratio between them is the interesting part."}
        ]
      },
      %{
        id: "verify",
        heading: "Verification matters more here than almost anywhere",
        body: [
          {:p,
           "A User-Agent header is a claim anyone can make, and with Perplexity specifically " <>
             "the gap between the claim and the reality has been the subject of public " <>
             "argument. Independent researchers have published findings alleging that requests " <>
             "reached sites which had disallowed Perplexity's declared agents; Perplexity has " <>
             "disputed aspects of those findings. We are an analytics tool and have no " <>
             "first-hand basis to adjudicate that dispute."},
          {:p,
           "What we can say without taking a side is the practical conclusion, which holds " <>
             "regardless of who is right: if a robots.txt rule is load-bearing for you, do not " <>
             "assume it is working. Verify identity at the network layer, and measure whether " <>
             "the rule changed anything. Both of those are things you would want to do anyway, " <>
             "and this is simply a case where the cost of not doing them is more visible."},
          {:p,
           "The vendor-independent verification method: take the source address, do a reverse " <>
             "DNS lookup, confirm the hostname belongs to the domain claimed, then forward-resolve " <>
             "that hostname and confirm it returns the original address. Both directions must " <>
             "agree, because reverse DNS alone is controlled by whoever owns the address. " <>
             "Perplexity also publishes address ranges for its crawlers, which is the faster " <>
             "check at your edge."},
          {:p,
           "And the measurement half, which is what this tool gives you: write the rule, note " <>
             "the date, and watch the agent's request count for the following week or two. If " <>
             "the declared agent goes quiet, the rule works. If declared traffic disappears but " <>
             "your origin load does not move, something is still fetching your pages under a " <>
             "different name — which is exactly the situation where having the numbers matters " <>
             "more than having an opinion."}
        ]
      },
      %{
        id: "invisible",
        heading: "Why none of this is in your existing analytics",
        body: [
          {:p,
           "Browser analytics records a visit when JavaScript runs in a browser. PerplexityBot " <>
             "does not run JavaScript, so the request is served, the bytes leave your server, " <>
             "and the tracker is never invoked. The traffic is not filtered — it was never " <>
             "collected."},
          {:p,
           "The result is a blind spot with an awkward shape. The crawler half of your " <>
             "relationship with Perplexity is invisible. The referral half — people clicking " <>
             "through from a cited answer — is perfectly visible, because those are humans with " <>
             "browsers. So the picture most site owners have is half a picture, and it is the " <>
             "flattering half."},
          {:p,
           "This tool has the same blind spot, and you should know that before relying on it. " <>
             "It is a JavaScript tracker: it names the automated clients that render a page — " <>
             "headless browsers, monitoring agents, agent browsers — and PerplexityBot is not " <>
             "among them. The referral half lands in your reports on its own; the crawl half " <>
             "only does if your own server reports it, with one ping per hit carrying `bot=`. " <>
             "That is the arrangement in which both halves can actually be compared, and it " <>
             "takes a few lines at your origin rather than a log pipeline."},
          {:p,
           "Keeping them apart matters just as much. A crawler is not a visitor. Mixing them " <>
             "gives you a bounce rate polluted by a client that cannot bounce and a session " <>
             "count inflated by something with no sessions. Here, crawler traffic is its own " <>
             "dimension: out of the human reports by default, always fully present in its own."}
        ]
      },
      %{
        id: "detection",
        heading: "How PerplexityBot is identified",
        body: [
          {:p,
           "Whatever reaches ingest carries a user agent — from a client that rendered the " <>
             "page, or from your own server reporting a crawler hit — and it is classified " <>
             "against an ordered list of patterns, most specific first. PerplexityBot and " <>
             "Perplexity-User each have their own entry and their own display name, both filed " <>
             "under the kind \"AI crawler\"."},
          {:p,
           "The ordering is the mechanism. A catch-all rule matching anything containing " <>
             "\"bot\" would swallow PerplexityBot into an unclassified bucket, and a " <>
             "search-engine pattern checked too early would file an AI crawler as search " <>
             "traffic. Most specific first, every time, in one readable list rather than a set " <>
             "of independent rules that can disagree."},
          {:p,
           "The kind assigned then drives the rest: automated traffic is sampled at ten-second " <>
             "resolution instead of the one-second cadence used for humans, and held out of the " <>
             "default reports with a one-click toggle to include it. The crawler report is " <>
             "always fully populated regardless of where that toggle sits."},
          {:p,
           "The list is open source and readable. If Perplexity ships another agent, adding it " <>
             "on your own deployment is one line, with no vendor release to wait for."}
        ]
      },
      %{
        id: "metrics",
        heading: "What the PerplexityBot report gives you",
        body: [
          {:ul,
           [
             "Requests per agent — PerplexityBot and Perplexity-User counted separately, because the ratio is the most informative number available about this provider.",
             "Pages taken — the ranked list of URLs each agent fetched, which tells you what Perplexity considers worth citing from your site.",
             "First seen and last seen — when each agent appeared and whether it is still returning.",
             "Shape over time — requests bucketed across your range, so indexing sweeps and live fetches are visually distinguishable.",
             "Kind breakdown — how much of your server's work is AI crawling at all, against search, SEO tools, unfurlers and monitors.",
             "Referrals, in the same dashboard — people arriving from Perplexity are ordinary human visitors with a referrer, so the other half of the relationship is right there."
           ]},
          {:p,
           "The pages-taken list is where the value is concentrated. Because Perplexity cites " <>
             "what it uses, the URLs it fetches repeatedly are a fair proxy for the pages it " <>
             "considers authoritative on their subject. That is a genuinely useful piece of " <>
             "competitive information and it is sitting in your own access logs, unread."},
          {:p,
           "Put the pages-taken list next to your referrer report filtered to Perplexity. Pages " <>
             "heavily crawled and never referred from are pages being consumed without return. " <>
             "Pages crawled and referred are the relationship working as advertised. That " <>
             "comparison is the single most actionable thing on this page."}
        ]
      },
      %{
        id: "referrals",
        heading: "The referral half: what actually comes back",
        body: [
          {:p,
           "Perplexity links its sources prominently, which means referral traffic is a real " <>
             "and growing channel rather than a theoretical one. Those visitors show up in your " <>
             "ordinary reports with a referrer, because they are people with browsers."},
          {:p,
           "The shape is distinctive. Volume is lower than search — considerably lower — but " <>
             "engagement tends to be higher, because someone arriving from a cited answer has " <>
             "already been told roughly what your page says and clicked anyway. That is a " <>
             "reader who wants the detail, not one checking whether they are in the right " <>
             "place. Engaged time and scroll depth make it visible, and both are captured by " <>
             "default."},
          {:p,
           "It is worth being honest about the ceiling here. An answer engine that answers well " <>
             "reduces the number of people who need to click, and no amount of citation changes " <>
             "that arithmetic. The referral you get is from the subset who wanted more than the " <>
             "summary. For some content that is most of the audience; for a factual lookup it " <>
             "is nearly nobody."},
          {:p,
           "Which of those you are is an empirical question about your own pages, and it is " <>
             "answerable. Crawl volume, referral volume, and engaged time on the referred " <>
             "traffic — three numbers, all in one place, and together they tell you whether " <>
             "this relationship is worth having."}
        ]
      },
      %{
        id: "reading",
        heading: "Reading Perplexity traffic",
        body: [
          {:h3, "Indexing sweeps"},
          {:p,
           "PerplexityBot moving across a wide spread of your URLs over hours. This is index " <>
             "building. It tends to recur at intervals rather than happening once, because an " <>
             "answer engine's index has to stay current in a way a training corpus does not."},
          {:h3, "Live fetches with no pattern"},
          {:p,
           "Perplexity-User landing on specific deep pages at unpredictable times. Each one is " <>
             "a question someone asked. The absence of pattern is the signature — these are " <>
             "driven by individual human curiosity, not a schedule."},
          {:h3, "Repeated returns to a small set of URLs"},
          {:p,
           "The same handful of pages fetched over and over. Those are pages being cited " <>
             "frequently, kept fresh because they keep being used. Whatever else is true, they " <>
             "are your most machine-visible content, and knowing which ones they are is useful " <>
             "whether you want to build on that or stop it."},
          {:h3, "A crawl that follows publication"},
          {:p,
           "Fetching shortly after you publish means a feed or sitemap is being watched, and " <>
             "gives you a real latency figure for how quickly new work becomes reachable " <>
             "through Perplexity."},
          {:p,
           "None of these is good or bad on its own. They are inputs to a decision that is " <>
             "yours, and the point of measuring is that the decision stops being a guess about " <>
             "a company's behaviour and becomes a reading of your own logs."}
        ]
      },
      %{
        id: "rate",
        heading: "Crawl volume and ten-second sampling",
        body: [
          {:p,
           "The browser tracker beacons once a second early in a human visit, which is what " <>
             "makes dwell and engaged time meaningful at that resolution. Automated traffic " <>
             "gets ten-second sampling instead, and the reason is arithmetic rather than " <>
             "principle."},
          {:p,
           "A crawler can fetch thousands of pages in minutes. Per-second telemetry across that " <>
             "is a denial of service you built against yourself, so anything classified as " <>
             "automated is sampled at ten seconds. Every request, URL and agent is still " <>
             "recorded; what is given up is sub-ten-second dwell precision on a client that " <>
             "does not dwell, scroll or read."},
          {:p,
           "The rule applies by classification rather than by volume, so it is predictable: a " <>
             "recognised crawler is sampled at ten seconds from its first request, and no human " <>
             "is ever downgraded for browsing quickly."},
          {:p,
           "If a crawl is genuinely too heavy for your origin, the levers are Crawl-delay, edge " <>
             "rate limiting and caching. The report is how you find out whether pulling one " <>
             "actually changed anything — which, given the verification questions above, is a " <>
             "step worth taking seriously here rather than assuming."}
        ]
      },
      %{
        id: "robots",
        heading: "Controlling PerplexityBot with robots.txt",
        body: [
          {:p,
           "Both agents are addressed by their own token. As always, robots.txt is a request " <>
             "that reputable crawlers choose to honour rather than a control that enforces " <>
             "anything."},
          {:h3, "Block indexing, keep live fetches"},
          {:code,
           "User-agent: PerplexityBot\nDisallow: /\n\nUser-agent: Perplexity-User\nAllow: /"},
          {:h3, "Block everything from Perplexity"},
          {:code,
           "User-agent: PerplexityBot\nDisallow: /\n\nUser-agent: Perplexity-User\nDisallow: /"},
          {:h3, "Allow the parts you want cited, protect the rest"},
          {:code,
           "User-agent: PerplexityBot\nAllow: /blog/\nAllow: /docs/\nDisallow: /pricing/\nDisallow: /customers/"},
          {:note,
           "Given the public disagreements about whether requests attributed to Perplexity have " <>
             "always honoured these rules, treat a Disallow here as the beginning of the " <>
             "process rather than the end of it. Write the rule, then verify with your own " <>
             "numbers that it took effect. Anything you genuinely must keep out belongs behind " <>
             "authentication."},
          {:p,
           "Allow a couple of weeks before drawing conclusions — robots.txt is cached — and " <>
             "compare not just the declared agent's count but your overall origin load. A " <>
             "declared agent going quiet while load stays flat is a meaningful signal."}
        ]
      },
      %{
        id: "decide",
        heading: "Should you block PerplexityBot?",
        body: [
          {:h3, "For allowing it"},
          {:p,
           "Perplexity cites, links, and sends real traffic. For documentation, reference " <>
             "material, research and technical writing, being the source an answer engine " <>
             "reaches for is a distribution channel, and it is one many of your competitors " <>
             "have blocked themselves out of. The referred visitors tend to be more engaged " <>
             "than search traffic, which is a point in its favour that rarely gets made."},
          {:h3, "For blocking it"},
          {:p,
           "An answer engine that answers well removes the need to click. If your business is " <>
             "measured in sessions, ad impressions or subscriptions, a good citation can still " <>
             "be a net loss. And if you are a publisher with any prospect of a licensing " <>
             "conversation, being freely available weakens your position in it."},
          {:h3, "The position most people land on"},
          {:p,
           "Allow indexing of the content you want spread — documentation, blog, reference — " <>
             "and disallow the pages that exist to convert rather than to inform. This is " <>
             "usually a better fit than an all-or-nothing rule, because most sites contain both " <>
             "kinds of content and they have opposite interests."},
          {:p,
           "Whatever you choose, choose it from your own numbers. Crawl volume, referral " <>
             "volume, engaged time on the referred traffic. A site where all three are healthy " <>
             "and one where crawling is heavy and referrals are zero should not arrive at the " <>
             "same conclusion, and without measurement they usually do."}
        ]
      },
      %{
        id: "llms-txt",
        heading: "llms.txt and being legible to an answer engine",
        body: [
          {:p,
           "robots.txt says what may be taken. It says nothing about what your site is or which " <>
             "parts are worth reading. llms.txt is the emerging convention for the second " <>
             "question: plain text at your root, written for a model, describing what you offer " <>
             "and pointing at the pages that matter."},
          {:p,
           "For an answer engine specifically, the argument is stronger than usual. Perplexity " <>
             "is deciding which source to cite for a question, and a site that states plainly " <>
             "what it is authoritative about is easier to choose than one a model has to infer " <>
             "from navigation markup. It is not a ranking signal in any documented sense; it is " <>
             "simply clearer."},
          {:p,
           "We publish our own, describing our entire event API, specifically so a coding agent " <>
             "can integrate without a human reading documentation first. It works, and that is " <>
             "an argument from our own traffic rather than from theory."},
          {:p,
           "AGENTS.md is the same idea for repositories. Neither file changes what a crawler " <>
             "may take; both change how well it understands what it took."}
        ]
      },
      %{
        id: "attribution",
        heading: "Knowing a visit came from Perplexity at all",
        body: [
          {:p,
           "The referral half of this relationship is only useful if you can actually see it, " <>
             "and attribution from AI surfaces is messier than attribution from search. It is " <>
             "worth understanding where the gaps are before you draw conclusions from a number."},
          {:p,
           "In the good case, a click from a cited answer arrives with a referrer naming the " <>
             "answer engine, and it lands in your referrer report like any other. That is the " <>
             "majority case and it is why the comparison this page keeps recommending — crawl " <>
             "volume against referral volume — is possible at all."},
          {:p,
           "There are three ways it goes wrong. Some clients strip or truncate the referrer for " <>
             "privacy reasons, in which case the visit lands in your direct bucket and is " <>
             "indistinguishable from someone typing your URL. A link opened in a native mobile " <>
             "app may not pass a referrer at all. And a user who reads your name in an answer, " <>
             "then searches for you separately, produces a visit attributed to the search " <>
             "engine even though the AI surface is what created the demand."},
          {:p,
           "The practical consequence is that referral counts from AI surfaces are a floor " <>
             "rather than a measurement. Treat the number as \"at least this many\", not " <>
             "\"exactly this many\". A rising direct-traffic bucket that correlates with rising " <>
             "crawler activity is weak evidence but it is not no evidence, and engaged time on " <>
             "that direct traffic is worth watching — visitors who arrived with intent behave " <>
             "differently from bookmark traffic."},
          {:p,
           "None of this is fixable by a tracker, ours or anyone else's, because the " <>
             "information genuinely is not in the request. What a tracker can do is not " <>
             "pretend otherwise. Engaged time and scroll depth on direct and referred traffic " <>
             "are captured by default here, which at least gives you a way to reason about the " <>
             "unattributed portion rather than ignoring it."}
        ]
      },
      %{
        id: "compare",
        heading: "PerplexityBot compared with the other AI crawlers",
        body: [
          {:ul,
           [
             "OpenAI splits three ways — GPTBot for training, ChatGPT-User for live fetches, OAI-SearchBot for search — and publishes per-agent address ranges as JSON.",
             "Anthropic splits the same three ways with ClaudeBot, Claude-User and Claude-SearchBot.",
             "Google-Extended is not a crawler at all but a permission token governing whether content Googlebot already fetched may be used for Gemini. Blocking it removes no requests, because it never made any.",
             "Applebot-Extended works identically: a token layered over Applebot, not a separate client.",
             "Meta-ExternalAgent, Bytespider and Amazonbot are conventional crawlers, varying widely in volume and in how carefully they honour robots.txt.",
             "CCBot is Common Crawl, a non-profit archive many organisations subsequently train on, so allowing it has a far wider blast radius than allowing any single company."
           ]},
          {:p,
           "Perplexity's distinguishing feature in this list is that the return leg is visible. " <>
             "With a pure training crawler you are guessing at the benefit; here you can count " <>
             "it. That does not make the answer yes, but it does make it an answerable question."}
        ]
      },
      %{
        id: "what-it-sees",
        heading: "What Perplexity sees when it fetches your page",
        body: [
          {:p,
           "Worth checking before you spend any time on robots.txt, because it changes the " <>
             "whole conversation. PerplexityBot requests a URL and reads the HTML that comes " <>
             "back. It does not execute JavaScript. Whatever your server put in that first " <>
             "response is the entirety of what it got."},
          {:p,
           "For a server-rendered or static site that is fine — roughly what a human would see " <>
             "with scripting off. For a single-page application rendering client-side, the " <>
             "initial response may be an empty container and a bundle reference. A browser " <>
             "fills that in within a second; a crawler never does. Your whole site can be, from " <>
             "an answer engine's point of view, blank."},
          {:p,
           "The test takes thirty seconds. Fetch one of your own pages with curl and read the " <>
             "output. If your actual content is not in there, Perplexity has never seen it and " <>
             "has never been able to cite you, and no amount of arguing about crawler policy " <>
             "changes that. Being invisible by accident is a different situation from being " <>
             "private by choice, and only one of them is a decision you made."},
          {:p,
           "For an answer engine specifically, two further details earn their keep. Semantic " <>
             "markup — real headings, a meaningful title, content in the order it should be " <>
             "read — is doing more work for machine readers than it has done in years, because " <>
             "a model summarising your page uses structure to decide what matters. And a clear " <>
             "statement of what a page is actually about, near the top, survives summarisation " <>
             "better than the same claim buried in the fourth paragraph."},
          {:p,
           "None of that is search engine optimisation in the old sense, and there is no " <>
             "documented ranking signal to game. It is the more boring thing: if you want to be " <>
             "cited accurately, be legible. Perplexity Analytics tells you which pages were " <>
             "fetched; the curl test tells you whether there was anything in them when they " <>
             "arrived."}
        ]
      },
      %{
        id: "cost",
        heading: "What a Perplexity crawl costs",
        body: [
          {:p,
           "Bandwidth is the cost everyone names and usually the smallest. A crawler that does " <>
             "not render pulls no images, fonts, video or JavaScript bundles — the cheapest " <>
             "bytes you serve. For most sites the whole crawl rounds to nothing against a day " <>
             "of human traffic."},
          {:p,
           "Origin load is the one that bites, and only for sites generating every page on " <>
             "demand from a database. An indexing sweep walks deep URLs that are never warm in " <>
             "any cache, which is close to a worst case. If a crawl has ever moved your latency " <>
             "graphs, that was why, and the answer is edge caching rather than a Disallow line."},
          {:p,
           "The third cost is the one people actually discover: pages being indexed that you " <>
             "did not intend to be public. Staging environments left reachable, print views, " <>
             "faceted URLs multiplying into near-duplicates, forgotten campaign pages. A " <>
             "crawler finds all of them, and for an answer engine that means any of them could " <>
             "end up cited. Reading the pages-taken list is often the moment a site owner learns " <>
             "what is genuinely reachable on their own domain."},
          {:p,
           "Measure before optimising. Request counts per agent over time turn \"is this " <>
             "costing me\" into a question with an answer. For most sites the answer is no, and " <>
             "the attention belongs on the pages-taken list instead."}
        ]
      },
      %{
        id: "first-week",
        heading: "A first week with PerplexityBot Analytics",
        body: [
          {:ol,
           [
             "Open the crawlers tab and read the kind breakdown. Most people are surprised by how much automated traffic their server handles in total, well beyond AI.",
             "Find both Perplexity agents and note the ratio. Indexing against live fetches is the most informative number here, and a merged total destroys it.",
             "Read the pages-taken list. These are the pages Perplexity considers worth citing from your site — useful whether your reaction is to promote them or to protect them.",
             "Filter your referrer report to Perplexity and compare. Crawled-and-referred pages are the relationship working; crawled-and-never-referred pages are consumption without return.",
             "Only then decide about robots.txt. If you write a rule, note the date, and check both the agent's count and your overall origin load a fortnight later."
           ]},
          {:p,
           "Measure, decide, verify. Ordinary advice everywhere else in engineering, and " <>
             "strangely rare in discussions of AI crawlers, which tend to go from an opinion " <>
             "straight to a robots.txt file with no numbers in between."}
        ]
      },
      %{
        id: "setup",
        heading: "Setting up PerplexityBot Analytics",
        body: [
          {:ol,
           [
             "Create a free account. Your account ID is on the dashboard the moment you sign in.",
             "Paste the script tag into the head of your pages. That is the entire integration.",
             "Open the crawlers tab. PerplexityBot and Perplexity-User appear by name as they arrive, and the referrer report fills in beside them."
           ]},
          {:p,
           "If you also build AI tools — an agent, an MCP server, a CLI, an extension — the " <>
             "same account tracks those by fetching one URL, with no SDK and nothing added to " <>
             "your dependency tree. Crawler analytics and your own tool's telemetry land in the " <>
             "same dashboard."},
          {:p,
           "All of it is free, because there is no paid tier. The project is open source and " <>
             "can be self-hosted against your own Postgres if you would rather no third party " <>
             "sat in the path."}
        ]
      },
      %{
        id: "privacy",
        heading: "Privacy and self-hosting",
        body: [
          {:ul,
           [
             "No cookies — identifiers live in browser storage, so there is no consent banner.",
             "No full IP addresses stored — used in-request to resolve a location, after which only a middle-masked copy and a salted hash are kept, with the salt rotating daily.",
             "Password fields are masked in the browser and dropped again server-side.",
             "data-wa-ignore on any element, form or field excludes it entirely.",
             "Self-host and none of this requires trusting us, because we are not in the path."
           ]},
          {:p,
           "The source is public and the detection rules are one readable list in one file. " <>
             "Given the verification questions on this page, being able to read exactly what is " <>
             "classified as Perplexity — rather than trusting a vendor's word for it — is " <>
             "worth more here than usual."}
        ]
      }
    ]
  end

  defp faq do
    [
      {"What is PerplexityBot?",
       "PerplexityBot is Perplexity's crawler, used to index pages so they can be surfaced and " <>
         "cited in Perplexity's answers. It runs alongside Perplexity-User, which fetches a " <>
         "specific page because a person asked a question that needed it."},
      {"What is the PerplexityBot user agent?",
       "PerplexityBot sends a User-Agent containing the token PerplexityBot along with a link " <>
         "to Perplexity's documentation. Match the token case-insensitively rather than the " <>
         "full string, because the surrounding browser-shaped prefix and version have changed " <>
         "over time."},
      {"What is the difference between PerplexityBot and Perplexity-User?",
       "PerplexityBot crawls to build an index. Perplexity-User fetches one page because " <>
         "somebody asked a question that required it, with a person waiting at the other end. " <>
         "Blocking the first while allowing the second is a coherent position."},
      {"Does PerplexityBot respect robots.txt?",
       "Perplexity states that it does. Independent researchers have published findings " <>
         "alleging that requests reached sites which had disallowed it, and Perplexity has " <>
         "disputed aspects of those findings. The practical conclusion either way is the same: " <>
         "if the rule is load-bearing for you, verify with your own numbers that it took effect " <>
         "rather than assuming."},
      {"How do I block PerplexityBot?",
       "Add a Disallow rule for PerplexityBot, and a separate one for Perplexity-User if you " <>
         "also want to stop live fetches. Then watch both the agent's request count and your " <>
         "overall origin load over the following fortnight. Anything you genuinely must keep " <>
         "out belongs behind authentication, not robots.txt."},
      {"Should I block PerplexityBot?",
       "It depends on whether the citations bring you anything. Perplexity does send real " <>
         "referral traffic, and it tends to be more engaged than search traffic. But an answer " <>
         "engine that answers well reduces the need to click at all. Compare your crawl volume " <>
         "with your Perplexity referral volume before deciding — the two numbers together give " <>
         "you the answer, and neither gives it alone."},
      {"Why doesn't PerplexityBot show in Google Analytics?",
       "Because JavaScript analytics only records clients that execute JavaScript, and " <>
         "PerplexityBot does not. Your server handled the request but no tracker ran — and the " <>
         "same is true here, since this is a JavaScript tracker too. To see it, report each hit " <>
         "from your own server to the ping API with `bot=`, or read your access log."},
      {"Can I see which of my pages Perplexity cites?",
       "Not directly — citations happen inside Perplexity's product. But the pages-taken list " <>
         "is a close proxy, because Perplexity fetches what it intends to use, and your " <>
         "referrer report shows which citations actually produced a click. Together the two are " <>
         "the best view available from outside."},
      {"How do I verify a request really came from Perplexity?",
       "Reverse DNS on the source address, confirm the hostname belongs to the domain claimed, " <>
         "then forward-resolve that hostname and confirm it returns the original address. Both " <>
         "directions must agree. Perplexity also publishes address ranges for its crawlers, " <>
         "which is faster if you are checking at your edge."},
      {"Is PerplexityBot Analytics free?",
       "Yes, entirely. No paid tier, no event quota, no sampling above a traffic threshold. The " <>
         "project is open source and can be self-hosted against your own Postgres."},
      {"Will crawler traffic distort my human numbers?",
       "No. Automated traffic is excluded from the ordinary reports by default and given a " <>
         "report of its own. Nothing is deleted — including crawlers is one toggle, and the " <>
         "crawler report is fully populated either way."},
      {"Does Perplexity see my JavaScript-rendered content?",
       "No. It reads the HTML your server returns and does not execute JavaScript, so a " <>
         "client-rendered single-page application may be effectively blank to it. Fetch one of " <>
         "your own pages with curl and read what comes back — if your content is not in there, " <>
         "it has never been seen by any AI crawler."},
      {"Why is crawler dwell sampled every ten seconds?",
       "Because crawlers arrive in volumes humans do not produce, and per-second telemetry " <>
         "across a large crawl would be a denial of service you built against yourself. " <>
         "Sub-ten-second precision is meaningless for a client that does not read or scroll."},
      {"Does Perplexity send real traffic, or just citations?",
       "It sends real traffic. Perplexity links its sources prominently and people do click " <>
         "through, arriving as ordinary human visitors with a referrer. Volume is well below " <>
         "search, but engagement tends to be higher, because someone clicking a citation has " <>
         "already read the summary and wanted more anyway."},
      {"How often does PerplexityBot crawl?",
       "There is no fixed schedule and it varies enormously by site. Because an answer engine's " <>
         "index has to stay current, indexing tends to recur at intervals rather than happening " <>
         "once — a different rhythm from a pure training crawl. Your own report is the only " <>
         "reliable source for your site."},
      {"Can I allow Perplexity on some pages and block it on others?",
       "Yes. robots.txt matches on path, so you can allow your documentation and blog while " <>
         "disallowing pricing, customer pages or anything else that exists to convert rather " <>
         "than to inform. Most sites contain both kinds of content and they have opposite " <>
         "interests, so this is usually a better fit than an all-or-nothing rule."},
      {"Why does Perplexity referral traffic look smaller than it should?",
       "Attribution from AI surfaces is a floor rather than a measurement. Some clients strip " <>
         "the referrer, links opened in native mobile apps may not pass one at all, and a user " <>
         "who reads your name in an answer and then searches for you separately is attributed " <>
         "to the search engine. Treat the number as \"at least this many\" and watch engaged " <>
         "time on your direct traffic alongside it."},
      {"Will blocking PerplexityBot stop the referrals too?",
       "Almost certainly, yes. Perplexity cites what it has been able to read, so removing " <>
         "yourself from the index removes you from the answers that would have linked to you. " <>
         "This is the trade-off in its clearest form, and it is why the crawl and referral " <>
         "numbers have to be read together rather than separately."},
      {"Does this work behind a CDN?",
       "The browser tracker does, since it runs in the visitor's browser. Forward the original " <>
         "client address or every visit appears to come from your edge. If you report crawler " <>
         "hits from your origin, note that a CDN answers many of them without ever consulting " <>
         "your server, so those hits are absent from anything your server can report."}
    ]
  end
end
