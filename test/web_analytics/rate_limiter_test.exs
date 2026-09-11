defmodule WebAnalytics.RateLimiterTest do
  use ExUnit.Case, async: false

  alias WebAnalytics.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "allows a burst up to the limit and refuses the one after" do
    for _ <- 1..3, do: assert(RateLimiter.hit(:burst, 3, 60_000) == :ok)
    assert {:error, retry_after} = RateLimiter.hit(:burst, 3, 60_000)
    assert retry_after in 1..60
  end

  test "buckets do not borrow each other's budget" do
    assert RateLimiter.hit(:a, 1, 60_000) == :ok
    assert RateLimiter.hit(:b, 1, 60_000) == :ok
    assert {:error, _} = RateLimiter.hit(:a, 1, 60_000)
  end

  test "the budget comes back with the next window" do
    now = System.system_time(:millisecond)
    assert RateLimiter.hit(:window, 1, 1_000, now) == :ok
    assert {:error, _} = RateLimiter.hit(:window, 1, 1_000, now)
    assert RateLimiter.hit(:window, 1, 1_000, now + 1_000) == :ok
  end

  test "retry_after counts down within the window rather than restating it" do
    now = System.system_time(:millisecond)
    base = div(now, 10_000) * 10_000

    assert RateLimiter.hit(:countdown, 1, 10_000, base) == :ok
    assert {:error, early} = RateLimiter.hit(:countdown, 1, 10_000, base)
    assert {:error, late} = RateLimiter.hit(:countdown, 1, 10_000, base + 8_000)

    assert late < early
  end
end
