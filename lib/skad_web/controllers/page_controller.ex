defmodule SkadWeb.PageController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Media

  def archive(conn, params) do
    languages = Archive.list_active_languages()
    language = Enum.find(languages, &(&1.slug == params["language"]))
    archive = Archive.list_public_entries(language, params["page"])

    render(conn, :archive,
      page_title: gettext("Archive"),
      languages: languages,
      language: language,
      archive: archive
    )
  end

  def home(conn, params) do
    {languages, language, query, results} = search_data(params)

    search_form =
      Phoenix.Component.to_form(
        %{
          "q" => query,
          "language" => if(language, do: language.slug, else: "")
        },
        as: nil
      )

    render(conn, :home,
      page_title: gettext("Search"),
      search_form: search_form,
      languages: languages,
      entry_count: Archive.count_public_entries(),
      recent_entries: Archive.list_recent_public_entries(),
      results: results,
      searched?: query != ""
    )
  end

  def results(conn, params) do
    case search_data(params) do
      {_languages, _language, "", _results} ->
        send_resp(conn, :no_content, "")

      {languages, _language, _query, results} ->
        conn
        |> put_root_layout(false)
        |> put_layout(false)
        |> put_resp_header("cache-control", "private, no-store")
        |> render(:results, languages: languages, results: results)
    end
  end

  def entry(conn, %{"public_id" => public_id}) do
    case Archive.get_public_entry(public_id) do
      nil ->
        not_found(conn, gettext("Entry not found"))

      entry ->
        render(conn, :entry,
          page_title: SkadWeb.PageHTML.primary_form_text(entry),
          entry: entry,
          languages: Archive.list_active_languages(),
          audio: Media.get_public_entry_audio(entry),
          images: Media.list_public_concept_images(entry.concept)
        )
    end
  end

  def not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> put_view(SkadWeb.PageHTML)
    |> render(:missing, page_title: gettext("Page unavailable"), message: message)
  end

  defp search_data(params) do
    languages = Archive.list_active_languages()
    query = params |> Map.get("q", "") |> String.trim()
    language = Enum.find(languages, &(&1.slug == params["language"]))
    results = if query == "", do: [], else: Archive.search(query, language)
    {languages, language, query, results}
  end
end
