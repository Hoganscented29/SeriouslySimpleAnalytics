defmodule WebAnalytics.Ingest.UserAgent do
  @moduledoc """
  Minimal UA classification — enough to segment traffic and to feed the
  `bot_ua` anomaly signal, without pulling in a parser dependency.
  """

  @bot ~r/bot|crawl|spider|slurp|headless|phantomjs|puppeteer|playwright|selenium|lighthouse|pingdom|uptime|curl\/|wget|python-requests|okhttp|go-http-client|java\/|scrapy|facebookexternalhit|embedly|preview|monitoring|archiver|validator/i

  @browsers [
    {~r/Edg(?:e|A|iOS)?\/([\d.]+)/, "Edge"},
    {~r/OPR\/([\d.]+)/, "Opera"},
    {~r/Opera[ \/]([\d.]+)/, "Opera"},
    {~r/SamsungBrowser\/([\d.]+)/, "Samsung Internet"},
    {~r/Vivaldi\/([\d.]+)/, "Vivaldi"},
    {~r/Brave\/([\d.]+)/, "Brave"},
    {~r/FxiOS\/([\d.]+)/, "Firefox"},
    {~r/Firefox\/([\d.]+)/, "Firefox"},
    {~r/CriOS\/([\d.]+)/, "Chrome"},
    {~r/Chrome\/([\d.]+)/, "Chrome"},
    {~r/Version\/([\d.]+).*Safari/, "Safari"},
    {~r/Safari\/([\d.]+)/, "Safari"}
  ]

  @systems [
    {~r/Windows NT 10\.0/, "Windows 10/11"},
    {~r/Windows NT ([\d.]+)/, "Windows"},
    {~r/iPhone OS ([\d_]+)/, "iOS"},
    {~r/iPad;.*OS ([\d_]+)/, "iPadOS"},
    {~r/Mac OS X ([\d_.]+)/, "macOS"},
    {~r/Android ([\d.]+)/, "Android"},
    {~r/CrOS/, "ChromeOS"},
    {~r/Linux/, "Linux"}
  ]

  @doc """
  Returns browser, version, OS, device class and a bot flag.

  The bot flag is advisory: it feeds anomaly scoring rather than dropping
  traffic outright, so a false positive stays visible behind the filter toggle.
  """
  def parse(nil), do: empty()
  def parse(""), do: empty()

  def parse(ua) when is_binary(ua) do
    {browser, version} = detect_browser(ua)

    %{
      browser: browser,
      browser_version: version,
      os: detect_os(ua),
      device_type: detect_device(ua),
      bot: Regex.match?(@bot, ua)
    }
  end

  def parse(_), do: empty()

  defp empty do
    %{browser: nil, browser_version: nil, os: nil, device_type: nil, bot: false}
  end

  defp detect_browser(ua) do
    Enum.find_value(@browsers, {nil, nil}, fn {re, name} ->
      case Regex.run(re, ua) do
        [_, version] -> {name, version}
        [_] -> {name, nil}
        nil -> nil
      end
    end)
  end

  defp detect_os(ua) do
    Enum.find_value(@systems, fn {re, name} ->
      if Regex.match?(re, ua), do: name
    end)
  end

  defp detect_device(ua) do
    cond do
      Regex.match?(~r/iPad|Tablet|PlayBook|Silk/i, ua) -> "tablet"
      Regex.match?(~r/Mobi|iPhone|iPod|Android.*Mobile|Windows Phone/i, ua) -> "mobile"
      true -> "desktop"
    end
  end
end
