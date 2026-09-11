defmodule WebAnalytics.Crawlers.Providers.Anthropic do
  @moduledoc "Content for the Claude Bot analytics page."

  alias WebAnalytics.Crawlers.Provider

  def provider do
    %Provider{
      slug: "claude-bot",
      name: "Claude Bot",
      vendor: "Anthropic",
      keyword: "Claude Bot Analytics",
      description:
        "Claude Bot Analytics — free analytics for Claude Bot. See every page ClaudeBot, " <>
          "Claude-User and Claude-SearchBot take from your site, how often, and what it means.",
      lede:
        "Anthropic's crawlers are almost certainly reading your site right now, and almost " <>
          "certainly none of it shows up in your analytics. Claude Bot Analytics is the part " <>
          "of SeriouslySimpleAnalytics that names them, counts them, and shows you which of " <>
          "your pages are actually being taken. It is free, it takes one script tag, and you " <>
          "can self-host the whole thing.",
      agents: [
        %{
          token: "ClaudeBot",
          robots: "ClaudeBot",
          purpose: "Broad crawling. The one most people mean by \"Claude Bot\".",
          example: "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
        },
        %{
          token: "Claude-User",
          robots: "Claude-User",
          purpose: "A fetch made because a person asked Claude about your page.",
          example: "Mozilla/5.0 (compatible; Claude-User/1.0; +Claude-User@anthropic.com)"
        },
        %{
          token: "Claude-SearchBot",
          robots: "Claude-SearchBot",
          purpose: "Indexing so your pages can be surfaced in Claude's search results.",
          example:
            "Mozilla/5.0 (compatible; Claude-SearchBot/1.0; +Claude-SearchBot@anthropic.com)"
        },
        %{
          token: "Claude-Web",
          robots: "Claude-Web",
          purpose: "An older token, still seen in logs. Recognised for completeness.",
          example: "Mozilla/5.0 (compatible; Claude-Web/1.0)"
        },
        %{
          token: "anthropic-ai",
          robots: "anthropic-ai",
          purpose: "Legacy identifier from earlier crawls. Rare now, still matched.",
          example: "anthropic-ai"
        }
      ],
      robots_tokens: ~w(ClaudeBot Claude-User Claude-SearchBot Claude-Web anthropic-ai),
      facts: [
        {"Vendor", "Anthropic"},
        {"Primary user agent", "ClaudeBot"},
        {"Kind", "AI crawler"},
        {"Respects robots.txt", "Yes, by published policy"},
        {"Renders JavaScript", "No"},
        {"Counted in your human traffic", "No — reported separately"},
        {"Cost to track it here", "Free"}
      ],
      sections: sections(),
      faq: faq(),
      related_note:
        "Anthropic is one of several providers crawling for model training and retrieval. " <>
          "The same report covers all of them."
    }
  end

  defp sections do
    [
      %{
        id: "what-it-is",
        heading: "What Claude Bot is, and why it is on your site",
        body: [
          {:p,
           "Claude Bot is the informal name for the family of crawlers Anthropic operates in " <>
             "support of Claude. They are ordinary HTTP clients: they request a URL, read the " <>
             "HTML that comes back, and move on. They do not run your JavaScript, they do not " <>
             "accept cookies, and they do not click anything. What separates them from a " <>
             "search engine crawler is not how they fetch but what the fetch is for."},
          {:p,
           "There are three distinct reasons a request from Anthropic arrives, and conflating " <>
             "them is the most common mistake site owners make. ClaudeBot crawls broadly. " <>
             "Claude-User fetches a specific page because a person in a Claude conversation " <>
             "asked about it — that request exists because a human wanted your page, right " <>
             "then. Claude-SearchBot builds an index so your pages can be surfaced when " <>
             "someone searches inside Claude. Those are three different relationships with " <>
             "your site, and a policy that treats them identically is a policy you have not " <>
             "thought about."},
          {:p,
           "The practical consequence is that \"should I allow Claude Bot?\" is not one " <>
             "question. Blocking ClaudeBot and allowing Claude-User is a coherent position: no " <>
             "bulk collection, but a person who asks Claude about your article still gets your " <>
             "article. Blocking everything is also coherent. What is not coherent is making " <>
             "the decision without knowing which of the three is actually hitting you and how " <>
             "much, which is what this page exists to fix."},
          {:p,
           "Claude Bot Analytics answers that directly. It separates each agent by name, shows " <>
             "you the pages each one took, and puts the whole thing on a timeline so you can " <>
             "see when a crawl started, how long it ran, and whether it has come back."}
        ]
      },
      %{
        id: "user-agents",
        heading: "The exact user agents to look for",
        body: [
          {:p,
           "Every Anthropic crawler identifies itself in the User-Agent header and includes a " <>
             "contact address. This is the deliberate opposite of a scraper trying to blend in, " <>
             "and it is what makes reliable detection possible in the first place. These are " <>
             "the strings SeriouslySimpleAnalytics matches on:"},
          {:agents, nil},
          {:p,
           "Matching is case-insensitive and looks for the token anywhere in the header, " <>
             "because minor version strings change without warning and a detector pinned to " <>
             "ClaudeBot/1.0 silently stops working the day ClaudeBot/1.1 ships. Matching is " <>
             "also ordered most-specific-first, so Claude-SearchBot is never swallowed by a " <>
             "generic \"anything containing bot\" rule."},
          {:p,
           "If you are grepping your own access logs rather than using a tool, the pattern you " <>
             "want is a case-insensitive search for Claude — it catches all five tokens at " <>
             "once and almost nothing else. Anthropic is unusual in how consistently it brands " <>
             "its agents, which makes this considerably easier than the equivalent exercise for " <>
             "some other providers."}
        ]
      },
      %{
        id: "invisible",
        heading: "Why your current analytics shows you none of this",
        body: [
          {:p,
           "Nearly every analytics product in common use works the same way: a JavaScript " <>
             "snippet runs in a browser and reports back. That design decides, before you " <>
             "configure anything, that only visitors who execute JavaScript exist. ClaudeBot " <>
             "does not execute JavaScript. Neither does GPTBot, or CCBot, or most of the " <>
             "others. So they are not filtered out of your reports — they were never in them."},
          {:p,
           "This produces a peculiar blind spot. Your server is doing real work, serving real " <>
             "bandwidth, to a client whose interest in your content is arguably higher than " <>
             "the average human visitor's, and your analytics reports a quiet day. Meanwhile " <>
             "the one place the traffic is visible — raw access logs — is the place nobody " <>
             "looks, because reading them means either grep or a log pipeline that costs more " <>
             "than the question is worth."},
          {:p,
           "SeriouslySimpleAnalytics closes the gap by classifying on the server side, at " <>
             "ingest, from the request itself. A crawler that never runs the tracker script is " <>
             "still a request your server handled, and that request carries a User-Agent header " <>
             "saying exactly who it is. The classification happens there, which is why it works " <>
             "for clients that will never run a line of your JavaScript."},
          {:p,
           "The second half of the fix is not mixing the two populations. A crawler is not a " <>
             "visitor, and averaging them produces numbers that describe nobody: a bounce rate " <>
             "polluted by a bot that fetched one page and left, a session count inflated by " <>
             "something that has no sessions. Crawler traffic here is a dimension of its own, " <>
             "filtered out of the human reports by default and given a report of its own."}
        ]
      },
      %{
        id: "detection",
        heading: "How SeriouslySimpleAnalytics identifies Claude Bot",
        body: [
          {:p,
           "Detection runs at ingest, before anything is written. Each request's User-Agent is " <>
             "tested against an ordered list of patterns, most specific first, and the first " <>
             "match assigns both a name and a kind. Claude Bot's kind is \"AI crawler\", which " <>
             "is the same bucket as GPTBot and PerplexityBot and a different bucket from " <>
             "Googlebot, Ahrefs, or a Slack link unfurler."},
          {:p,
           "That ordering matters more than it sounds. A naive detector that looks for the " <>
             "substring \"bot\" first would file Claude-SearchBot as an unclassified bot and " <>
             "you would never see it by name. A detector that checks Applebot before " <>
             "Applebot-Extended makes the same mistake in the other direction and reports an " <>
             "AI training crawler as a search engine. The specific-first ordering is the whole " <>
             "trick, and it is why the classifier is a single ordered list rather than a set of " <>
             "independent rules."},
          {:p,
           "The kind is also what drives the rest of the system's behaviour. Anything " <>
             "classified as automated is sampled at ten-second resolution instead of the " <>
             "one-second resolution used for humans, and is excluded from the default reports. " <>
             "Nothing is deleted — the toggle to include crawlers is one click, and the crawler " <>
             "report is always fully populated regardless of where that toggle sits."},
          {:p,
           "Because the classifier is open source, you can read exactly what it matches. There " <>
             "is no vendor list you cannot inspect and no proprietary score. If Anthropic ships " <>
             "a new agent tomorrow, the change needed is one line, and you can make it yourself " <>
             "on your own deployment without waiting for anybody."}
        ]
      },
      %{
        id: "metrics",
        heading: "What the Claude Bot report actually gives you",
        body: [
          {:p,
           "The crawler report answers the questions people actually have about an AI crawler, " <>
             "rather than reusing the human metrics and hoping they mean something."},
          {:ul,
           [
             "Requests by agent — ClaudeBot, Claude-User and Claude-SearchBot counted separately, not merged into one \"Anthropic\" number that hides which relationship you have.",
             "Pages taken — the full list of URLs each agent fetched, ranked. This is the single most useful view on the page: it tells you what Claude considers worth having from your site.",
             "First seen and last seen — when this agent first appeared and whether it is still coming back.",
             "Crawl shape over time — requests bucketed over your selected range, so a bulk crawl looks obviously different from steady background retrieval.",
             "Kind breakdown — AI crawlers against search engines, SEO tools, link unfurlers, monitors and plain HTTP clients, so you can see what share of your server's work is AI-related at all.",
             "Everything else, still separated — your human numbers stay clean while all of the above is available beside them."
           ]},
          {:p,
           "The pages-taken list deserves particular attention. A search crawler visits broadly " <>
             "because it is building an index of everything. An AI crawler's page list is more " <>
             "revealing: repeated, concentrated fetching of a specific section of your site is " <>
             "a signal about which of your content is considered valuable. People discover " <>
             "surprising things here — documentation pages crawled far more heavily than " <>
             "marketing pages, old reference posts pulled repeatedly while new announcements " <>
             "are ignored."}
        ]
      },
      %{
        id: "reading",
        heading: "Reading a Claude Bot crawl: what the patterns mean",
        body: [
          {:p,
           "Once you can see the traffic, the next question is what to make of it. A few " <>
             "patterns recur often enough to be worth naming."},
          {:h3, "A burst, then silence"},
          {:p,
           "A large number of requests concentrated into a short window, covering a wide spread " <>
             "of URLs, then nothing for weeks. This is bulk crawling. It is the pattern most " <>
             "people mean when they worry about training data. It costs you bandwidth in a lump " <>
             "and then costs you nothing."},
          {:h3, "A thin, steady trickle"},
          {:p,
           "A handful of requests a day, landing on different pages each time, often deep pages " <>
             "rather than your home page. If these are Claude-User, each one is a person who " <>
             "asked Claude about that specific page. This is the most valuable traffic on the " <>
             "report and the one most likely to be mistaken for noise because the volume is so " <>
             "low. Low volume, high intent."},
          {:h3, "Repeated fetching of the same few URLs"},
          {:p,
           "The same pages, over and over, at intervals. Usually a sign those pages are being " <>
             "kept fresh in an index or are being cited frequently. Whatever else is true, " <>
             "those URLs are the ones Claude keeps coming back for — which makes them worth " <>
             "knowing about whether your reaction is to promote them or to protect them."},
          {:h3, "A crawl that starts right after you publish"},
          {:p,
           "Fast arrival after new content goes up means something is watching a feed or a " <>
             "sitemap. This is worth noticing because it tells you your publishing is visible, " <>
             "and it gives you a rough latency figure for how quickly new work becomes " <>
             "reachable through Claude."},
          {:p,
           "None of these patterns is good or bad on its own. They are inputs to a decision " <>
             "that is yours: a documentation site may be delighted to be crawled thoroughly, " <>
             "while a site whose entire business is people arriving on the page may feel " <>
             "differently. The point of measuring is that the decision stops being a guess."}
        ]
      },
      %{
        id: "rate",
        heading: "Crawl rate, and why crawler dwell time is sampled at ten seconds",
        body: [
          {:p,
           "The browser tracker beacons once a second for the first several minutes of a human " <>
             "visit, which is what makes dwell time and engaged time meaningful at that " <>
             "resolution. Applying the same cadence to automated traffic would be a mistake, " <>
             "and a fairly expensive one."},
          {:p,
           "Automated traffic arrives in volumes humans do not produce. A crawl that fetches " <>
             "thousands of pages in a few minutes, each generating per-second telemetry, is a " <>
             "denial of service you have built against yourself. So anything classified as " <>
             "automated is sampled at ten-second resolution instead. The collector stays cheap " <>
             "under a heavy crawl, and nothing about the crawler report gets worse — you still " <>
             "get every request, every URL and every agent. What you lose is sub-ten-second " <>
             "dwell precision on a client that does not dwell, does not scroll, and does not " <>
             "read."},
          {:p,
           "The distinction is applied by classification, not by volume, so it is predictable. " <>
             "A recognised crawler is sampled at ten seconds from its first request, before it " <>
             "has had a chance to generate any load at all. Nothing has to trip a threshold and " <>
             "no human ever gets downgraded for browsing quickly."},
          {:p,
           "On crawl rate itself: Anthropic's crawlers are generally well-behaved and back off " <>
             "under pressure, but the definitive answer for your site is on your own report. If " <>
             "a crawl is genuinely too aggressive for your infrastructure, robots.txt " <>
             "Crawl-delay and rate limiting at your edge are the levers, and the report tells " <>
             "you whether pulling them actually changed anything."}
        ]
      },
      %{
        id: "verify",
        heading: "Verifying that it is really Anthropic",
        body: [
          {:p,
           "A User-Agent header is a claim, not a credential. Anyone can send " <>
             "\"ClaudeBot/1.0\" and some people do — occasionally to slip past a rule that " <>
             "allows it, occasionally just because a script copied the string from a blog post. " <>
             "If you are about to make a serving decision based on identity, verify it rather " <>
             "than trusting the header."},
          {:p,
           "The general method is the same one used for search engines and it does not depend " <>
             "on any vendor cooperating beyond publishing their infrastructure. Take the source " <>
             "address of the request. Do a reverse DNS lookup on it. Confirm the hostname you " <>
             "get back belongs to the domain the crawler claims. Then do a forward lookup on " <>
             "that hostname and confirm it resolves back to the original address. Both " <>
             "directions have to agree, because reverse DNS alone can be set to whatever the " <>
             "address owner likes."},
          {:p,
           "Anthropic also publishes the address ranges its crawlers operate from, which is the " <>
             "faster check if you are doing this at your edge rather than per request: pull the " <>
             "current list from Anthropic's own documentation, keep it fresh, and match against " <>
             "it. Treat any published list as something that changes, and re-fetch it on a " <>
             "schedule rather than pasting it into a config file once."},
          {:p,
           "SeriouslySimpleAnalytics reports what the header said, deliberately. It is an " <>
             "analytics tool, not an access control system, and quietly dropping requests whose " <>
             "identity it doubted would make the numbers less trustworthy rather than more. " <>
             "Verification belongs at the layer that makes serving decisions — your CDN, your " <>
             "reverse proxy, your firewall — and what you get here is the measurement that " <>
             "tells you whether that layer needs a rule at all."}
        ]
      },
      %{
        id: "robots",
        heading: "Controlling Claude Bot with robots.txt",
        body: [
          {:p,
           "Anthropic's stated policy is that its crawlers obey robots.txt. Rules are matched " <>
             "against the tokens above, and each agent is addressed separately — which is what " <>
             "makes the three-way distinction actionable rather than academic."},
          {:h3, "Allow everything (the default if you do nothing)"},
          {:code, "User-agent: ClaudeBot\nAllow: /"},
          {:h3, "Block bulk crawling, keep user-initiated fetches"},
          {:p,
           "This is the position many publishers land on. No bulk collection, but a person who " <>
             "asks Claude about one of your pages still gets it, and you still get the referral " <>
             "when Claude cites you."},
          {:code,
           "User-agent: ClaudeBot\nDisallow: /\n\nUser-agent: Claude-User\nAllow: /\n\nUser-agent: Claude-SearchBot\nAllow: /"},
          {:h3, "Block everything from Anthropic"},
          {:code,
           "User-agent: ClaudeBot\nDisallow: /\n\nUser-agent: Claude-User\nDisallow: /\n\nUser-agent: Claude-SearchBot\nDisallow: /\n\nUser-agent: Claude-Web\nDisallow: /\n\nUser-agent: anthropic-ai\nDisallow: /"},
          {:h3, "Protect one section, allow the rest"},
          {:code, "User-agent: ClaudeBot\nDisallow: /members/\nDisallow: /pricing/\nAllow: /"},
          {:note,
           "robots.txt is a request, not a control. It works because reputable crawlers choose " <>
             "to honour it. Anything you genuinely need to keep out belongs behind " <>
             "authentication, not behind a Disallow line."},
          {:p,
           "Whichever rule you write, the report is how you find out whether it worked. Note " <>
             "the date you changed robots.txt, then watch the agent's request count over the " <>
             "following days. Crawlers cache robots.txt for a while, so give it time — but if " <>
             "requests are unchanged a week later, either the rule has a typo or the client is " <>
             "not the one it says it is, and both are worth knowing."}
        ]
      },
      %{
        id: "decide",
        heading: "Should you block Claude Bot? The honest trade-off",
        body: [
          {:p,
           "This page is published by an analytics tool, so take the following in that spirit: " <>
             "we have no stake in which way you go, and anyone who tells you the answer is " <>
             "obvious in either direction is selling something."},
          {:h3, "The case for allowing it"},
          {:p,
           "Claude increasingly cites and links its sources, and a citation is a referral from " <>
             "somewhere your competitors may not be. For documentation, reference material, " <>
             "open source projects and technical writing, being the thing a model reaches for " <>
             "is closer to distribution than to theft. Blocking also does not un-train anything " <>
             "already learned; it only affects what happens next. And blocking Claude-User " <>
             "specifically means a person who explicitly asked about your page does not get it, " <>
             "which is a strange thing to do to someone who was, by any reasonable reading, " <>
             "trying to read your site."},
          {:h3, "The case for blocking it"},
          {:p,
           "If your business depends on people arriving on your pages — advertising, " <>
             "subscriptions, anything measured in sessions — then an answer that satisfies " <>
             "someone without a visit is a lost visit. If your content is your product rather " <>
             "than marketing for your product, bulk collection is a straightforward transfer of " <>
             "value away from you. And at real scale the bandwidth is a bill, even if it is a " <>
             "small one."},
          {:h3, "The middle, which is where most people end up"},
          {:p,
           "Block bulk crawling, allow user-initiated fetches, and keep the sections that " <>
             "matter commercially behind a Disallow or behind a login. That gets you out of " <>
             "wholesale collection while keeping the referrals from people who genuinely wanted " <>
             "your page. It is not a fence-sit; it is a distinction the protocol explicitly " <>
             "supports."},
          {:p,
           "What makes any of these a decision rather than a guess is the measurement " <>
             "underneath. Look at your own numbers first: which agent, how much, which pages. " <>
             "A site taking forty requests a month has a different problem from one taking " <>
             "forty thousand, and they should not reach the same conclusion."}
        ]
      },
      %{
        id: "llms-txt",
        heading: "llms.txt, AGENTS.md, and being legible to models",
        body: [
          {:p,
           "robots.txt says what a crawler may take. It says nothing about what your site is " <>
             "or which parts of it are worth reading. llms.txt is the emerging convention for " <>
             "the second question: a plain-text file at the root of your site, written for a " <>
             "model rather than a browser, describing what you offer and pointing at the pages " <>
             "that matter."},
          {:p,
           "It is not a standard in any formal sense and no crawler is obliged to read it. It " <>
             "costs an afternoon to write, and the downside of having one is essentially zero, " <>
             "which is a ratio that does not come up often. If you publish documentation or an " <>
             "API, it is the cheapest thing on this page."},
          {:p,
           "We have a direct interest here, so we will be plain about it: SeriouslySimpleAnalytics " <>
             "publishes its own llms.txt describing its whole event API, precisely so that a " <>
             "coding agent can integrate with us without a human reading documentation. It " <>
             "works. That is the argument for writing one, and it is an argument from our own " <>
             "traffic rather than from theory."},
          {:p,
           "AGENTS.md is the same idea aimed at repositories rather than websites: a file " <>
             "telling a coding agent how to work in your codebase. If you ship a library, it is " <>
             "worth having for the same reason. Neither file changes what a crawler is allowed " <>
             "to take. Both change how well it understands what it took."}
        ]
      },
      %{
        id: "referrals",
        heading: "Traffic coming back from Claude",
        body: [
          {:p,
           "Crawling and referral are two halves of the same relationship, and it is worth " <>
             "watching both. When Claude cites your page and a person clicks through, that " <>
             "person is a human visitor with a referrer — ordinary traffic, visible in the " <>
             "ordinary reports, not in the crawler report."},
          {:p,
           "The referrer breakdown is where you see it, and the shape of that traffic tends to " <>
             "be distinctive: lower volume than search, but often noticeably more engaged, " <>
             "because someone arriving from a cited answer has already been told roughly what " <>
             "your page contains and came anyway. Engaged time and scroll depth are the metrics " <>
             "that make this visible, and both are captured by default."},
          {:p,
           "Watching the two together is what turns the block-or-allow question into something " <>
             "empirical. If crawling is heavy and referrals are zero, you are subsidising " <>
             "something that gives nothing back, and that is a reasonable basis for a Disallow. " <>
             "If referrals are real and growing, blocking the crawl may cost you the referrals " <>
             "too. Nobody can tell you which case you are in from the outside — it is in your " <>
             "own numbers, which is the entire argument for having them."}
        ]
      },
      %{
        id: "compare",
        heading: "Claude Bot compared with the other AI crawlers",
        body: [
          {:p,
           "Anthropic is one of several organisations crawling for model training and " <>
             "retrieval, and they differ in ways that matter when you write rules."},
          {:ul,
           [
             "OpenAI splits its crawlers three ways too — GPTBot, ChatGPT-User and OAI-SearchBot — and publishes address ranges for each. The distinctions map closely onto Anthropic's.",
             "Perplexity runs PerplexityBot for indexing and Perplexity-User for fetches a person triggered, and is built around citing sources, so referrals are a larger part of the relationship.",
             "Google-Extended is not a crawler at all. It is a robots.txt token that controls whether content Googlebot already fetched may be used for Gemini. Blocking it does not reduce a single request.",
             "Applebot-Extended works the same way: a permission token layered on top of Applebot, not a separate client.",
             "Meta-ExternalAgent, Bytespider, Amazonbot and CCBot are conventional crawlers with their own agents, varying considerably in volume and in how much they honour.",
             "CCBot is Common Crawl, a non-profit whose archive many other organisations then train on. Allowing CCBot has a wider blast radius than allowing any single vendor."
           ]},
          {:p,
           "The important consequence is that a single blanket rule aimed at \"AI crawlers\" " <>
             "will be wrong in both directions: it will fail to stop the things that are not " <>
             "crawlers, and it will stop things you might have wanted. Per-agent measurement " <>
             "first, per-agent rules second."}
        ]
      },
      %{
        id: "cost",
        heading: "What a Claude Bot crawl actually costs you",
        body: [
          {:p,
           "Bandwidth is the cost people name first and it is usually the smallest one. A " <>
             "crawler fetching HTML does not pull your images, your fonts, your video or your " <>
             "JavaScript bundles, because it does not render the page. The bytes it takes are " <>
             "the cheapest bytes you serve, and for most sites the whole crawl rounds to " <>
             "nothing against a single day of human traffic."},
          {:p,
           "Origin load is the cost that actually bites, and only in a specific case: a site " <>
             "where each page is generated on demand by an application server hitting a " <>
             "database. A broad crawl walks every URL you have, including the deep, rarely " <>
             "requested pages that are never warm in any cache, so it is close to a worst case " <>
             "for a dynamic site. If a crawl has ever made your dashboards twitch, this is " <>
             "almost always why, and the fix is caching at the edge rather than a Disallow line."},
          {:p,
           "There is a third cost that is real but harder to put a number on: the pages you did " <>
             "not want indexed being indexed. Staging environments left publicly reachable, " <>
             "print views, faceted search URLs that multiply into thousands of near-identical " <>
             "pages, old campaign landing pages you forgot about. A crawler finds all of them, " <>
             "because finding all of them is the job. Seeing the pages-taken list is frequently " <>
             "the moment a site owner discovers what is actually reachable on their own domain."},
          {:p,
           "Measure before you optimise. The report gives you request counts by agent over " <>
             "time, so the question \"is this costing me anything\" has an answer rather than a " <>
             "feeling attached to it. For a large majority of sites the honest answer is no, " <>
             "and the effort is better spent on the pages-taken list than on the bandwidth " <>
             "figure."}
        ]
      },
      %{
        id: "first-week",
        heading: "A first week with Claude Bot Analytics",
        body: [
          {:p,
           "If you have just added the script tag, here is the order worth doing things in. " <>
             "None of it takes long and each step tends to produce a surprise."},
          {:ol,
           [
             "Day one, open the crawlers tab and look at the kind breakdown. Most people are surprised by how much of their server's work is automated traffic of some sort, well beyond AI crawlers.",
             "Find Claude Bot in the list and check which agent is actually hitting you. ClaudeBot and Claude-User mean different things and the ratio between them is the single most informative number on the page.",
             "Read the pages-taken list carefully. Look for pages you did not know were public, faceted URLs multiplying, and old content you had forgotten. This is the step that most often turns into actual work.",
             "Check your referrer report for traffic arriving from Claude. Crawling and referral are two halves of one relationship, and you cannot judge the first without the second.",
             "Only now decide whether you want a robots.txt rule. If you write one, note the date, and check the same report a week later to confirm it did what you expected."
           ]},
          {:p,
           "The pattern underneath all of this: measure, then decide, then verify the decision " <>
             "took effect. It is unremarkable advice everywhere else in engineering and is " <>
             "strangely rare in discussions about AI crawlers, which tend to go straight from " <>
             "an opinion to a robots.txt file without any numbers in between."}
        ]
      },
      %{
        id: "setup",
        heading: "Setting up Claude Bot Analytics",
        body: [
          {:p,
           "Three steps, and the third is optional. There is no plan to choose, no trial, and " <>
             "no card."},
          {:ol,
           [
             "Create a free account. You get an account ID immediately — it is on your dashboard the moment you sign in.",
             "Paste the script tag into the head of your pages. That is the whole integration; there is nothing to configure and no tagging plan to design.",
             "Open the crawlers tab. Claude Bot traffic appears as it arrives, named and separated from your human numbers."
           ]},
          {:p,
           "If you also build AI tools — an agent, an MCP server, a CLI, an extension — the " <>
             "same account tracks those by fetching a single URL, with no SDK and nothing added " <>
             "to your dependency tree. Crawler analytics and your own tool's telemetry land in " <>
             "the same dashboard, which is more useful than it sounds the first time you notice " <>
             "a crawl and a usage spike lining up."},
          {:p,
           "Everything described on this page is in the free tier, because there is only a free " <>
             "tier. The project is open source and can be self-hosted against your own Postgres " <>
             "if you would rather no third party sat in the path at all."}
        ]
      },
      %{
        id: "privacy",
        heading: "Privacy, self-hosting, and what we keep",
        body: [
          {:p,
           "Crawler analytics is the least privacy-sensitive thing a tracker does — a bot is " <>
             "not a person — but the same rules apply to everything here, so they are worth " <>
             "stating."},
          {:ul,
           [
             "No cookies. Identifiers live in browser storage, so there is no consent banner to show.",
             "No IP addresses stored. An address is used in-request to resolve a location, then salted, hashed and discarded, and the salt rotates daily.",
             "Password fields are masked in the browser and dropped again server-side, so a stale snippet cannot defeat it.",
             "data-wa-ignore on any element, form or field excludes it entirely.",
             "Self-host it and none of the above requires trusting us, because we are not in the path."
           ]},
          {:p,
           "The source is public and the detection rules are a readable list in a single file. " <>
             "If you want to know exactly what is classified as Claude Bot, you can read the " <>
             "line that does it rather than taking our word for it."}
        ]
      }
    ]
  end

  defp faq do
    [
      {"What is Claude Bot?",
       "Claude Bot is the informal name for the crawlers Anthropic operates for Claude. In " <>
         "practice it is three distinct agents: ClaudeBot, which crawls broadly; Claude-User, " <>
         "which fetches a page because a person asked Claude about it; and Claude-SearchBot, " <>
         "which indexes pages so they can be surfaced in Claude's search."},
      {"What is the ClaudeBot user agent string?",
       "ClaudeBot identifies itself with a User-Agent containing the token ClaudeBot along " <>
         "with a contact address, in the form " <>
         "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com). Match on the " <>
         "token case-insensitively rather than on the full string, because version numbers " <>
         "change."},
      {"Why doesn't Google Analytics show Claude Bot?",
       "Because JavaScript-based analytics only records visitors that execute JavaScript, and " <>
         "ClaudeBot does not. The traffic is real and your server handled it, but the tracker " <>
         "never ran, so it was never recorded. Detection has to happen server-side, at ingest, " <>
         "from the request itself."},
      {"Does Claude Bot respect robots.txt?",
       "Anthropic's published policy is that its crawlers obey robots.txt, and each agent can " <>
         "be addressed separately by name. Whether a rule you wrote actually took effect is an " <>
         "empirical question — write the rule, note the date, and watch that agent's request " <>
         "count over the following week."},
      {"How do I block Claude Bot?",
       "Add a Disallow rule for each agent you want to stop. Blocking ClaudeBot while allowing " <>
         "Claude-User is a common and coherent choice: no bulk collection, but a person who " <>
         "asks Claude about your page still gets it. Anything you genuinely must keep out " <>
         "belongs behind authentication rather than behind robots.txt."},
      {"Should I block Claude Bot?",
       "It depends on what your content is for. If it is documentation, reference material or " <>
         "technical writing, being cited is closer to distribution than to loss. If your " <>
         "business is measured in sessions, an answer that satisfies someone without a visit " <>
         "costs you. Look at your own crawl volume and referral traffic before deciding — the " <>
         "right answer for a site taking forty requests a month is not the right answer for one " <>
         "taking forty thousand."},
      {"Does blocking ClaudeBot remove my content from Claude?",
       "No. A Disallow affects future crawling, not anything already collected, and it does " <>
         "not reach into a trained model. What it does change is what happens from now on."},
      {"How can I verify a request really came from Anthropic?",
       "Do a reverse DNS lookup on the source address, confirm the hostname belongs to the " <>
         "domain claimed, then do a forward lookup on that hostname and confirm it resolves " <>
         "back to the original address. Both directions must agree. Anthropic also publishes " <>
         "its crawler address ranges, which is faster if you are checking at your edge."},
      {"Is Claude Bot Analytics free?",
       "Yes, entirely. There is no paid tier, no event quota and no sampling above some traffic " <>
         "threshold. The project is also open source, so you can run the whole thing on your " <>
         "own server against your own Postgres if you prefer."},
      {"Will crawler traffic distort my human analytics?",
       "No. Anything classified as automated is excluded from the ordinary reports by default " <>
         "and given a report of its own, so your visitor counts, bounce rates and session " <>
         "numbers describe people. Nothing is deleted — including crawlers is a single toggle, " <>
         "and the crawler report is fully populated either way."},
      {"Why is crawler dwell time sampled every ten seconds instead of every second?",
       "Because automated traffic arrives in volumes humans do not produce, and per-second " <>
         "telemetry across a large crawl would be a denial of service you built against " <>
         "yourself. Sub-ten-second precision is meaningless for a client that does not read, " <>
         "scroll or linger, so nothing useful is lost."},
      {"Can I see which specific pages Claude Bot took?",
       "Yes — the full ranked list of URLs per agent is the most useful view on the report. It " <>
         "tells you which of your content is actually being taken, which is frequently not the " <>
         "content you would have guessed."},
      {"Does this work if my site is server-rendered, static, or behind a CDN?",
       "Yes. Detection happens from the request that reaches your application, so the rendering " <>
         "model does not matter. Behind a CDN, make sure the original client address is " <>
         "forwarded, or every request will appear to come from your edge."},
      {"What about the other AI crawlers?",
       "The same report covers GPTBot, PerplexityBot, Bytespider, CCBot, Amazonbot, " <>
         "Meta-ExternalAgent and the rest, each named individually. There is a page for each " <>
         "major provider explaining what its crawlers do and how to control them."}
    ]
  end
end
