defmodule WebAnalyticsWeb.Router do
  use WebAnalyticsWeb, :router

  import WebAnalyticsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WebAnalyticsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Public, cross-origin, and cookie-free. No session or CSRF plugs here: the
  # tracker posts from other origins and must never carry ambient credentials.
  pipeline :public_api do
    plug WebAnalyticsWeb.Plugs.Cors
  end

  scope "/api/v1", WebAnalyticsWeb do
    pipe_through :public_api

    post "/collect", CollectController, :create
    match :options, "/collect", CollectController, :options
  end

  # The one-URL event API, deliberately outside /v1: it is the front door and
  # its shape is a promise, not a version.
  scope "/api", WebAnalyticsWeb do
    pipe_through :public_api

    get "/ping", PingController, :ping
    post "/ping", PingController, :ping
    match :options, "/ping", PingController, :ping

    # Lets an agent provision its own account ID before it has any data to
    # send, so integrating never requires a human to visit a signup form.
    post "/v1/accounts", AccountController, :create
    match :options, "/v1/accounts", AccountController, :options
  end

  scope "/", WebAnalyticsWeb do
    pipe_through :public_api

    get "/wa.js", TrackerController, :script
    # Served publicly and cross-origin so an agent can read the integration
    # contract before it ever sends anything.
    get "/llms.txt", LandingController, :llms
  end

  scope "/", WebAnalyticsWeb do
    pipe_through :browser

    get "/", LandingController, :home
    get "/AI-Analytics-llms-txt", LandingController, :ai

    # One page per AI crawler provider. Generated from the same registry that
    # holds the content, so a route can never point at a page that isn't written.
    get "/ai-crawler-analytics", ProviderController, :index

    for slug <- WebAnalytics.Crawlers.Provider.slugs() do
      get "/#{slug}-analytics", ProviderController, :show,
        as: :"#{String.replace(slug, "-", "_")}_analytics",
        assigns: %{provider_slug: slug}
    end

    get "/demo", DemoController, :home
    get "/demo/pricing", DemoController, :pricing
    get "/demo/docs", DemoController, :docs
    get "/demo/thanks", DemoController, :thanks
    post "/demo/signup", DemoController, :signup
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:web_analytics, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WebAnalyticsWeb.Telemetry
    end
  end

  ## Authentication routes

  scope "/", WebAnalyticsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{WebAnalyticsWeb.UserAuth, :require_authenticated}] do
      # The dashboard shows one account's data, so it lives behind the session
      # rather than picking a site out of everything on the box.
      live "/dashboard", DashboardLive, :index
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # Every account's data in one place, so the gate is its own live_session
  # rather than a check inside a shared one.
  scope "/", WebAnalyticsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_admin,
      on_mount: [{WebAnalyticsWeb.UserAuth, :require_admin}] do
      live "/admin", AdminLive, :index

      # The full dashboard, pointed at one account. A separate action rather
      # than a flag on /dashboard, so the ownership check there stays absolute.
      live "/admin/accounts/:key", DashboardLive, :admin
    end
  end

  scope "/", WebAnalyticsWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{WebAnalyticsWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
