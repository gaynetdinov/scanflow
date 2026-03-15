defmodule ScanflowWeb.Router do
  use ScanflowWeb, :router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ScanflowWeb.Layouts, :app})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", ScanflowWeb do
    pipe_through(:browser)

    get("/documents/:id/thumb", BatchDocumentController, :thumb)
    get("/batch/documents/:id/thumb", BatchDocumentController, :thumb)
    get("/batch/documents/:id/source", BatchDocumentController, :source)
    live("/", DocumentsLive, :index)
    live("/documents/:id", DocumentLive.Show, :show)
  end

  scope "/api", ScanflowWeb do
    pipe_through(:api)

    post("/ha/scan", AutomationController, :scan)
    post("/paperless/webhook", AutomationController, :paperless_webhook)
  end

  # Enables LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through([:fetch_session, :protect_from_forgery])

      live_dashboard("/dashboard", metrics: ScanflowWeb.Telemetry)
    end
  end
end
