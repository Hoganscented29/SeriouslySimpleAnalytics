defmodule WebAnalytics.Mailer.Stub do
  @moduledoc """
  A mail adapter that logs instead of sending.

  Used in production when no Mailgun key is configured. The alternatives are
  worse: no adapter crashes on the first send, and a silent one discards the
  message. The messages in question are the ones that let people into their
  accounts, so a deployment without mail credentials should be visibly degraded
  rather than broken in a way that reads as a bug in registration.
  """
  use Swoosh.Adapter

  require Logger

  @impl Swoosh.Adapter
  def deliver(email, _config) do
    Logger.warning("""
    Email NOT delivered — MAILGUN_API_KEY is not configured.

      to:      #{format(email.to)}
      subject: #{email.subject}

    #{email.text_body}
    """)

    {:ok, %{id: "stubbed"}}
  end

  @impl Swoosh.Adapter
  def deliver_many(emails, config) do
    {:ok, Enum.map(emails, fn email -> elem(deliver(email, config), 1) end)}
  end

  defp format(recipients) when is_list(recipients) do
    Enum.map_join(recipients, ", ", fn
      {"", address} -> address
      {name, address} -> "#{name} <#{address}>"
      address when is_binary(address) -> address
    end)
  end

  defp format(other), do: inspect(other)
end
