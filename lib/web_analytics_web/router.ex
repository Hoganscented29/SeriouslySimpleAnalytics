defmodule WebAnalyticsWeb.Router do
  use WebAnalyticsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WebAnalyticsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
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
    live "/dashboard", DashboardLive, :index

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
end
