defmodule Mix.Tasks.Geoip.Download do
  @moduledoc """
  Downloads a free city-level GeoIP database.

      mix geoip.download

  Fetches DB-IP's IP-to-City Lite database, which is published monthly under
  CC BY 4.0 and needs no account or API key. The file is written to
  `priv/geoip/` and is gitignored — it is ~120MB and is reissued every month, so
  it does not belong in version control.

  Without it the app still runs: location falls back to CDN headers, and then to
  a country-level guess from the visitor's time zone.

  ## Options

    * `--month YYYY-MM` — fetch a specific edition instead of the newest
    * `--output PATH` — write somewhere other than the default
  """
  @shortdoc "Downloads a free city-level GeoIP database"

  use Mix.Task

  @base "https://download.db-ip.com/free"
  @default_output "priv/geoip/dbip-city-lite.mmdb"

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: [month: :string, output: :string])

    output = opts[:output] || @default_output
    months = if opts[:month], do: [opts[:month]], else: recent_months()

    Mix.shell().info("Fetching DB-IP IP-to-City Lite...")
    File.mkdir_p!(Path.dirname(output))

    case Enum.find_value(months, &fetch(&1, output)) do
      :ok ->
        %{size: size} = File.stat!(output)
        Mix.shell().info("Wrote #{output} (#{div(size, 1_048_576)}MB)")
        Mix.shell().info("Restart the app, or call WebAnalytics.Geo.Database.reload/0.")

      nil ->
        Mix.raise("""
        Could not download a database from #{@base}.

        Download one manually and put it at #{output}:
          * DB-IP Lite  https://db-ip.com/db/download/ip-to-city-lite
          * MaxMind GeoLite2 City  https://dev.maxmind.com/geoip/geolite2-free-geolocation-data

        Any MaxMind-format .mmdb file works.
        """)
    end
  end

  # The newest edition is dated the current month, but it is not published until
  # partway through it, so the previous couple are tried as a fallback.
  defp recent_months do
    today = Date.utc_today()

    for back <- 0..2 do
      date = shift_months(today, -back)
      "#{date.year}-#{String.pad_leading(to_string(date.month), 2, "0")}"
    end
  end

  defp shift_months(date, months) do
    total = date.year * 12 + (date.month - 1) + months
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  defp fetch(month, output) do
    url = "#{@base}/dbip-city-lite-#{month}.mmdb.gz"
    Mix.shell().info("  trying #{month}...")

    gz = output <> ".gz"

    case System.cmd("curl", ["-sfL", "--max-time", "600", url, "-o", gz], stderr_to_stdout: true) do
      {_, 0} ->
        decompress(gz, output)

      _ ->
        File.rm(gz)
        nil
    end
  end

  defp decompress(gz, output) do
    case System.cmd("gunzip", ["-cf", gz], into: File.stream!(output)) do
      {_, 0} ->
        File.rm(gz)
        :ok

      _ ->
        File.rm(gz)
        File.rm(output)
        nil
    end
  rescue
    _ ->
      File.rm(gz)
      nil
  end
end
