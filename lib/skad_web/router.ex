defmodule SkadWeb.Router do
  use SkadWeb, :router

  import SkadWeb.ModeratorAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SkadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SkadWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/entries/:public_id", PageController, :entry
    get "/entries/:public_id/correct", ContributionController, :correct
    post "/entries/:public_id/corrections", ContributionController, :create_correction
    get "/entries/:public_id/add", ContributionController, :add
    post "/entries/:public_id/additions", ContributionController, :create_addition
    get "/entries/:public_id/examples/new", ContributionController, :example
    post "/entries/:public_id/examples", ContributionController, :create_example
    get "/entries/:public_id/audio/new", ContributionController, :audio
    post "/entries/:public_id/audio", ContributionController, :create_audio
    get "/entries/:public_id/images/new", ContributionController, :images
    post "/entries/:public_id/images", ContributionController, :create_images
    get "/contribute", ContributionController, :new
    post "/contributions", ContributionController, :create
    get "/contributions/:public_id", ContributionController, :show
    post "/media/uploads", MediaController, :prepare_upload
    post "/media/uploads/complete", MediaController, :complete_upload
    get "/media/:public_id", MediaController, :show
  end

  scope "/moderator", SkadWeb do
    pipe_through [:browser, :redirect_if_moderator_is_authenticated]

    get "/log-in", ModeratorSessionController, :new
    post "/log-in", ModeratorSessionController, :create
  end

  scope "/moderator", SkadWeb do
    pipe_through [:browser, :require_authenticated_moderator]

    get "/", ModeratorController, :home
    get "/concepts", ModeratorConceptController, :index
    post "/concepts", ModeratorConceptController, :create
    get "/concepts/:public_id", ModeratorConceptController, :show
    patch "/concepts/:public_id", ModeratorConceptController, :update
    post "/concepts/:public_id/media/uploads", ModeratorConceptController, :prepare_media

    post "/concepts/:public_id/media/uploads/complete",
         ModeratorConceptController,
         :complete_media

    get "/concepts/:public_id/media/:media_public_id/preview",
        ModeratorConceptController,
        :preview_media

    delete "/concepts/:public_id/media/:media_public_id",
           ModeratorConceptController,
           :remove_media

    get "/submissions", ModeratorSubmissionController, :index
    get "/submissions/:public_id", ModeratorSubmissionController, :show
    post "/submissions/:public_id/media", ModeratorSubmissionController, :attach_media

    get "/submissions/:public_id/media/:media_public_id/preview",
        ModeratorSubmissionController,
        :preview_media

    delete "/submissions/:public_id/media/:media_public_id",
           ModeratorSubmissionController,
           :remove_media

    patch "/submissions/:public_id/proposal", ModeratorSubmissionController, :update_proposal
    patch "/submissions/:public_id", ModeratorSubmissionController, :update
  end

  scope "/moderator", SkadWeb do
    pipe_through :browser

    delete "/log-out", ModeratorSessionController, :delete
  end

  # Other scopes may use custom stacks.
  # scope "/api", SkadWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:skad, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SkadWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
