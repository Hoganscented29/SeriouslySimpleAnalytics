defmodule WebAnalytics.Ingest.CrawlerTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.Ingest.Crawler

  describe "classify/1" do
    test "identifies AI crawlers and agents" do
      for {ua, name} <- [
            {"Mozilla/5.0 (compatible; GPTBot/1.1; +https://openai.com/gptbot)", "GPTBot"},
            {"Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)", "ClaudeBot"},
            {"Mozilla/5.0 (compatible; PerplexityBot/1.0)", "PerplexityBot"},
            {"Mozilla/5.0 (compatible; Bytespider; spider-feedback@bytedance.com)", "Bytespider"},
            {"CCBot/2.0 (https://commoncrawl.org/faq/)", "CCBot"},
            {"Mozilla/5.0 (compatible; Meta-ExternalAgent/1.1)", "Meta-ExternalAgent"},
            {"ChatGPT-User/1.0", "ChatGPT-User"}
          ] do
        assert %{crawler: true, kind: "ai", name: ^name} = Crawler.classify(ua)
      end
    end

    test "identifies search engines" do
      assert %{crawler: true, kind: "search", name: "Googlebot"} =
               Crawler.classify(
                 "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
               )

      assert %{crawler: true, kind: "search", name: "Bingbot"} =
               Crawler.classify(
                 "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
               )

      assert %{crawler: true, kind: "search", name: "DuckDuckBot"} =
               Crawler.classify("DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)")
    end

    test "prefers the AI variant over the search engine it shares a name with" do
      # These two exist specifically to opt out of AI training and must not be
      # reported as ordinary search crawling.
      assert %{kind: "ai", name: "Google-Extended"} = Crawler.classify("Google-Extended/1.0")
      assert %{kind: "ai", name: "Applebot-Extended"} = Crawler.classify("Applebot-Extended/1.0")

      assert %{kind: "search", name: "Applebot"} =
               Crawler.classify("Mozilla/5.0 (compatible; Applebot/0.1)")
    end

    test "identifies link unfurlers, SEO crawlers, monitors and HTTP clients" do
      assert %{kind: "preview", name: "Slackbot"} = Crawler.classify("Slackbot-LinkExpanding 1.0")
      assert %{kind: "preview", name: "Facebook"} = Crawler.classify("facebookexternalhit/1.1")

      assert %{kind: "seo", name: "AhrefsBot"} =
               Crawler.classify("Mozilla/5.0 (compatible; AhrefsBot/7.0)")

      assert %{kind: "monitor", name: "Lighthouse"} = Crawler.classify("Chrome-Lighthouse")
      assert %{kind: "tool", name: "curl"} = Crawler.classify("curl/8.4.0")
      assert %{kind: "tool", name: "Python HTTP"} = Crawler.classify("python-requests/2.31.0")

      assert %{kind: "headless", name: "Headless Chrome"} =
               Crawler.classify("HeadlessChrome/120.0.0.0")
    end

    test "falls back to a generic verdict for unknown bots" do
      assert %{crawler: true, kind: "other", name: "Unclassified bot"} =
               Crawler.classify("SomeNewThing-Crawler/1.0")
    end

    test "leaves ordinary browsers alone" do
      for ua <- [
            WebAnalytics.Fixtures.user_agent(),
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0"
          ] do
        assert %{crawler: false, kind: nil, name: nil} = Crawler.classify(ua)
      end
    end

    test "handles a missing user agent" do
      assert %{crawler: false} = Crawler.classify(nil)
      assert %{crawler: false} = Crawler.classify("")
    end
  end

  describe "classify/2" do
    test "believes a client that reports itself automated" do
      human = WebAnalytics.Fixtures.user_agent()

      assert %{crawler: true, kind: "automation"} = Crawler.classify(human, "webdriver")
      assert %{crawler: true, kind: "headless"} = Crawler.classify(human, "headless")
      assert %{crawler: true, kind: "other"} = Crawler.classify(human, "user-agent")
    end

    test "still catches a crawler that reports nothing" do
      assert %{crawler: true, kind: "ai", name: "GPTBot"} =
               Crawler.classify("Mozilla/5.0 (compatible; GPTBot/1.1)", nil)
    end

    test "keeps the specific server verdict over the vaguer client one" do
      assert %{kind: "ai", name: "ClaudeBot"} =
               Crawler.classify("Mozilla/5.0 (compatible; ClaudeBot/1.0)", "webdriver")
    end

    test "does not turn a quiet human into a crawler" do
      assert %{crawler: false} = Crawler.classify(WebAnalytics.Fixtures.user_agent(), nil)
      assert %{crawler: false} = Crawler.classify(WebAnalytics.Fixtures.user_agent(), "")
    end
  end
end
