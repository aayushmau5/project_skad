defmodule SkadWeb.PageController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Media

  def home(conn, params) do
    languages = Archive.list_active_languages()
    query = params |> Map.get("q", "") |> String.trim()
    language = Enum.find(languages, &(&1.slug == params["language"]))

    results =
      if query == "" do
        []
      else
        Archive.search(query, language)
      end

    search_form =
      Phoenix.Component.to_form(
        %{
          "q" => query,
          "language" => if(language, do: language.slug, else: "")
        },
        as: nil
      )

    render(conn, :home,
      page_title: "Search",
      search_form: search_form,
      languages: languages,
      results: results,
      searched?: query != ""
    )
  end

  def entry(conn, %{"public_id" => public_id}) do
    case Archive.get_public_entry(public_id) do
      nil ->
        send_resp(conn, :not_found, "Entry not found")

      entry ->
        render(conn, :entry,
          page_title: SkadWeb.PageHTML.primary_form_text(entry),
          entry: entry,
          audio: Media.get_public_entry_audio(entry),
          images: Media.list_public_concept_images(entry.concept)
        )
    end
  end
end
