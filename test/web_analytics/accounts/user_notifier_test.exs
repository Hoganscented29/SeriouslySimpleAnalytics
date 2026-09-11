defmodule WebAnalytics.Accounts.UserNotifierTest do
  use WebAnalytics.DataCase, async: true

  import WebAnalytics.AccountsFixtures

  alias WebAnalytics.Accounts

  # Asserting on the received message rather than through
  # Swoosh.TestAssertions.assert_email_sent/1: that helper treats the function's
  # return value as the match, and a block ending in `refute` returns false, so
  # a passing body reads as "no such email". The failure looks like a missing
  # email rather than a bad assertion, which is a bad hour to spend.
  defp sent_email do
    assert_receive {:email, email}
    email
  end

  describe "the from address" do
    test "is the one this deployment configured, not a generator placeholder" do
      user = unconfirmed_user_fixture()
      Accounts.deliver_login_instructions(user, &"https://example.com/users/log-in/#{&1}")

      {name, address} = sent_email().from

      # phx.gen.auth hardcodes contact@example.com. A provider refuses to send
      # from a domain it does not hold, and sign-in mail is the only way into an
      # account — so a wrong address here reads as broken registration.
      assert address == Application.get_env(:web_analytics, :mail_from)
      assert name == "SeriouslySimpleAnalytics"
      refute address == "contact@example.com"
      refute address =~ "@example.com"
    end
  end

  describe "sign-in mail" do
    test "carries the URL the caller built, which is the only way in" do
      user = unconfirmed_user_fixture()

      Accounts.deliver_login_instructions(user, fn token ->
        "https://seriouslysimpleanalytics.com/users/log-in/#{token}"
      end)

      email = sent_email()

      assert email.text_body =~ "https://seriouslysimpleanalytics.com/users/log-in/"
      assert email.to == [{"", user.email}]
    end

    test "a confirmed user gets a sign-in link rather than a confirmation one" do
      user = user_fixture()
      # Drop the confirmation mail the fixture itself triggered.
      assert_receive {:email, _}

      Accounts.deliver_login_instructions(user, &"https://example.com/users/log-in/#{&1}")

      assert sent_email().subject == "Log in instructions"
    end
  end
end
