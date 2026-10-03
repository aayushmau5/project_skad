defmodule SkadWeb.ErrorHTML do
  @moduledoc "HTML error pages with an accessible recovery path."
  use SkadWeb, :html

  def render(template, assigns) do
    locale =
      Map.get(assigns, :locale) || get_in(assigns, [:conn, Access.key(:assigns), :locale]) || "hi"

    Gettext.put_locale(SkadWeb.Gettext, locale)

    assigns =
      Map.merge(assigns, %{
        __changed__: nil,
        locale: locale,
        not_found?: String.starts_with?(template, "404")
      })

    ~H"""
    <!DOCTYPE html>
    <html lang={@locale}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{gettext("Page unavailable")} · Skad</title>
        <link rel="stylesheet" href={~p"/app.css"} />
      </head>
      <body>
        <Layouts.app flash={%{}} locale={@locale}>
          <section id="request-error" class="auth-panel">
            <h1>
              {if @not_found?,
                do: gettext("This page is unavailable"),
                else: gettext("We couldn’t complete this request")}
            </h1>
            <%= if @not_found? do %>
              <p>
                {gettext("The link may have changed. Search the archive to find the word again.")}
              </p>
            <% else %>
              <p>
                {gettext(
                  "Use your browser’s Back button to check your information, then try again. If you received a receipt, your suggestion was saved."
                )}
              </p>
            <% end %>
            <.link id="request-error-search" href={~p"/"}>{gettext("Back to search")}</.link>
          </section>
        </Layouts.app>
      </body>
    </html>
    """
  end
end
