defmodule WebAnalytics.Admin.HostTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.Admin.Host

  # Shaped like the output from the Ubuntu box this deploys to. Parsing is
  # tested against fixtures rather than against the machine running the suite,
  # because that machine is usually a Mac with no /proc at all.
  @stat """
  cpu  234567 1234 56789 9876543 4321 0 2345 0 0 0
  cpu0 117283 617 28394 4938271 2160 0 1172 0 0 0
  cpu1 117284 617 28395 4938272 2161 0 1173 0 0 0
  intr 123456789 0 0 0
  ctxt 987654321
  btime 1757000000
  """

  @meminfo """
  MemTotal:        4030312 kB
  MemFree:          182340 kB
  MemAvailable:    2431208 kB
  Buffers:          104520 kB
  Cached:          1893244 kB
  SwapCached:         1024 kB
  SwapTotal:       2097148 kB
  SwapFree:        2031612 kB
  """

  @loadavg "0.52 0.31 0.24 2/412 91572\n"

  describe "cpu" do
    test "a sample is the totals and the idle time" do
      assert %{total: total, idle: idle} = Host.parse_stat(@stat)
      assert total == 234_567 + 1234 + 56_789 + 9_876_543 + 4321 + 0 + 2345 + 0 + 0 + 0
      # idle + iowait: a core blocked on disk is not doing work.
      assert idle == 9_876_543 + 4321
    end

    test "utilisation is the busy share between two samples" do
      # 200 jiffies passed, 150 of them idle, so 25% busy.
      assert Host.cpu_util(%{total: 1000, idle: 900}, %{total: 1200, idle: 1050}) == 25.0
    end

    test "a fully idle interval is zero, a fully busy one is a hundred" do
      assert Host.cpu_util(%{total: 100, idle: 50}, %{total: 200, idle: 150}) == 0.0
      assert Host.cpu_util(%{total: 100, idle: 50}, %{total: 200, idle: 50}) == 100.0
    end

    test "nonsense intervals produce nil rather than a wrong number" do
      # No time passed between the samples.
      refute Host.cpu_util(%{total: 100, idle: 50}, %{total: 100, idle: 50})
      # Counters went backwards, which means the host rebooted.
      refute Host.cpu_util(%{total: 500, idle: 400}, %{total: 100, idle: 50})
      # More idle time than elapsed time.
      refute Host.cpu_util(%{total: 100, idle: 50}, %{total: 110, idle: 90})
      refute Host.cpu_util(:unavailable, %{total: 200, idle: 100})
      refute Host.cpu_util(%{total: 100, idle: 50}, :unavailable)
    end

    test "a file without a cpu line is unavailable, not a crash" do
      assert Host.parse_stat("intr 1 2 3\nctxt 4\n") == :unavailable
      assert Host.parse_stat("") == :unavailable
      assert Host.cpu_sample(:error) == :unavailable
    end
  end

  describe "memory" do
    test "reports what is actually claimable, not MemFree" do
      memory = Host.parse_meminfo(@meminfo)

      assert memory.total == 4_030_312 * 1024
      # MemAvailable, not MemFree: free reads alarmingly low on any healthy box
      # because the page cache is doing its job.
      assert memory.available == 2_431_208 * 1024
      assert memory.used == (4_030_312 - 2_431_208) * 1024
      assert memory.used_pct == 39.7
    end

    test "reports swap separately" do
      memory = Host.parse_meminfo(@meminfo)

      assert memory.swap_total == 2_097_148 * 1024
      assert memory.swap_used == (2_097_148 - 2_031_612) * 1024
      assert memory.swap_used_pct == 3.1
    end

    test "a host with no swap reports zero rather than dividing by it" do
      memory =
        Host.parse_meminfo(
          "MemTotal: 1000 kB\nMemAvailable: 400 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"
        )

      assert memory.swap_total == 0
      assert memory.swap_used_pct == 0.0
    end

    test "falls back to MemFree on a kernel too old for MemAvailable" do
      memory = Host.parse_meminfo("MemTotal: 1000 kB\nMemFree: 250 kB\n")

      assert memory.available == 250 * 1024
      assert memory.used_pct == 75.0
    end

    test "junk is unavailable, not a crash" do
      assert Host.parse_meminfo("") == :unavailable
      assert Host.parse_meminfo("MemTotal: not-a-number kB\n") == :unavailable
      assert Host.parse_meminfo("MemTotal: 0 kB\nMemAvailable: 0 kB\n") == :unavailable
      assert Host.memory(:error) == :unavailable
    end
  end

  describe "load average" do
    test "reads the three windows" do
      assert %{one: 0.52, five: 0.31, fifteen: 0.24} = Host.parse_loadavg(@loadavg)
    end

    test "junk is unavailable" do
      assert Host.parse_loadavg("") == :unavailable
      assert Host.parse_loadavg("nonsense here") == :unavailable
      assert Host.load_average(:error) == :unavailable
    end
  end

  describe "on whatever machine this is" do
    test "every reader either answers or says it cannot" do
      # Passes on Linux, where /proc exists, and on a Mac, where it does not.
      assert Host.cpu_sample() == :unavailable or match?(%{total: _}, Host.cpu_sample())
      assert Host.memory() == :unavailable or match?(%{total: _}, Host.memory())
      assert Host.load_average() == :unavailable or match?(%{one: _}, Host.load_average())
      assert Host.cpu_count() > 0
    end
  end
end
