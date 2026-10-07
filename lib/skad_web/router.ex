defmodule SkadWeb.Router do
  use SkadWeb, :router

  import Phoenix.LiveDashboard.Router
  import SkadWeb.ModeratorAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SkadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
    plug SkadWeb.InterfaceLocale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SkadWeb do
    pipe_through :api

    get "/health", HealthController, :health
    get "/ready", HealthController, :ready
  end

  scope "/", SkadWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/archive", PageController, :archive
    get "/search/results", PageController, :results
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

    live_dashboard "/dashboard",
      metrics: SkadWeb.Telemetry,
      home_app: {"Skad", :skad},
      ecto_repos: [Skad.Repo],
      on_mount: [{SkadWeb.ModeratorAuth, :ensure_authenticated}]

    get "/concepts", ModeratorConceptController, :index
    get "/concepts/new", ModeratorConceptController, :new
    get "/concepts/matches", ModeratorConceptController, :matches
    post "/concepts", ModeratorConceptController, :create
    get "/concepts/:public_id", ModeratorConceptController, :show
    patch "/concepts/:public_id", ModeratorConceptController, :update
    delete "/concepts/:public_id", ModeratorConceptController, :delete
    post "/concepts/:public_id/media/uploads", ModeratorConceptController, :prepare_media

    post "/concepts/:public_id/media/uploads/complete",
         ModeratorConceptController,
         :complete_media

    get "/concepts/:public_id/media/:media_public_id/preview",
        ModeratorConceptController,
        :preview_media

    delete "/concepts/:public_id/media/:media_public_id",
           ModeratorArchiveController,
           :delete_concept_media

    patch "/concepts/:public_id/media/:media_public_id",
          ModeratorArchiveController,
          :update_concept_media

    get "/words", ModeratorArchiveController, :index
    get "/entries/:public_id", ModeratorArchiveController, :entry
    patch "/entries/:public_id", ModeratorArchiveController, :update_entry
    delete "/entries/:public_id", ModeratorArchiveController, :delete_entry
    patch "/entries/:public_id/forms/:form_id", ModeratorArchiveController, :update_form
    delete "/entries/:public_id/forms/:form_id", ModeratorArchiveController, :delete_form

    patch "/entries/:public_id/media/:media_public_id",
          ModeratorArchiveController,
          :update_entry_media

    delete "/entries/:public_id/media/:media_public_id",
           ModeratorArchiveController,
           :delete_entry_media

    get "/examples/:public_id", ModeratorArchiveController, :example
    patch "/examples/:public_id", ModeratorArchiveController, :update_example
    delete "/examples/:public_id", ModeratorArchiveController, :delete_example

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

  # Enable the Swoosh mailbox preview in development.
  if Application.compile_env(:skad, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
