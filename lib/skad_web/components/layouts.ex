defmodule SkadWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SkadWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :locale, :string, default: "hi"
  attr :language_links, :map, default: %{"hi" => "/?ui_language=hi", "en" => "/?ui_language=en"}
  attr :moderator, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a id="skip-to-content" class="skip-link" href="#main-content">{gettext("Skip to content")}</a>
    <header id="site-header" class={["site-header", @moderator && "moderator-header"]}>
      <a id="site-wordmark" class="wordmark" href={~p"/"}>Skad<span :if={@moderator}> / {gettext(
        "Moderator"
      )}</span></a>
      <nav
        :if={@moderator && @current_scope}
        id="moderator-navigation"
        class="site-nav"
        aria-label={gettext("Moderator navigation")}
      >
        <.link id="moderator-workspace-link" href={~p"/moderator"}>{gettext("Workspace")}</.link>
        <.link id="moderator-queue-link" href={~p"/moderator/submissions"}>{gettext("Review queue")}</.link>
        <.link id="moderator-published-link" href={~p"/moderator/concepts"}>{gettext("Published")}</.link>
      </nav>
      <nav id="interface-language" class="language-switch" aria-label={gettext("Interface language")}>
        <a
          id="language-hi"
          href={@language_links["hi"]}
          lang="hi"
          hreflang="hi"
          aria-current={if @locale == "hi", do: "true"}
        >हिंदी</a>
        <span aria-hidden="true">/</span>
        <a
          id="language-en"
          href={@language_links["en"]}
          lang="en"
          hreflang="en"
          aria-current={if @locale == "en", do: "true"}
        >English</a>
      </nav>
      <.link
        :if={@moderator && @current_scope}
        id="moderator-log-out"
        href={~p"/moderator/log-out"}
        method="delete"
      >{gettext("Log out")}</.link>
    </header>
    <div id="connection-status" class="connection-status" role="status" hidden data-connection-status>
      {gettext(
        "You are offline. Keep this page open to retain your entered information. Reconnect before sending or uploading."
      )}
    </div>
    <main id="main-content" class={["site-main", @moderator && "moderator-main"]} tabindex="-1">
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </main>
    <footer id="site-footer" class="site-footer">
      <p>{gettext("A living archive of Kinnaur’s languages")}</p>
      <.link :if={!@moderator} id="contribute-link" href={~p"/contribute"}>{gettext("Suggest a word")}</.link>
      <.link :if={!@moderator} id="moderator-login-link" href={~p"/moderator/log-in"}>{gettext(
        "Moderator log in"
      )}</.link>
    </footer>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
