defmodule WebAnalytics.Crawlers.Providers.OpenAI do
  @moduledoc "Content for the GPTBot analytics page."

  alias WebAnalytics.Crawlers.Provider

  def provider do
    %Provider{
      slug: "gptbot",
      name: "GPTBot",
      vendor: "OpenAI",
      keyword: "GPTBot Analytics",
      description:
        "GPTBot Analytics — free analytics for GPTBot. See every page GPTBot, ChatGPT-User " <>
          "and OAI-SearchBot take from your site, how often, and which robots.txt rule " <>
          "actually controls each one.",
      lede:
        "OpenAI runs three separate crawlers and they do three different things. Most site " <>
          "owners have one robots.txt rule covering one of them and no idea what the other " <>
          "two are doing. GPTBot Analytics names all three, counts them separately, and shows " <>
          "you the pages each one is taking. Free, one script tag, self-hostable.",
      agents: [
        %{
          token: "GPTBot",
          robots: "GPTBot",
          purpose: "Broad crawling, used to gather content for model training.",
          example:
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.2; +https://openai.com/gptbot"
        },
        %{
          token: "ChatGPT-User",
          robots: "ChatGPT-User",
          purpose:
            "A live fetch, made because a person in ChatGPT asked something that needed your page.",
          example:
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
        },
        %{
          token: "OAI-SearchBot",
          robots: "OAI-SearchBot",
          purpose: "Indexing for ChatGPT search results. Not used for training.",
          example: "Mozilla/5.0 (compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot)"
        }
      ],
      robots_tokens: ~w(GPTBot ChatGPT-User OAI-SearchBot),
      facts: [
        {"Vendor", "OpenAI"},
        {"Crawlers", "Three, controlled separately"},
        {"Kind", "AI crawler"},
        {"Respects robots.txt", "Yes, by published policy"},
        {"Renders JavaScript", "No"},
        {"Publishes IP ranges", "Yes, per crawler, as JSON"},
        {"Cost to track it here", "Free"}
      ],
      sections: sections(),
      faq: faq(),
      related_note:
        "OpenAI's three-way split has close equivalents at Anthropic and Perplexity, and no " <>
          "equivalent at all at Google or Apple. The same report covers all of them."
    }
  end

  defp sections do
    [
      %{
        id: "three-crawlers",
        heading: "GPTBot is one of three, and the difference matters",
        body: [
          {:p,
           "Almost every discussion of GPTBot treats it as a single thing to allow or block. " <>
             "It is not. OpenAI operates three crawlers with three separate robots.txt tokens, " <>
             "and the most common configuration mistake on the web right now is a rule that " <>
             "blocks one of them while its author believes they have blocked all three."},
          {:p,
           "GPTBot crawls broadly and the content it collects may be used to train models. " <>
             "This is the one people mean. ChatGPT-User is entirely different: it fires when a " <>
             "person in a ChatGPT conversation asks something that requires reading your page " <>
             "right now. There is a human at the other end of that request, waiting. " <>
             "OAI-SearchBot builds the index behind ChatGPT's search results, and OpenAI " <>
             "states that what it gathers is not used for training."},
          {:p,
           "Read that list again with your own site in mind and the block-everything position " <>
             "starts to look less obvious. Blocking GPTBot stops bulk collection. Blocking " <>
             "ChatGPT-User means a person who explicitly asked about your page does not get it. " <>
             "Blocking OAI-SearchBot removes you from a search surface without preventing a " <>
             "single byte of training, because that crawler was not doing training in the first " <>
             "place."},
          {:p,
           "This page exists because you cannot reason about any of that without numbers. " <>
             "GPTBot Analytics separates the three agents, counts each one, and lists the pages " <>
             "each is actually taking, so the rule you write afterwards is a response to your " <>
             "traffic rather than to a headline."}
        ]
      },
      %{
        id: "user-agents",
        heading: "The exact GPTBot user agent strings",
        body: [
          {:p,
           "All three identify themselves clearly and include a URL pointing at OpenAI's own " <>
             "documentation. These are the tokens SeriouslySimpleAnalytics matches:"},
          {:agents, nil},
          {:p,
           "Match on the token, case-insensitively, anywhere in the header. Do not match the " <>
             "whole string: GPTBot's version has moved through 1.0, 1.1 and 1.2 and a detector " <>
             "pinned to a version stops working silently at the next bump — the worst kind of " <>
             "failure, because your report simply goes quiet and looks like good news."},
          {:p,
           "One trap worth knowing about if you are writing your own matcher: GPTBot's header " <>
             "opens with a Mozilla and AppleWebKit prefix that looks like a real browser. A " <>
             "naive rule that treats \"AppleWebKit\" as evidence of a human will file GPTBot as " <>
             "a visitor. Match the specific token first and let the browser-shaped prefix be " <>
             "what it is, decoration."},
          {:p,
           "If you are grepping access logs directly, searching case-insensitively for " <>
             "\"gptbot\", \"chatgpt-user\" and \"oai-search\" separately is the reliable " <>
             "approach. A single search for \"openai\" catches the URLs in the headers too, " <>
             "which works but merges the three agents back into one number — precisely the " <>
             "thing worth avoiding."}
        ]
      },
      %{
        id: "invisible",
        heading: "Why GPTBot never appears in Google Analytics",
        body: [
          {:p,
           "Browser-based analytics records a visit when a JavaScript snippet runs in a " <>
             "browser. GPTBot does not run JavaScript. Neither does ChatGPT-User or " <>
             "OAI-SearchBot. The requests happen, your server does the work and serves the " <>
             "bytes, and the tracker is never invoked, so nothing is recorded. The traffic is " <>
             "not filtered out — it never entered the system."},
          {:p,
           "This is why the usual advice to \"check your bot filter settings\" is beside the " <>
             "point. There is nothing to unfilter. The only place a non-rendering crawler is " <>
             "visible at all is your own access log, because your origin is the only machine it " <>
             "ever spoke to."},
          {:p,
           "That is true of this tool as well, and worth saying plainly rather than leaving you " <>
             "to discover it. SeriouslySimpleAnalytics is a JavaScript tracker: it identifies " <>
             "automated clients that execute JavaScript — headless Chrome, Playwright, " <>
             "Lighthouse, monitoring agents, agent browsers that render before reading — and " <>
             "names them. GPTBot is not one of those. No hosted JavaScript analytics sees it, " <>
             "including ours."},
          {:p,
           "What closes the gap is reporting from the side that does see it. One request to the " <>
             "ping API per crawler hit, sent from your own server with `bot=` and the agent " <>
             "name, puts GPTBot, ChatGPT-User and OAI-SearchBot into the report below as they " <>
             "arrive — no SDK, no log shipping, and the access log stays on your box. Failing " <>
             "that, a case-insensitive grep for the three tokens answers the same question " <>
             "once, by hand."},
          {:p,
           "The second half is keeping the two populations apart. GPTBot fetching four thousand " <>
             "pages in an afternoon is real traffic, but folding it into your visitor numbers " <>
             "produces a report about nobody: sessions that are not sessions, a bounce rate " <>
             "describing a client that cannot bounce. Crawlers are a dimension of their own " <>
             "here, excluded from the human reports by default and given a report that is " <>
             "always fully populated regardless of that toggle."}
        ]
      },
      %{
        id: "detection",
        heading: "How GPTBot is identified",
        body: [
          {:p,
           "Whatever reaches ingest carries a user agent — sent by a client that rendered the " <>
             "page, or passed by your server when it reports a crawler hit — and that string is " <>
             "classified against an ordered list of patterns, most specific first. GPTBot, " <>
             "ChatGPT-User and OAI-SearchBot each have their own entry, each resolving to its " <>
             "own display name, all three filed under the kind \"AI crawler\"."},
          {:p,
           "Ordering is what makes the list correct rather than approximately correct. A " <>
             "catch-all rule matching anything containing \"bot\" would swallow OAI-SearchBot " <>
             "and report it as unclassified. Checking a generic search-engine pattern before " <>
             "the AI-specific ones would misfile training crawlers as search traffic. The " <>
             "specific-first ordering is the entire mechanism, which is why detection lives in " <>
             "one readable ordered list rather than a scattering of independent rules."},
          {:p,
           "The assigned kind then drives behaviour. Automated traffic is sampled at " <>
             "ten-second resolution rather than the one-second cadence used for humans, and is " <>
             "held out of the default reports. Nothing is discarded: the include-crawlers " <>
             "toggle is one click and the crawler report never depends on it."},
          {:p,
           "Because this is open source, the list is readable. You can see precisely what is " <>
             "classified as GPTBot, and if OpenAI ships a fourth agent you can add it yourself " <>
             "on your own deployment in one line rather than waiting for a vendor release."}
        ]
      },
      %{
        id: "metrics",
        heading: "What the GPTBot report gives you",
        body: [
          {:p,
           "The questions people have about an AI crawler are not the questions the human " <>
             "metrics answer, so the crawler report asks different ones."},
          {:ul,
           [
             "Requests per agent — GPTBot, ChatGPT-User and OAI-SearchBot counted separately, because merging them hides the only distinction that matters.",
             "Pages taken — the ranked list of URLs each agent fetched. The most useful view on the page, and usually the most surprising.",
             "First seen and last seen — when each agent showed up and whether it is still coming back.",
             "Shape over time — requests bucketed across your range, so a bulk crawl is visually obvious next to steady background retrieval.",
             "Kind breakdown — AI crawlers against search engines, SEO tools, unfurlers, monitors and plain HTTP clients, so you can see how much of your server's work is AI-related at all.",
             "Clean human numbers beside it — all of the above without any of it leaking into your visitor counts."
           ]},
          {:p,
           "The ChatGPT-User line is the one to watch most closely, and the one most likely to " <>
             "be dismissed because the volume is small. Each of those requests is a person who " <>
             "asked ChatGPT something your page answers. Ten of those a day is a different " <>
             "signal from ten thousand GPTBot requests a month, and the two should never have " <>
             "been in the same number."}
        ]
      },
      %{
        id: "reading",
        heading: "Reading GPTBot traffic: what the shapes mean",
        body: [
          {:p,
           "Each of the three agents produces a characteristic pattern, which makes them " <>
             "distinguishable on a timeline even before you read the labels."},
          {:h3, "GPTBot: broad and bursty"},
          {:p,
           "Large volumes over hours or days, spread wide across your URL space, then long " <>
             "silence. It is walking your site, not reading a page. If a crawl has ever shown " <>
             "up on your infrastructure dashboards, this is the shape that did it."},
          {:h3, "ChatGPT-User: thin, irregular, deep"},
          {:p,
           "A few requests a day at unpredictable times, landing on specific deep pages rather " <>
             "than your home page, with no pattern between them. That lack of pattern is the " <>
             "signature: these requests are driven by whatever individual people happened to " <>
             "ask. Low volume, high intent, and the best leading indicator you have that " <>
             "ChatGPT is sending people your way."},
          {:h3, "OAI-SearchBot: periodic and repetitive"},
          {:p,
           "Moderate volume, returning to the same pages at intervals, behaving much like a " <>
             "conventional search crawler because that is essentially what it is. Rising " <>
             "OAI-SearchBot activity on a set of pages generally means those pages are being " <>
             "kept fresh in an index."},
          {:h3, "A crawl that arrives minutes after you publish"},
          {:p,
           "Something is watching a sitemap or a feed. Useful to know, because it gives you a " <>
             "real latency figure for how quickly new work becomes reachable, and it confirms " <>
             "your sitemap is being read at all."},
          {:p,
           "Read the shapes before you write rules. A site seeing heavy GPTBot and no " <>
             "ChatGPT-User is in a genuinely different position from one seeing the reverse, " <>
             "and the same robots.txt file would be right for one and wrong for the other."}
        ]
      },
      %{
        id: "rate",
        heading: "Crawl volume and ten-second sampling",
        body: [
          {:p,
           "The browser tracker beacons once a second early in a human visit, which is what " <>
             "makes dwell and engaged time meaningful. Applying that cadence to a crawler would " <>
             "be an expensive mistake."},
          {:p,
           "GPTBot can fetch thousands of pages in a short window. Per-second telemetry across " <>
             "that is a self-inflicted denial of service, so anything classified as automated " <>
             "is sampled at ten seconds instead. The collector stays cheap under a heavy crawl " <>
             "and the crawler report loses nothing that matters: every request, every URL and " <>
             "every agent is still there. What is given up is sub-ten-second dwell precision on " <>
             "a client that does not dwell."},
          {:p,
           "The rule is applied by classification, not by volume, so it is predictable. A " <>
             "recognised crawler is sampled at ten seconds from its very first request, and no " <>
             "human is ever downgraded for browsing quickly. Nothing has to trip a threshold."},
          {:p,
           "If a GPTBot crawl is genuinely too much for your origin, the levers are " <>
             "Crawl-delay in robots.txt, rate limiting at your edge, and caching. The report is " <>
             "how you find out whether pulling one changed anything, which is the part usually " <>
             "missing from advice on this subject."}
        ]
      },
      %{
        id: "verify",
        heading: "Verifying a request really came from OpenAI",
        body: [
          {:p,
           "A User-Agent is a claim. Sending \"GPTBot/1.2\" requires nothing but a text editor, " <>
             "and scrapers do it — sometimes to slip past a rule that allows GPTBot, sometimes " <>
             "because a tutorial told them to. Verify before you make a serving decision based " <>
             "on identity."},
          {:p,
           "OpenAI makes this unusually easy by publishing the address ranges for each crawler " <>
             "as machine-readable JSON, served from its own domain, one file per agent. Fetch " <>
             "the file for the agent you care about, keep it fresh on a schedule, and match " <>
             "request addresses against it at your edge. Because the files are per-agent, you " <>
             "can verify not just \"this is OpenAI\" but \"this is specifically ChatGPT-User\", " <>
             "which is what you need if your rules differentiate."},
          {:p,
           "The vendor-independent method works too and is worth knowing for crawlers that " <>
             "publish nothing: reverse DNS on the source address, confirm the hostname belongs " <>
             "to the domain claimed, then forward-resolve that hostname and confirm it comes " <>
             "back to the original address. Both directions have to agree, because reverse DNS " <>
             "alone is set by whoever owns the address."},
          {:p,
           "SeriouslySimpleAnalytics reports what the header said and does not attempt to " <>
             "adjudicate. It is a measurement tool, and silently dropping requests whose " <>
             "identity it doubted would make the numbers less trustworthy. Enforcement belongs " <>
             "at your CDN or proxy; what you get here is the evidence that tells you whether " <>
             "enforcement is needed at all."}
        ]
      },
      %{
        id: "robots",
        heading: "Controlling GPTBot with robots.txt",
        body: [
          {:p,
           "OpenAI's published policy is that all three crawlers obey robots.txt, and each is " <>
             "addressed by its own token. That is what makes a nuanced policy possible rather " <>
             "than theoretical."},
          {:h3, "Block training, keep everything else"},
          {:p,
           "The most common considered position. No bulk collection for training, but people " <>
             "who ask ChatGPT about your page still get it, and you stay in ChatGPT's search " <>
             "index."},
          {:code,
           "User-agent: GPTBot\nDisallow: /\n\nUser-agent: ChatGPT-User\nAllow: /\n\nUser-agent: OAI-SearchBot\nAllow: /"},
          {:h3, "Block everything from OpenAI"},
          {:code,
           "User-agent: GPTBot\nDisallow: /\n\nUser-agent: ChatGPT-User\nDisallow: /\n\nUser-agent: OAI-SearchBot\nDisallow: /"},
          {:h3, "Allow everything (what happens if you write nothing)"},
          {:code, "User-agent: GPTBot\nAllow: /"},
          {:h3, "Protect the commercially sensitive parts only"},
          {:code,
           "User-agent: GPTBot\nDisallow: /pricing/\nDisallow: /customers/\nAllow: /docs/"},
          {:note,
           "A rule naming only GPTBot leaves ChatGPT-User and OAI-SearchBot entirely " <>
             "unaffected. This is the single most common misconfiguration on this subject, and " <>
             "it is invisible until you look at per-agent numbers."},
          {:p,
           "Whatever you write, verify it. Note the date you changed the file and watch each " <>
             "agent's request count over the following week. Crawlers cache robots.txt, so " <>
             "allow some days — but unchanged counts after that mean either a typo or a client " <>
             "that is not who it claims to be, and you want to know which."}
        ]
      },
      %{
        id: "decide",
        heading: "Should you block GPTBot?",
        body: [
          {:p,
           "We sell nothing either way, so here is the case on both sides without the usual " <>
             "editorialising."},
          {:h3, "For allowing it"},
          {:p,
           "ChatGPT cites and links sources, and a citation is distribution into a surface your " <>
             "competitors may have blocked themselves out of. For documentation, technical " <>
             "reference, open source projects and anything where being the canonical answer is " <>
             "valuable, that is closer to reach than to loss. Blocking also does not undo " <>
             "anything already collected — it only affects what happens next."},
          {:h3, "For blocking it"},
          {:p,
           "If your content is the product rather than marketing for the product, bulk " <>
             "collection is a one-way transfer. If your revenue is measured in sessions, an " <>
             "answer that satisfies someone without a visit is a lost visit. And if you are a " <>
             "publisher with any prospect of a licensing conversation, being freely available " <>
             "in bulk weakens it."},
          {:h3, "The three-way position most people end up at"},
          {:p,
           "Block GPTBot, allow ChatGPT-User, allow OAI-SearchBot. No bulk collection for " <>
             "training, no loss of the people who explicitly wanted your page, no self-removal " <>
             "from a search surface for no benefit. It is not indecision — it is the " <>
             "distinction the tokens were created to express."},
          {:p,
           "None of these is a general answer. Forty requests a month and forty thousand are " <>
             "different situations, and only one of them is worth an afternoon of your " <>
             "attention. Measure first."}
        ]
      },
      %{
        id: "llms-txt",
        heading: "llms.txt: saying what your site is, not just what may be taken",
        body: [
          {:p,
           "robots.txt is a permissions file. It says what may be fetched and nothing about " <>
             "what your site is or which parts of it are worth reading. llms.txt is the " <>
             "emerging convention for that second question: plain text at your site root, " <>
             "written for a model, describing what you offer and pointing at the pages that " <>
             "matter."},
          {:p,
           "It is not a formal standard and nothing obliges a crawler to read it. It also costs " <>
             "an afternoon and has essentially no downside, which is a ratio worth acting on. " <>
             "If you publish documentation or an API, it is the cheapest item on this page."},
          {:p,
           "Our interest here is direct, so we will be plain about it: SeriouslySimpleAnalytics " <>
             "publishes its own llms.txt describing its entire event API, specifically so a " <>
             "coding agent can integrate without a human reading docs first. It works. That is " <>
             "an argument from our own traffic rather than from theory, and it is the reason we " <>
             "recommend it."},
          {:p,
           "AGENTS.md is the same idea for repositories rather than sites — a file telling a " <>
             "coding agent how to work in your codebase. Neither file changes what a crawler " <>
             "may take. Both change how well it understands what it took."}
        ]
      },
      %{
        id: "referrals",
        heading: "Traffic arriving from ChatGPT",
        body: [
          {:p,
           "Crawling and referral are two halves of one relationship and judging either alone " <>
             "gets you the wrong answer. When ChatGPT cites your page and someone clicks, that " <>
             "person is an ordinary human visitor with a referrer, visible in the ordinary " <>
             "reports rather than the crawler report."},
          {:p,
           "That traffic tends to have a distinctive shape: lower volume than search, but " <>
             "noticeably more engaged, because someone arriving from a cited answer already " <>
             "knows roughly what your page contains and came anyway. Engaged time and scroll " <>
             "depth are what make that visible, and both are captured by default with no " <>
             "configuration."},
          {:p,
           "Watching both halves turns the block-or-allow question into an empirical one. Heavy " <>
             "crawling with zero referrals is a subsidy with nothing coming back, and a " <>
             "reasonable basis for a Disallow. Real and growing referrals suggest blocking the " <>
             "crawl may cost you the referrals too. Nobody outside your site can tell you which " <>
             "case you are in, which is the whole argument for measuring it."}
        ]
      },
      %{
        id: "compare",
        heading: "GPTBot compared with the other AI crawlers",
        body: [
          {:p,
           "OpenAI's three-way split is the clearest of any provider, but it is not unique, and " <>
             "the differences matter when you write rules."},
          {:ul,
           [
             "Anthropic splits the same three ways — ClaudeBot, Claude-User and Claude-SearchBot — so a policy that works for one maps almost directly onto the other.",
             "Perplexity runs PerplexityBot and Perplexity-User, and is built around citing sources, so the referral half of the relationship is proportionally larger.",
             "Google-Extended is not a crawler. It is a robots.txt token controlling whether content Googlebot already fetched may be used for Gemini. Blocking it removes no requests from your logs, because it never made any.",
             "Applebot-Extended is the same kind of thing: a permission token layered over Applebot, not a client of its own.",
             "Meta-ExternalAgent, Bytespider, Amazonbot and CCBot are conventional crawlers with their own agents, differing widely in volume and in how carefully they honour robots.txt.",
             "CCBot is Common Crawl, a non-profit archive that many other organisations then train on. Allowing it has a much wider blast radius than allowing any single vendor."
           ]},
          {:p,
           "The lesson is that a single blanket rule aimed at \"AI\" will be wrong in both " <>
             "directions at once — failing to stop things that are not crawlers, and stopping " <>
             "things you would have wanted. Per-agent measurement first, per-agent rules second."}
        ]
      },
      %{
        id: "what-it-sees",
        heading: "What GPTBot actually sees when it fetches your page",
        body: [
          {:p,
           "This is the part most site owners have never checked, and it is the one most " <>
             "likely to be costing them something. GPTBot requests a URL and reads the HTML " <>
             "that comes back. It does not execute JavaScript. Whatever your server put in that " <>
             "initial response is the entirety of what it got."},
          {:p,
           "For a server-rendered site, a static site, or anything built with a framework that " <>
             "ships real HTML, that is fine — the crawler sees roughly what a human sees with " <>
             "scripting turned off. For a single-page application that renders client-side, it " <>
             "is a different story. The initial response may be an empty div and a script tag. " <>
             "A human's browser fills that in within a second. GPTBot never does. Your entire " <>
             "site can be, from a crawler's perspective, blank."},
          {:p,
           "The practical test takes thirty seconds: fetch one of your own pages with curl and " <>
             "read what comes back. If your actual content is not in there, no AI crawler has " <>
             "ever seen it, and neither has anything else that does not render — which includes " <>
             "a good deal of the automated web. This matters whichever side of the block-or-allow " <>
             "question you land on, because being invisible by accident is not the same as being " <>
             "private by choice."},
          {:p,
           "Two adjacent details are worth knowing. First, a crawler reads your markup, not " <>
             "your design, so semantic HTML, real headings and a sensible title are doing more " <>
             "work for machine readers than they have done for years. Second, structured data " <>
             "and clean metadata are cheap and travel well, because they survive the " <>
             "summarisation a model performs on the way to an answer."},
          {:p,
           "GPTBot Analytics tells you which pages were fetched. Whether those pages contained " <>
             "anything when they arrived is a question only you can answer, and the curl test " <>
             "is how you answer it. It is the single highest-value thirty seconds available to " <>
             "anyone reading this page."}
        ]
      },
      %{
        id: "cost",
        heading: "What a GPTBot crawl actually costs",
        body: [
          {:p,
           "Bandwidth is the cost everyone names and usually the smallest. A crawler that does " <>
             "not render pulls no images, fonts, video or JavaScript bundles — it takes the " <>
             "cheapest bytes you serve. For most sites the whole crawl rounds to nothing " <>
             "against a single day of human traffic."},
          {:p,
           "Origin load is the cost that actually bites, and only in one case: a site where " <>
             "every page is generated on demand from a database. A broad crawl walks every URL " <>
             "you have, including deep pages that are never warm in any cache, which is close " <>
             "to a worst case for a dynamic site. If a crawl has ever moved your latency " <>
             "graphs, this was why, and the fix is edge caching rather than a Disallow line."},
          {:p,
           "The third cost is harder to price and often the most valuable discovery: pages you " <>
             "did not intend to be public being indexed. Staging environments left reachable, " <>
             "print views, faceted search URLs multiplying into thousands of near-duplicates, " <>
             "campaign pages you forgot. A crawler finds all of them, because finding all of " <>
             "them is the job. Reading the pages-taken list is frequently the moment people " <>
             "learn what is actually reachable on their own domain."},
          {:p,
           "Measure before optimising. The report gives request counts per agent over time, so " <>
             "\"is this costing me anything\" has an answer instead of a feeling. For most " <>
             "sites the honest answer is no, and the time is better spent on the pages-taken " <>
             "list."}
        ]
      },
      %{
        id: "first-week",
        heading: "A first week with GPTBot Analytics",
        body: [
          {:p,
           "If the script tag is in, this is the order worth doing things in. None of it takes " <>
             "long and most steps produce something unexpected."},
          {:ol,
           [
             "Open the crawlers tab and look at the kind breakdown first. Most people are surprised how much of their server's work is automated traffic of some kind, well beyond AI.",
             "Find all three OpenAI agents and note the ratio between them. GPTBot against ChatGPT-User is the single most informative number on the page, and it is the one a merged total destroys.",
             "Read the pages-taken list carefully. Look for pages you did not know were public, faceted URLs multiplying, and old content you had forgotten about. This step usually turns into real work.",
             "Check your referrer report for people arriving from ChatGPT. You cannot judge the crawl without the other half of the relationship.",
             "Only now decide whether you want a robots.txt rule, remembering that a rule naming GPTBot alone leaves the other two untouched. Note the date, then check the same report a week later."
           ]},
          {:p,
           "Measure, decide, verify the decision took effect. Unremarkable advice anywhere else " <>
             "in engineering, and strangely rare in discussions of AI crawlers, which tend to " <>
             "go straight from an opinion to a robots.txt file with no numbers in between. The " <>
             "whole loop takes perhaps an hour spread over a week, and at the end of it you " <>
             "have a policy you can defend to whoever asks."}
        ]
      },
      %{
        id: "setup",
        heading: "Setting up GPTBot Analytics",
        body: [
          {:p, "Two steps, and there is no plan to choose, no trial and no card."},
          {:ol,
           [
             "Create a free account. The account ID is on your dashboard the moment you sign in.",
             "Paste the script tag into the head of your pages. That is the whole integration — nothing to configure, no tagging plan to design.",
             "Open the crawlers tab. GPTBot, ChatGPT-User and OAI-SearchBot appear by name as they arrive."
           ]},
          {:p,
           "If you also build AI tools — an agent, an MCP server, a CLI, an extension — the " <>
             "same account tracks those by fetching a single URL, with no SDK and nothing added " <>
             "to your dependency tree. Crawler analytics and your own tool's telemetry land in " <>
             "one dashboard, which is more useful than it sounds the first time a crawl and a " <>
             "usage spike line up."},
          {:p,
           "Everything here is free, because there is no paid tier. The project is open source " <>
             "and can be self-hosted against your own Postgres if you would rather no third " <>
             "party sat in the path."}
        ]
      },
      %{
        id: "privacy",
        heading: "Privacy and self-hosting",
        body: [
          {:p,
           "Crawler analytics is the least privacy-sensitive thing a tracker does, since a bot " <>
             "is not a person, but the same rules apply to everything here."},
          {:ul,
           [
             "No cookies — identifiers live in browser storage, so there is no consent banner.",
             "No IP addresses stored — an address resolves a location in-request, then is salted, hashed and discarded, with the salt rotating daily.",
             "Password fields are masked in the browser and dropped again server-side, so a stale snippet cannot defeat it.",
             "data-wa-ignore on any element, form or field excludes it entirely.",
             "Self-host and none of the above requires trusting us, because we are not in the path."
           ]},
          {:p,
           "The source is public and the detection rules are one readable list in one file. If " <>
             "you want to know exactly what counts as GPTBot, read the line that decides it."}
        ]
      }
    ]
  end

  defp faq do
    [
      {"What is GPTBot?",
       "GPTBot is OpenAI's web crawler, used to gather content that may be used for model " <>
         "training. It is one of three OpenAI crawlers: GPTBot crawls broadly, ChatGPT-User " <>
         "fetches a page because a person in ChatGPT asked about it, and OAI-SearchBot indexes " <>
         "pages for ChatGPT search."},
      {"What is the GPTBot user agent string?",
       "GPTBot sends a User-Agent containing the token GPTBot along with a link to OpenAI's " <>
         "documentation, in the form Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); " <>
         "compatible; GPTBot/1.2; +https://openai.com/gptbot. Match the token " <>
         "case-insensitively rather than the whole string, because the version changes."},
      {"What is the difference between GPTBot and ChatGPT-User?",
       "GPTBot crawls broadly and what it collects may be used for training. ChatGPT-User " <>
         "fetches one page because a person in a ChatGPT conversation asked something that " <>
         "needed it — there is a human waiting at the other end. Blocking the first and " <>
         "allowing the second is a coherent and common position."},
      {"Does blocking GPTBot remove me from ChatGPT search?",
       "No. ChatGPT search is fed by OAI-SearchBot, which has its own robots.txt token. A rule " <>
         "naming only GPTBot leaves it untouched. If you want out of the search surface too, " <>
         "you have to say so separately — and OpenAI states OAI-SearchBot's crawling is not " <>
         "used for training, so blocking it removes you from a search result without preventing " <>
         "any training."},
      {"Why doesn't GPTBot show up in Google Analytics?",
       "Because JavaScript analytics only records clients that execute JavaScript, and GPTBot " <>
         "does not. The requests happened and your server served them, but no tracker ran. The " <>
         "same limit applies here: what this tool catches by itself is automation that renders. " <>
         "For GPTBot you report each hit from your own server to the ping API, or read your " <>
         "access log."},
      {"Does GPTBot respect robots.txt?",
       "OpenAI's published policy is that all three of its crawlers do, each addressed by its " <>
         "own token. Whether a rule you wrote actually took effect is worth confirming: note " <>
         "the date you changed the file and watch that agent's request count over the following " <>
         "week."},
      {"How do I block GPTBot?",
       "Add a Disallow rule for the specific token. Remember that a rule naming GPTBot alone " <>
         "does nothing to ChatGPT-User or OAI-SearchBot — this is the most common " <>
         "misconfiguration on the subject. Anything you genuinely must keep out belongs behind " <>
         "authentication rather than robots.txt."},
      {"Should I block GPTBot?",
       "It depends what your content is for. If it is documentation or reference material, " <>
         "being cited is closer to distribution than to loss. If your content is the product, " <>
         "or your revenue is measured in sessions, bulk collection costs you. Look at your own " <>
         "crawl volume and your ChatGPT referral traffic before deciding."},
      {"How do I verify a request really came from OpenAI?",
       "OpenAI publishes the address ranges for each crawler as JSON on its own domain, one " <>
         "file per agent, so you can verify not just that a request is from OpenAI but which " <>
         "crawler it is. The vendor-independent method also works: reverse DNS on the source " <>
         "address, then a forward lookup on the hostname, with both directions agreeing."},
      {"Is GPTBot Analytics free?",
       "Yes, entirely. No paid tier, no event quota, no sampling above a traffic threshold. The " <>
         "project is open source, so you can also run the whole thing on your own server " <>
         "against your own Postgres."},
      {"Will GPTBot traffic distort my human analytics?",
       "No. Automated traffic is excluded from the ordinary reports by default and given a " <>
         "report of its own, so visitor counts, bounce rates and session numbers describe " <>
         "people. Nothing is deleted — including crawlers is one toggle, and the crawler report " <>
         "is populated either way."},
      {"Why is crawler dwell time sampled every ten seconds?",
       "Because crawlers arrive in volumes humans do not produce, and per-second telemetry " <>
         "across a large crawl is a denial of service you built against yourself. " <>
         "Sub-ten-second precision means nothing for a client that does not read, scroll or " <>
         "linger, so nothing useful is lost."},
      {"Can I see which pages GPTBot took?",
       "Yes, as a ranked list per agent. It is the most useful view on the report and " <>
         "frequently shows content you would not have guessed — including pages you did not " <>
         "realise were publicly reachable."},
      {"Does GPTBot see my JavaScript-rendered content?",
       "No. GPTBot reads the HTML your server returns and does not execute JavaScript, so a " <>
         "single-page application that renders client-side may be effectively blank to it. " <>
         "Fetch one of your own pages with curl and read what comes back — if your content is " <>
         "not in there, no AI crawler has ever seen it."},
      {"How often does GPTBot crawl?",
       "There is no fixed schedule, and the honest answer is that it varies enormously by site. " <>
         "The pattern is usually bursty: a large number of requests over hours or days, then " <>
         "long quiet periods. Your own report is the only reliable source for your site, which " <>
         "is rather the point of having one."},
      {"Can I allow GPTBot on some pages and block it on others?",
       "Yes. robots.txt matches on path, so you can Disallow the sections that matter " <>
         "commercially while allowing your documentation or blog. This is often a better fit " <>
         "than an all-or-nothing rule, because most sites contain both content they want spread " <>
         "widely and content they do not."},
      {"What is OAI-SearchBot for?",
       "OAI-SearchBot builds the index behind ChatGPT's search results, and OpenAI states that " <>
         "what it gathers is not used for model training. Blocking it therefore removes you " <>
         "from a search surface without preventing any training, which is rarely what the " <>
         "person writing the rule intended."},
      {"Does this work behind a CDN?",
       "The browser tracker does, since it runs in the visitor's browser. Forward the original " <>
         "client address or every visit appears to come from your edge. If you report crawler " <>
         "hits from your origin, remember a CDN answers many of them itself — those never reach " <>
         "your server, so they are absent from anything your server reports."}
    ]
  end
end
