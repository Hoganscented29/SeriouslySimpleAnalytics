defmodule WebAnalytics.Admin.Host do
  @moduledoc """
  CPU and memory for the machine, as opposed to for the BEAM.

  Read straight from `/proc` rather than through `:os_mon`. os_mon would work,
  but it starts its own polling processes and alarm handlers for a page that
  already has a timer of its own, and it is one more thing to reason about when
  a number looks wrong. Four files, parsed here, is the smaller moving part.

  Everything degrades to `:unavailable` rather than raising: a host without
  `/proc` — a Mac in development, most likely — should show a dash on the
  dashboard, not a 500.

  One caveat worth knowing if this ever moves into a container: `/proc/meminfo`
  reports the host's memory, not the cgroup's limit, so the percentages would
  describe the machine rather than the share this application is allowed. On a
  plain VM, which is what this is deployed to, they are the same thing.
  """

  @stat "/proc/stat"
  @meminfo "/proc/meminfo"
  @loadavg "/proc/loadavg"

  @doc """
  A point-in-time CPU reading, meaningless alone.

  Utilisation is a rate, so it needs two samples and the time between them. The
  caller holds the previous one — for the dashboard that is one tick, making the
  number a true ten-second average rather than an instant guess.
  """
  def cpu_sample(contents \\ read(@stat)) do
    case contents do
      {:ok, text} -> parse_stat(text)
      :error -> :unavailable
    end
  end

  @doc "Percentage of CPU busy between two samples, or nil if it cannot be said."
  def cpu_util(%{total: prev_total, idle: prev_idle}, %{total: total, idle: idle}) do
    total_delta = total - prev_total
    idle_delta = idle - prev_idle

    # A counter that went backwards means a reboot, and a zero delta means the
    # two samples came from the same jiffy. Neither is a number worth showing.
    if total_delta > 0 and idle_delta >= 0 and idle_delta <= total_delta do
      Float.round((total_delta - idle_delta) / total_delta * 100, 1)
    end
  end

  def cpu_util(_previous, _current), do: nil

  @doc "Total, used and available memory in bytes, plus swap if the host has any."
  def memory(contents \\ read(@meminfo)) do
    case contents do
      {:ok, text} -> parse_meminfo(text)
      :error -> :unavailable
    end
  end

  @doc "The 1, 5 and 15 minute load averages."
  def load_average(contents \\ read(@loadavg)) do
    case contents do
      {:ok, text} -> parse_loadavg(text)
      :error -> :unavailable
    end
  end

  @doc "How many schedulers the load average should be judged against."
  def cpu_count, do: System.schedulers_online()

  # -- parsers --------------------------------------------------------------

  @doc false
  # The aggregate "cpu" line, whose columns are jiffies spent in each state.
  # Idle is user-visible idle plus iowait: a core waiting on disk is not doing
  # work, and counting it as busy makes a quiet box look loaded.
  def parse_stat(text) do
    text
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "cpu "))
    |> case do
      nil ->
        :unavailable

      line ->
        fields =
          line
          |> String.split(~r/\s+/, trim: true)
          |> Enum.drop(1)
          |> Enum.map(&parse_int/1)

        if Enum.any?(fields, &is_nil/1) or length(fields) < 5 do
          :unavailable
        else
          idle = Enum.at(fields, 3) + Enum.at(fields, 4)
          %{total: Enum.sum(fields), idle: idle}
        end
    end
  end

  @doc false
  def parse_meminfo(text) do
    values =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, rest] ->
            case rest |> String.trim() |> String.split(~r/\s+/) do
              [value | _] ->
                case parse_int(value) do
                  # /proc/meminfo is in kibibytes.
                  nil -> acc
                  kb -> Map.put(acc, key, kb * 1024)
                end

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)

    total = values["MemTotal"]
    # MemAvailable is the kernel's own estimate of what a new workload could
    # claim. MemFree is not the same thing and reads alarmingly low on any
    # healthy machine, because the page cache is doing its job.
    available = values["MemAvailable"] || values["MemFree"]

    if total && available && total > 0 do
      swap_total = values["SwapTotal"] || 0
      swap_free = values["SwapFree"] || 0

      %{
        total: total,
        available: available,
        used: total - available,
        used_pct: Float.round((total - available) / total * 100, 1),
        swap_total: swap_total,
        swap_used: swap_total - swap_free,
        swap_used_pct:
          if(swap_total > 0,
            do: Float.round((swap_total - swap_free) / swap_total * 100, 1),
            else: 0.0
          )
      }
    else
      :unavailable
    end
  end

  @doc false
  def parse_loadavg(text) do
    case text |> String.trim() |> String.split(~r/\s+/) do
      [one, five, fifteen | _] ->
        with {a, _} <- Float.parse(one),
             {b, _} <- Float.parse(five),
             {c, _} <- Float.parse(fifteen) do
          %{one: a, five: b, fifteen: c}
        else
          _ -> :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, _} -> :error
    end
  end
end
