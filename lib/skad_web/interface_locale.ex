defmodule SkadWeb.InterfaceLocale do
  @moduledoc "Selects a device's interface language without changing archive content."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = conn |> fetch_query_params() |> fetch_cookies()
    moderator? = String.starts_with?(conn.request_path, "/moderator")
    requested = conn.query_params["ui_language"]
    session_key = if moderator?, do: :moderator_locale, else: :interface_locale
    cookie_key = if moderator?, do: "skad_moderator_language", else: "skad_interface_language"
    default = if moderator?, do: "en", else: "hi"

    locale =
      if requested in ["en", "hi"],
        do: requested,
        else: conn.cookies[cookie_key] || get_session(conn, session_key) || default

    locale = if locale in ["en", "hi"], do: locale, else: default
    Gettext.put_locale(SkadWeb.Gettext, locale)

    # A language switch on a POST response must never replay that write as a GET.
    path = if conn.method == "GET", do: conn.request_path, else: "/"

    links =
      Map.new(
        ["hi", "en"],
        &{&1,
         path <> "?" <> Plug.Conn.Query.encode(Map.put(conn.query_params, "ui_language", &1))}
      )

    conn =
      if requested in ["en", "hi"] do
        put_resp_cookie(conn, cookie_key, locale,
          max_age: 31_536_000,
          same_site: "Lax",
          http_only: true,
          secure: Application.get_env(:skad, :secure_cookies, false)
        )
      else
        conn
      end

    conn
    |> put_session(session_key, locale)
    |> assign(:locale, locale)
    |> assign(:language_links, links)
    |> assign(:moderator_workspace?, moderator?)
  end
end
