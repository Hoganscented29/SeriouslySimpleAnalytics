defmodule WebAnalyticsWeb.ReloadOnDeploy do
  @moduledoc """
  Reloads a long-lived tab after the server is redeployed.

  A dashboard left open for a week is running the markup and the JavaScript of
  whatever was deployed a week ago, talking to a server that has moved on. The
  socket reconnects and everything looks fine, which is the problem: the reader
  has no way to tell they are looking at an old build.

  `static_changed?/1` is how LiveView answers that — the client sends the digest
  of the static assets it loaded, and this is true when the server's no longer
  match. So it fires exactly once per deploy, on the reconnect that follows the
  restart, rather than on any old disconnection.

  The reload is asked for on the client rather than done with a redirect,
  because the tag has to be told first: without that, the new page counts as a
  second pageview against the same visit and starts its dwell time over. See
  `prepareReload` in the tracker.
  """
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and static_changed?(socket) do
      {:cont, push_event(socket, "wa:reload", %{})}
    else
      {:cont, socket}
    end
  end
end
