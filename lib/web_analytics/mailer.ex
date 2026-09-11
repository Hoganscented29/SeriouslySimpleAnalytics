defmodule WebAnalytics.Mailer do
  @moduledoc """
  Sends the account emails: confirmation, password reset, address changes.

  In development mail goes to a local mailbox at `/dev/mailbox` rather than
  anywhere real. In production an SMTP host must be configured — see
  `config/runtime.exs`, which refuses to start without one rather than silently
  dropping the mail that lets people into their accounts.
  """
  use Swoosh.Mailer, otp_app: :web_analytics
end
