defmodule WebAnalyticsWeb.DashboardComponents do
  @moduledoc """
  Presentation pieces for the analytics dashboard, plus the formatting helpers
  they share.
  """
  use WebAnalyticsWeb, :html

  alias WebAnalytics.Analytics.Anomaly

  # -- stat card -----------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: "neutral"

  def stat(assigns) do
    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300 px-4 py-3">
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class={[
        "text-2xl font-semibold tabular-nums mt-1",
        @tone == "warning" && "text-warning",
        @tone == "success" && "text-success"
      ]}>
        {@value}
      </div>
      <div :if={@hint} class="text-xs text-base-content/50 mt-0.5">{@hint}</div>
    </div>
    """
  end

  # -- ranked bar list -----------------------------------------------------

  attr :rows, :list, required: true
  attr :title, :string, default: nil
  attr :empty, :string, default: "No data yet"
  attr :name_key, :atom, default: :name
  attr :value_key, :atom, default: :count
  attr :class, :string, default: nil
  attr :click, :string, default: nil, doc: "phx-click event that makes each row a drill-down"
  attr :click_key, :atom, default: nil, doc: "field sent as phx-value-page; defaults to name_key"
  slot :meta

  def bar_list(assigns) do
    max =
      assigns.rows
      |> Enum.map(&Map.get(&1, assigns.value_key, 0))
      |> Enum.max(fn -> 0 end)

    assigns = assign(assigns, :max, max)

    ~H"""
    <div class={["rounded-box bg-base-100 border border-base-300", @class]}>
      <div :if={@title} class="px-4 py-3 border-b border-base-300 font-medium text-sm">
        {@title}
      </div>
      <div :if={@rows == []} class="px-4 py-8 text-center text-sm text-base-content/50">
        {@empty}
      </div>
      <ul class="divide-y divide-base-300/60">
        <li :for={row <- @rows} class="relative px-4 py-2">
          <div
            class="absolute inset-y-0 left-0 bg-primary/10 rounded-l"
            style={"width: #{bar_width(Map.get(row, @value_key, 0), @max)}%"}
          />
          <div class="relative flex items-center justify-between gap-4">
            <button
              :if={@click}
              phx-click={@click}
              phx-value-page={Map.get(row, @click_key || @name_key)}
              class="truncate text-sm text-left link link-hover"
              title={"Drill into #{display_name(Map.get(row, @name_key))}"}
            >
              {display_name(Map.get(row, @name_key))}
            </button>
            <span
              :if={!@click}
              class="truncate text-sm"
              title={to_string(Map.get(row, @name_key))}
            >
              {display_name(Map.get(row, @name_key))}
            </span>
            <span class="text-sm tabular-nums font-medium shrink-0">
              {number(Map.get(row, @value_key, 0))}
            </span>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp bar_width(_value, 0), do: 0
  defp bar_width(value, max), do: Float.round(value * 100 / max, 2)

  # -- histogram -----------------------------------------------------------

  attr :buckets, :list, required: true
  attr :title, :string, default: nil
  attr :primary_key, :atom, default: :count
  attr :secondary_key, :atom, default: nil
  attr :label_key, :atom, default: :label
  attr :primary_label, :string, default: "Included"
  attr :secondary_label, :string, default: "Filtered out"

  def histogram(assigns) do
    max =
      assigns.buckets
      |> Enum.map(fn bucket ->
        Map.get(bucket, assigns.primary_key, 0) +
          if(assigns.secondary_key, do: Map.get(bucket, assigns.secondary_key, 0), else: 0)
      end)
      |> Enum.max(fn -> 0 end)

    assigns = assign(assigns, :max, max)

    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300">
      <div
        :if={@title}
        class="px-4 py-3 border-b border-base-300 font-medium text-sm flex items-center justify-between"
      >
        <span>{@title}</span>
        <span :if={@secondary_key} class="flex items-center gap-3 text-xs font-normal">
          <span class="flex items-center gap-1">
            <span class="w-2.5 h-2.5 rounded-sm bg-primary inline-block" />{@primary_label}
          </span>
          <span class="flex items-center gap-1">
            <span class="w-2.5 h-2.5 rounded-sm bg-warning inline-block" />{@secondary_label}
          </span>
        </span>
      </div>
      <!-- Captions do not wrap, so on a narrow screen the bars' min-content width
           is the width of ten labels. Scroll the plot inside the card, the way
           the tables on this dashboard already do, rather than letting it push
           the page sideways. -->
      <div class="px-4 py-4 overflow-x-auto">
        <div class="flex items-end gap-1 h-40 min-w-max">
          <div
            :for={bucket <- @buckets}
            class="flex-1 flex flex-col items-center gap-1 h-full justify-end"
          >
            <div class="w-full flex flex-col justify-end items-stretch flex-1 gap-px">
              <div
                :if={@secondary_key && Map.get(bucket, @secondary_key, 0) > 0}
                class="bg-warning rounded-t-sm min-h-[2px]"
                style={"height: #{bar_height(Map.get(bucket, @secondary_key, 0), @max)}%"}
                title={"#{@secondary_label}: #{Map.get(bucket, @secondary_key, 0)}"}
              />
              <div
                class="bg-primary min-h-[2px] rounded-sm"
                style={"height: #{bar_height(Map.get(bucket, @primary_key, 0), @max)}%"}
                title={"#{@primary_label}: #{Map.get(bucket, @primary_key, 0)}"}
              />
            </div>
            <span class="text-[10px] text-base-content/50 whitespace-nowrap px-1">
              {Map.get(bucket, @label_key)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp bar_height(_value, 0), do: 0
  defp bar_height(value, max), do: Float.round(value * 100 / max, 2)

  # -- flow diagram --------------------------------------------------------

  attr :transitions, :list, default: []
  attr :focus, :map, default: nil, doc: "a navigation summary; switches to the focused view"
  attr :title, :string, default: "Page flow"
  attr :subtitle, :string, default: nil
  attr :click, :string, default: nil, doc: "phx-click event fired when a node is selected"
  slot :actions

  @doc """
  Flow diagram, in one of two modes.

  With no page selected it shows the busiest single hops across the site, two
  columns wide. A full multi-step Sankey turns to spaghetti past a handful of
  nodes, so the overview stays one hop deep.

  Selecting a page switches it to three columns centred on that page: where its
  traffic came from, the page itself, and where that traffic went. Since every
  node is clickable, re-centring on a neighbour walks the graph one hop at a
  time — which is how you read a route without drawing the whole thing.
  """
  def flow_diagram(assigns) do
    layout =
      if assigns.focus,
        do: focused_layout(assigns.focus),
        else: sankey_layout(assigns.transitions)

    assigns = assign(assigns, :layout, layout)

    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300">
      <div class="px-4 py-3 border-b border-base-300 flex items-center gap-3 flex-wrap">
        <span class="font-medium text-sm">{@title}</span>
        <span :if={@subtitle} class="text-xs text-base-content/60">{@subtitle}</span>
        <span class="flex-1"></span>
        {render_slot(@actions)}
      </div>
      <div :if={@layout.nodes == []} class="px-4 py-12 text-center text-sm text-base-content/50">
        {if @focus,
          do: "No traffic in or out of this page yet",
          else: "No page-to-page transitions recorded yet"}
      </div>
      <div :if={@layout.nodes != []} class="p-4 overflow-x-auto">
        <svg
          viewBox={"0 0 900 #{@layout.height}"}
          class="w-full"
          style={"min-height: #{@layout.height}px"}
        >
          <g :for={link <- @layout.links}>
            <path
              d={link.path}
              fill="currentColor"
              class="text-primary/20 hover:text-primary/40 transition-colors"
            >
              <title>{link.from} → {link.to}: {link.count}</title>
            </path>
          </g>
          <g
            :for={node <- @layout.nodes}
            phx-click={@click && node.clickable && @click}
            phx-value-page={node.clickable && node.name}
            class={@click && node.clickable && "cursor-pointer"}
          >
            <rect
              x={node.x}
              y={node.y}
              width="12"
              height={node.height}
              rx="2"
              fill="currentColor"
              class={node_color(node)}
            >
              <title>
                {node.name}: {node.value}{if @click && node.clickable,
                  do: " — click to centre the flow here"}
              </title>
            </rect>
            <text
              :if={node.side != :focus}
              x={if node.side == :source, do: node.x - 8, else: node.x + 20}
              y={node.y + node.height / 2}
              text-anchor={if node.side == :source, do: "end", else: "start"}
              dominant-baseline="middle"
              class={[
                "text-[11px] fill-current",
                node.clickable && "text-base-content/80",
                !node.clickable && "text-base-content/40 italic",
                @click && node.clickable && "hover:text-primary hover:underline"
              ]}
            >
              {truncate(node.name, 30)}
            </text>
          </g>
        </svg>
      </div>
    </div>
    """
  end

  @svg_width 900
  @node_width 12
  @left_x 260
  @right_x 620
  # The focused view needs a third column, so its two outer columns sit further
  # out to leave the centre free.
  @focus_left_x 220
  @focus_centre_x 448
  @focus_right_x 676
  @row_gap 4
  @min_node 3

  # Pseudo-nodes for traffic that did not come from, or go to, another page.
  @entry_label "(entered here)"
  @exit_label "(left the site)"
  @other_label "(other pages)"

  defp node_color(%{side: :focus}), do: "text-accent"
  defp node_color(%{clickable: false}), do: "text-base-content/25"
  defp node_color(%{side: :source}), do: "text-primary"
  defp node_color(_node), do: "text-secondary"

  @doc false
  # Three columns centred on one page: inbound on the left, the page itself in
  # the middle, outbound on the right.
  #
  # Each side is scaled independently against its own total, because a page's
  # inbound and outbound traffic rarely match — the difference is exactly the
  # entrances and exits, which appear as their own nodes so the two sides of the
  # centre node still add up.
  defp focused_layout(%{page: page} = focus) do
    inbound =
      focus.before
      |> Enum.map(&{&1.name, &1.count, true})
      |> append_extra(@other_label, Map.get(focus, :before_other, 0))
      |> append_extra(@entry_label, focus.totals.entrances)

    outbound =
      focus.next
      |> Enum.map(&{&1.name, &1.count, true})
      |> append_extra(@other_label, Map.get(focus, :next_other, 0))
      |> append_extra(@exit_label, focus.totals.exits)

    inbound_total = total_of(inbound)
    outbound_total = total_of(outbound)

    if inbound_total == 0 and outbound_total == 0 do
      %{height: 80, nodes: [], links: []}
    else
      # Taller rows than the overview: there are only a handful of ribbons here
      # and they carry the whole story, so they are worth the vertical room.
      rows = max(length(inbound), length(outbound))
      height = max(rows * 52, 220)
      usable = height - max(rows - 1, 0) * @row_gap

      left_nodes = place_side(inbound, @focus_left_x, inbound_total, usable, :source)
      right_nodes = place_side(outbound, @focus_right_x, outbound_total, usable, :target)

      centre = %{
        name: page,
        value: focus.totals.views,
        x: @focus_centre_x,
        y: 0.0,
        height: usable * 1.0,
        side: :focus,
        clickable: false
      }

      # The centre node's left edge is divided by the inbound proportions and its
      # right edge by the outbound ones, which is what makes both sides meet it
      # flush despite the different totals.
      {inbound_links, _} =
        Enum.map_reduce(left_nodes, 0.0, fn node, offset ->
          link = %{
            from: node.name,
            to: page,
            count: node.value,
            path: ribbon(node.x + @node_width, node.y, centre.x, offset, node.height)
          }

          {link, offset + node.height}
        end)

      {outbound_links, _} =
        Enum.map_reduce(right_nodes, 0.0, fn node, offset ->
          link = %{
            from: page,
            to: node.name,
            count: node.value,
            path: ribbon(centre.x + @node_width, offset, node.x, node.y, node.height)
          }

          {link, offset + node.height}
        end)

      %{
        height: height,
        nodes: left_nodes ++ [centre] ++ right_nodes,
        links: inbound_links ++ outbound_links
      }
    end
  end

  defp append_extra(rows, _label, count) when count <= 0, do: rows
  defp append_extra(rows, label, count), do: rows ++ [{label, count, false}]

  defp total_of(rows), do: rows |> Enum.map(fn {_name, count, _} -> count end) |> Enum.sum()

  defp place_side(rows, x, total, usable, side) do
    {nodes, _} =
      Enum.map_reduce(rows, 0.0, fn {name, count, clickable?}, offset ->
        height = max(count / max(total, 1) * usable, @min_node)

        node = %{
          name: name,
          value: count,
          x: x,
          y: offset,
          height: height,
          side: side,
          clickable: clickable?
        }

        {node, offset + height + @row_gap}
      end)

    nodes
  end

  defp sankey_layout([]), do: %{height: 80, nodes: [], links: []}

  defp sankey_layout(transitions) do
    sources = totals_by(transitions, :from)
    targets = totals_by(transitions, :to)

    grand = transitions |> Enum.map(& &1.count) |> Enum.sum()
    rows = max(length(sources), length(targets))
    height = max(rows * 26, 120)
    usable = height - (rows - 1) * @row_gap

    source_nodes = place(sources, @left_x, grand, usable, :source)
    target_nodes = place(targets, @right_x, grand, usable, :target)

    source_index = Map.new(source_nodes, &{&1.name, &1})
    target_index = Map.new(target_nodes, &{&1.name, &1})

    {links, _, _} =
      transitions
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.reduce({[], %{}, %{}}, fn transition, {acc, source_used, target_used} ->
        source = Map.fetch!(source_index, transition.from)
        target = Map.fetch!(target_index, transition.to)

        thickness = max(transition.count / max(grand, 1) * usable, 1.0)

        y0 = source.y + Map.get(source_used, transition.from, 0.0)
        y1 = target.y + Map.get(target_used, transition.to, 0.0)

        link = %{
          from: transition.from,
          to: transition.to,
          count: transition.count,
          path: ribbon(source.x + @node_width, y0, target.x, y1, thickness)
        }

        {
          [link | acc],
          Map.update(source_used, transition.from, thickness, &(&1 + thickness)),
          Map.update(target_used, transition.to, thickness, &(&1 + thickness))
        }
      end)

    %{height: height, nodes: source_nodes ++ target_nodes, links: Enum.reverse(links)}
  end

  defp totals_by(transitions, key) do
    transitions
    |> Enum.group_by(&Map.fetch!(&1, key))
    |> Enum.map(fn {name, rows} -> {name, rows |> Enum.map(& &1.count) |> Enum.sum()} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp place(entries, x, grand, usable, side) do
    {nodes, _} =
      Enum.reduce(entries, {[], 0.0}, fn {name, value}, {acc, offset} ->
        height = max(value / max(grand, 1) * usable, @min_node)

        node = %{
          name: name,
          value: value,
          x: x,
          y: offset,
          height: height,
          side: side,
          clickable: true
        }

        {[node | acc], offset + height + @row_gap}
      end)

    Enum.reverse(nodes)
  end

  # Cubic bezier band: two horizontal-tangent curves joined at the ends.
  defp ribbon(x0, y0, x1, y1, thickness) do
    mid = (x0 + x1) / 2

    Enum.join(
      [
        "M#{r(x0)},#{r(y0)}",
        "C#{r(mid)},#{r(y0)} #{r(mid)},#{r(y1)} #{r(x1)},#{r(y1)}",
        "L#{r(x1)},#{r(y1 + thickness)}",
        "C#{r(mid)},#{r(y1 + thickness)} #{r(mid)},#{r(y0 + thickness)} #{r(x0)},#{r(y0 + thickness)}",
        "Z"
      ],
      " "
    )
  end

  defp r(value), do: Float.round(value * 1.0, 2)

  def svg_width, do: @svg_width

  # -- anomaly badge -------------------------------------------------------

  attr :series, :list, required: true, doc: "one entry per minute, oldest first"
  attr :value_key, :atom, default: :sessions
  attr :label, :string, default: "Sessions open, per minute"

  @doc """
  The last thirty minutes, one bar per minute.

  Written to survive both ends of its range. A busy window scales to its own
  peak. An empty one still draws thirty baseline ticks and an axis rather than
  collapsing to a blank box, because "nothing happened" and "this panel is
  broken" look identical otherwise — and on a live view that is the difference
  a reader most needs to see.

  The scale is floored at one so an empty window does not divide by zero. One
  session therefore fills the height, which is what the "peak 1" label beside
  it is for: the shape says when, the label says how much.
  """
  def live_sparkline(assigns) do
    values = Enum.map(assigns.series, &Map.get(&1, assigns.value_key, 0))
    peak = values |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(:values, values)
      |> assign(:peak, peak)
      |> assign(:scale, max(peak, 1))
      |> assign(:total, Enum.sum(values))

    ~H"""
    <div class="rounded-box bg-base-200/50 border border-base-300 p-3">
      <div class="flex items-baseline justify-between gap-3 mb-2">
        <span class="text-[11px] font-medium">{@label}</span>
        <span class="text-[10px] text-base-content/40 tabular-nums">
          {if @peak > 0, do: "peak #{@peak}", else: "no activity"}
        </span>
      </div>

      <%!-- A floor under the bars, so an all-zero window still reads as a chart
      with nothing in it rather than as an empty box. --%>
      <div class="flex items-end gap-[2px] h-16 border-b border-base-300">
        <div
          :for={{point, value} <- Enum.zip(@series, @values)}
          class="flex-1 min-w-0 flex items-end h-full"
          title={"#{Calendar.strftime(point.at, "%H:%M")} UTC · #{value}"}
        >
          <%!-- A zero still gets a visible tick. It reads as a minute that was
          measured and was quiet, which a bar of no height does not. --%>
          <div
            class={[
              "w-full rounded-sm transition-colors",
              value > 0 && "bg-success/80 hover:bg-success",
              value == 0 && "bg-base-content/15 hover:bg-base-content/30"
            ]}
            style={
              if value > 0,
                do: "height: #{max(round(value * 100 / @scale), 6)}%",
                else: "height: 3px"
            }
          >
          </div>
        </div>
      </div>

      <div class="flex justify-between text-[10px] text-base-content/40 mt-1.5">
        <span>30 min ago</span>
        <span :if={@total > 0} class="tabular-nums">{@total} session-minutes</span>
        <span>now</span>
      </div>
    </div>
    """
  end

  attr :reasons, :list, required: true
  attr :score, :float, default: nil

  def anomaly_badges(assigns) do
    ~H"""
    <span :if={@reasons == []} class="text-xs text-base-content/40">—</span>
    <span class="flex flex-wrap gap-1">
      <span
        :for={reason <- @reasons}
        class="badge badge-sm badge-warning badge-outline whitespace-nowrap"
        title={Anomaly.label(reason)}
      >
        {Anomaly.label(reason)}
      </span>
    </span>
    """
  end

  # -- formatting ----------------------------------------------------------

  @doc """
  A visitor's address with its middle masked out.

  Masked in the request that carried it, so the value shown here is the only
  form that was ever written — there is no unmasked column behind this one.
  Sessions recorded before the column existed have nothing to show, and fall
  back to the origin hash so the column is not simply blank for them.
  """
  def masked_ip(%{ip_masked: masked}) when is_binary(masked) and masked != "", do: masked
  def masked_ip(%{ip_hash: hash}) when is_binary(hash), do: origin_hash(hash)
  def masked_ip(_), do: "—"

  @doc """
  The leading bytes of the salted, day-rotating origin hash.

  Not an address: this is the identifier the anomaly scorer keeps to spot one
  place spraying sessions, and it is what the origin filters group and exclude
  on. It stops being linkable once the salt rotates.
  """
  def origin(nil), do: "—"
  def origin(hash) when is_binary(hash), do: origin_hash(hash)
  def origin(_), do: "—"

  defp origin_hash(hash), do: binary_part(hash, 0, min(6, byte_size(hash)))

  @doc "Human-readable duration from milliseconds."
  def duration(nil), do: "—"
  def duration(ms) when not is_integer(ms), do: duration(round(ms))
  def duration(ms) when ms < 1_000, do: "#{ms}ms"

  def duration(ms) when ms < 60_000 do
    seconds = Float.round(ms / 1000, 1)
    "#{:erlang.float_to_binary(seconds, decimals: 1)}s"
  end

  def duration(ms) when ms < 3_600_000 do
    "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  end

  def duration(ms), do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"

  @doc "Thousands-separated integer."
  def number(nil), do: "0"
  def number(value) when is_float(value), do: number(round(value))

  def number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  def number(value), do: to_string(value)

  def percent(nil), do: "0%"
  def percent(value) when is_integer(value), do: "#{value}%"
  def percent(value), do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}%"

  def display_name(nil), do: "(none)"
  def display_name(""), do: "(empty)"
  def display_name(value), do: to_string(value)

  def truncate(nil, _length), do: ""

  def truncate(value, length) do
    value = to_string(value)
    if String.length(value) > length, do: String.slice(value, 0, length - 1) <> "…", else: value
  end

  @doc "Compact relative time, e.g. `3m ago`."
  def relative(nil), do: "—"

  def relative(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
