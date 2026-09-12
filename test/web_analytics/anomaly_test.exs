defmodule WebAnalytics.Analytics.AnomalyTest do
  use ExUnit.Case, async: true

  alias WebAnalytics.Analytics.Anomaly

  @config Anomaly.config()

  defp session(overrides) do
    Map.merge(
      %{
        dwell_ms: 45_000,
        active_ms: 30_000,
        tick_count: 45,
        active_tick_count: 30,
        pageview_count: 2,
        click_count: 3,
        max_scroll_pct: 70,
        crawler: false
      },
      overrides
    )
  end

  defp classify(overrides, baseline \\ nil) do
    Anomaly.classify(session(overrides), baseline, @config)
  end

  describe "explanations" do
    test "there is one for every reason the classifier can store" do
      # A reason with a count and no explanation is the state this tab exists
      # to fix: "Parked idle tab: 41" tells a reader that 41 visits were thrown
      # away without telling them what was thrown away or why.
      assert Map.keys(Anomaly.explanations()) |> Enum.sort() ==
               Map.keys(Anomaly.labels()) |> Enum.sort()
    end

    test "each one says what it is, what trips it and why that matters" do
      for {code, explanation} <- Anomaly.explanations() do
        assert is_binary(explanation.why), code
        assert is_binary(explanation.rule), code
        assert is_binary(explanation.because), code
      end
    end

    test "the numbers come from the config rather than being typed in" do
      # Otherwise a threshold changed in the defaults leaves the dashboard
      # explaining a rule the classifier no longer applies.
      tightened =
        Anomaly.config()
        |> Map.put(:max_dwell_ms, 3_600_000)
        |> Map.put(:stale_tick_count, 999)

      explanations = Anomaly.explanations(tightened)

      assert explanations["extreme_dwell"].rule =~ "1 hours"
      assert explanations["no_engagement"].rule =~ "999"

      refute Anomaly.explanations()["extreme_dwell"].rule =~ "1 hours"
    end
  end

  test "an ordinary visit is not flagged" do
    assert %{anomalous: false, anomaly_reasons: []} = classify(%{})
  end

  test "flags a visit with no dwell, heartbeat or click" do
    assert %{anomalous: true, anomaly_reasons: reasons} =
             classify(%{dwell_ms: 200, tick_count: 0, click_count: 0, pageview_count: 1})

    assert "no_dwell" in reasons
  end

  test "does not flag a short visit that still shows a click" do
    result = classify(%{dwell_ms: 200, tick_count: 0, click_count: 1, pageview_count: 1})
    refute "no_dwell" in result.anomaly_reasons
  end

  test "flags several pages consumed faster than a person could read them" do
    assert %{anomaly_reasons: reasons} = classify(%{dwell_ms: 1_200, pageview_count: 4})
    assert "too_fast" in reasons
  end

  test "does not apply the too-fast rule below three pages" do
    result = classify(%{dwell_ms: 1_200, pageview_count: 2})
    refute "too_fast" in result.anomaly_reasons
  end

  test "flags an impossible navigation rate" do
    assert %{anomaly_reasons: reasons} = classify(%{dwell_ms: 2_000, pageview_count: 9})
    assert "hyper_navigation" in reasons
  end

  test "flags a tab parked open with almost no attention" do
    assert %{anomaly_reasons: reasons} =
             classify(%{dwell_ms: 5 * 3_600_000, active_ms: 20_000, tick_count: 400})

    assert "idle_tab" in reasons
  end

  test "does not flag a long visit that stayed engaged" do
    result =
      classify(%{
        dwell_ms: 5 * 3_600_000,
        active_ms: 4 * 3_600_000,
        tick_count: 400,
        active_tick_count: 350
      })

    refute "idle_tab" in result.anomaly_reasons
  end

  test "flags an implausibly long visit" do
    assert %{anomaly_reasons: reasons} =
             classify(%{dwell_ms: 20 * 3_600_000, active_ms: 19 * 3_600_000})

    assert "extreme_dwell" in reasons
  end

  test "flags heartbeats that never showed any engagement" do
    assert %{anomaly_reasons: reasons} =
             classify(%{
               tick_count: 120,
               active_tick_count: 0,
               click_count: 0,
               max_scroll_pct: 0
             })

    assert "no_engagement" in reasons
  end

  describe "dwell distribution outliers" do
    # ln(45_000) ≈ 10.71, so a baseline centred there makes a normal visit typical.
    @baseline %{median: 10.71, mad: 0.5, sample: 200}

    test "leaves a session near the median alone" do
      result = classify(%{}, @baseline)
      refute "dwell_outlier" in result.anomaly_reasons
      assert result.anomaly_score < 1.0
    end

    test "flags a session far from the median" do
      assert %{anomaly_reasons: reasons} = classify(%{dwell_ms: 30}, @baseline)
      assert "dwell_outlier" in reasons
    end

    test "is skipped when the site has too little traffic to model" do
      small = %{@baseline | sample: 3}
      result = classify(%{dwell_ms: 30}, small)
      refute "dwell_outlier" in result.anomaly_reasons
    end

    test "is skipped when there is no baseline at all" do
      result = classify(%{dwell_ms: 30}, nil)
      refute "dwell_outlier" in result.anomaly_reasons
      assert result.anomaly_score == 0.0
    end

    test "reports zero rather than dividing by a degenerate spread" do
      assert Anomaly.score(session(%{}), %{median: 10.0, mad: 0.0, sample: 500}) == 0.0
    end
  end

  test "does not classify crawlers — that is a separate axis" do
    refute Map.has_key?(Anomaly.labels(), "bot_ua")

    # A crawler's dwell profile trips nearly every rule; flagging it too would
    # mean un-hiding crawler traffic still left it hidden behind this filter.
    crawling = session(%{dwell_ms: 900, tick_count: 0, click_count: 0, pageview_count: 6})

    assert %{anomalous: true} = Anomaly.classify(crawling, nil, @config)

    assert %{anomalous: false, anomaly_reasons: []} =
             Anomaly.classify(Map.put(crawling, :crawler, true), nil, @config)
  end

  test "every reason it can emit has a human-readable label" do
    reasons =
      [
        %{dwell_ms: 200, tick_count: 0, click_count: 0, pageview_count: 1},
        %{dwell_ms: 1_200, pageview_count: 4},
        %{dwell_ms: 2_000, pageview_count: 9},
        %{dwell_ms: 5 * 3_600_000, active_ms: 10, tick_count: 400},
        %{dwell_ms: 20 * 3_600_000},
        %{tick_count: 120, active_tick_count: 0, click_count: 0, max_scroll_pct: 0}
      ]
      |> Enum.flat_map(&classify(&1).anomaly_reasons)
      |> Enum.uniq()

    assert length(reasons) >= 5

    for reason <- reasons do
      assert Anomaly.label(reason) != reason, "no label for #{reason}"
    end
  end
end
