defmodule SkadWeb.ModeratorArchiveController do
  use SkadWeb, :controller

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Media
  alias Skad.Moderation

  def index(conn, params) do
    query = get_in(params, ["search", "query"]) || ""
    languages = Archive.list_active_languages()
    language = Enum.find(languages, &(&1.slug == params["language"]))

    render(conn, :index,
      page_title: gettext("Words"),
      word_page: Archive.list_public_entries(language, params["page"], query),
      query: query,
      language: language,
      languages: languages,
      search_form: Phoenix.Component.to_form(%{"query" => query}, as: :search)
    )
  end

  def entry(conn, %{"public_id" => id}) do
    with_entry(conn, id, &render_entry(conn, &1))
  end

  def update_entry(conn, %{"public_id" => id, "entry" => attrs} = params) do
    with_entry(conn, id, fn entry ->
      attrs =
        localized_attrs(
          attrs,
          "definitions",
          false,
          entry.language.slug,
          params["remove_meaning"]
        )

      cond do
        params["remove_meaning"] != nil ->
          render_entry(conn, entry, Moderation.change_entry(entry, attrs))

        params["intent"] == "add_meaning" ->
          attrs =
            localized_attrs(attrs, "definitions", true, List.first(entry.definitions).language)

          render_entry(conn, entry, Moderation.change_entry(entry, attrs))

        true ->
          case Moderation.update_entry(conn.assigns.current_scope, entry, attrs) do
            {:ok, _updated} ->
              saved(conn, ~p"/moderator/entries/#{id}", gettext("Word saved."))

            {:error, %Changeset{} = changeset} ->
              render_entry(put_status(conn, 422), entry, %{changeset | action: :update})

            {:error, reason} ->
              failed(conn, reason, ~p"/moderator/entries/#{id}")
          end
      end
    end)
  end

  def update_form(conn, %{"public_id" => id, "form_id" => form_id, "word_form" => attrs}) do
    with_entry(conn, id, fn entry ->
      case Moderation.update_form(conn.assigns.current_scope, entry, form_id, attrs) do
        {:ok, _updated} ->
          saved(conn, ~p"/moderator/entries/#{id}", gettext("Form saved."))

        {:error, %Changeset{} = changeset} ->
          render_entry(put_status(conn, 422), entry, nil, %{"word-form-#{form_id}" => changeset})

        {:error, reason} ->
          failed(conn, reason, ~p"/moderator/entries/#{id}")
      end
    end)
  end

  def delete_form(conn, %{"public_id" => id, "form_id" => form_id} = params) do
    with_entry(conn, id, fn entry ->
      case Moderation.delete_form(
             conn.assigns.current_scope,
             entry,
             form_id,
             params["deletion"] || %{}
           ) do
        {:ok, _updated} ->
          saved(conn, ~p"/moderator/entries/#{id}", gettext("Form deleted."))

        {:error, %Changeset{} = changeset} ->
          render_entry(put_status(conn, 422), entry, nil, %{"delete-form-#{form_id}" => changeset})

        {:error, reason} ->
          failed(conn, reason, ~p"/moderator/entries/#{id}")
      end
    end)
  end

  def delete_entry(conn, %{"public_id" => id} = params) do
    with_entry(conn, id, fn entry ->
      case Moderation.delete_entry(conn.assigns.current_scope, entry, params["deletion"] || %{}) do
        {:ok, _archived} ->
          saved(
            conn,
            ~p"/moderator/words",
            gettext("Word deleted.")
          )

        {:error, %Changeset{} = changeset} ->
          render_entry(put_status(conn, 422), entry, nil, %{"delete-word" => changeset})

        {:error, reason} ->
          failed(conn, reason, ~p"/moderator/entries/#{id}")
      end
    end)
  end

  def example(conn, %{"public_id" => id}) do
    with_example(conn, id, &render_example(conn, &1))
  end

  def update_example(conn, %{"public_id" => id, "example" => attrs} = params) do
    with_example(conn, id, fn example ->
      attrs =
        localized_attrs(
          attrs,
          "translations",
          params["intent"] == "add_translation",
          "",
          params["remove_translation"]
        )

      changeset = Moderation.change_example(example, attrs)
      text = Changeset.get_field(changeset, :text) || ""

      cond do
        params["intent"] in ["check_links", "add_translation"] ||
            params["remove_translation"] != nil ->
          choices =
            if params["links_version"] == links_version(text),
              do: Map.values(params["links"] || %{}),
              else: []

          render_example(conn, example, changeset, %{}, choices)

        params["links_version"] != links_version(text) ->
          conn
          |> put_flash(:info, gettext("Review the word links, then save the example."))
          |> render_example(example, changeset)

        true ->
          links = selected_links(params["links"] || %{})

          case Moderation.update_example(conn.assigns.current_scope, example, attrs, links) do
            {:ok, _updated} ->
              saved(conn, ~p"/moderator/examples/#{id}", gettext("Example saved."))

            {:error, %Changeset{} = changeset} ->
              render_example(
                put_status(conn, 422),
                example,
                %{changeset | action: :update},
                %{},
                links
              )

            {:error, reason} ->
              render_example(
                put_status(put_flash(conn, :error, error_message(reason)), 422),
                example,
                changeset,
                %{},
                links
              )
          end
      end
    end)
  end

  def delete_example(conn, %{"public_id" => id} = params) do
    with_example(conn, id, fn example ->
      case Moderation.delete_example(
             conn.assigns.current_scope,
             example,
             params["deletion"] || %{}
           ) do
        {:ok, _archived} ->
          saved(conn, example_return_path(example), gettext("Example deleted."))

        {:error, %Changeset{} = changeset} ->
          render_example(put_status(conn, 422), example, nil, %{"delete-example" => changeset})

        {:error, reason} ->
          failed(conn, reason, ~p"/moderator/examples/#{id}")
      end
    end)
  end

  def update_entry_media(conn, params), do: update_media(conn, Map.put(params, "owner", "entry"))

  def update_concept_media(conn, params),
    do: update_media(conn, Map.put(params, "owner", "concept"))

  def delete_entry_media(conn, params), do: delete_media(conn, Map.put(params, "owner", "entry"))

  def delete_concept_media(conn, params),
    do: delete_media(conn, Map.put(params, "owner", "concept"))

  defp update_media(conn, %{"media_public_id" => media_id, "media" => attrs} = params) do
    with_owned_media(conn, params, fn owner, item ->
      case Moderation.update_media(conn.assigns.current_scope, item, attrs) do
        {:ok, _item} ->
          saved(conn, owner_path(params, owner), gettext("Media details saved."))

        {:error, %Changeset{} = changeset} ->
          errors = %{"media-#{media_id}" => changeset}

          if params["owner"] == "entry",
            do: render_entry(put_status(conn, 422), owner, nil, errors),
            else: render_concept_error(conn, owner, errors)

        {:error, reason} ->
          failed(conn, reason, owner_path(params, owner))
      end
    end)
  end

  defp delete_media(conn, %{"media_public_id" => media_id} = params) do
    with_owned_media(conn, params, fn owner, item ->
      case Moderation.delete_media(conn.assigns.current_scope, item, params["deletion"] || %{}) do
        {:ok, _item} ->
          saved(conn, owner_path(params, owner), gettext("Media deleted."))

        {:error, %Changeset{} = changeset} ->
          errors = %{"delete-media-#{media_id}" => changeset}

          if params["owner"] == "entry",
            do: render_entry(put_status(conn, 422), owner, nil, errors),
            else: render_concept_error(conn, owner, errors)

        {:error, reason} ->
          failed(conn, reason, owner_path(params, owner))
      end
    end)
  end

  defp render_entry(conn, entry, changeset \\ nil, errors \\ %{}) do
    changeset = changeset || Moderation.change_entry(entry)

    render(conn, :entry,
      page_title: gettext("Edit word"),
      entry: entry,
      form: Phoenix.Component.to_form(changeset, as: :entry),
      meaning_count: length(Changeset.get_field(changeset, :definitions)),
      examples: Archive.list_entry_examples(entry),
      audio: Media.get_public_entry_audio(entry),
      errors: errors
    )
  end

  defp render_example(conn, example, changeset \\ nil, errors \\ %{}, choices \\ []) do
    changeset = changeset || Moderation.change_example(example)
    text = Changeset.get_field(changeset, :text) || ""
    {suggestions, match_error} = example_suggestions(example, text)

    render(conn, :example,
      page_title: gettext("Edit example"),
      example: example,
      languages: Archive.list_active_languages(),
      form: Phoenix.Component.to_form(changeset, as: :example),
      translation_count: length(Changeset.get_field(changeset, :translations)),
      suggestions: suggestions,
      choices: choices,
      match_error: match_error,
      links_version: links_version(text),
      back_path: example_return_path(example),
      errors: errors
    )
  end

  defp render_concept_error(conn, concept, errors) do
    conn
    |> put_status(422)
    |> put_view(SkadWeb.ModeratorConceptHTML)
    |> render(:show,
      page_title: concept.editorial_label,
      concept: concept,
      form:
        Phoenix.Component.to_form(
          Skad.Contributions.change_concept(conn.assigns.current_scope, concept),
          as: :concept
        ),
      media_items: Media.list_concept_images(concept),
      errors: errors
    )
  end

  defp with_entry(conn, id, work) do
    case Archive.get_public_entry(id) do
      nil -> send_resp(conn, 404, gettext("Word not found"))
      entry -> work.(entry)
    end
  end

  defp with_example(conn, id, work) do
    case Archive.get_example(id) do
      nil -> send_resp(conn, 404, gettext("Example not found"))
      example -> work.(example)
    end
  end

  defp with_owned_media(conn, params, work) do
    owner =
      if params["owner"] == "entry",
        do: Archive.get_public_entry(params["public_id"]),
        else: Archive.get_concept(params["public_id"])

    item = Media.get_item(params["media_public_id"])

    owned? =
      owner && item &&
        if(params["owner"] == "entry",
          do: item.entry_id == owner.id,
          else: item.concept_id == owner.id
        )

    if owned?, do: work.(owner, item), else: send_resp(conn, 404, gettext("Media not found"))
  end

  defp owner_path(%{"owner" => "entry"}, owner), do: ~p"/moderator/entries/#{owner.public_id}"
  defp owner_path(_params, owner), do: ~p"/moderator/concepts/#{owner.public_id}"

  defp example_return_path(example) do
    case Enum.find(example.links, &(Archive.get_public_entry(&1.entry.public_id) != nil)) do
      nil -> ~p"/moderator/concepts"
      link -> ~p"/moderator/entries/#{link.entry.public_id}"
    end
  end

  defp localized_attrs(attrs, field, add?, language, remove_index \\ nil) do
    remove = attrs["remove_#{field}"] || %{}
    remove = if remove_index, do: Map.put(remove, remove_index, "true"), else: remove
    current = if attrs[field] == "", do: [], else: attrs[field]

    items =
      if is_map(current),
        do:
          current
          |> Enum.sort_by(fn {key, _} -> Integer.parse(key) end)
          |> Enum.reject(fn {key, _} -> remove[key] == "true" end)
          |> Enum.map(&elem(&1, 1)),
        else: current

    items = if add?, do: (items || []) ++ [%{"language" => language, "text" => ""}], else: items
    if items, do: Map.put(attrs, field, items), else: attrs
  end

  defp selected_links(links) do
    links |> Map.values() |> Enum.reject(&(&1["entry_public_id"] in [nil, ""]))
  end

  defp example_suggestions(example, text) do
    case Archive.suggest_example_links(example.language, text) do
      {:error, reason} ->
        {[], reason}

      {:ok, suggestions} ->
        preserved =
          for link <- example.links,
              entry = Archive.get_public_entry(link.entry.public_id),
              entry != nil,
              {start, length} <- :binary.matches(text, link.surface_text) do
            %{
              start_offset: start,
              end_offset: start + length,
              surface_text: link.surface_text,
              role: link.role,
              candidates: [entry]
            }
          end

        preserved = Enum.uniq_by(preserved, &{&1.start_offset, &1.end_offset})

        additional =
          Enum.reject(suggestions, fn suggestion ->
            Enum.any?(
              preserved,
              &(suggestion.start_offset < &1.end_offset and
                  &1.start_offset < suggestion.end_offset)
            )
          end)

        {Enum.sort_by(preserved ++ additional, & &1.start_offset), nil}
    end
  end

  defp links_version(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp saved(conn, path, message), do: conn |> put_flash(:info, message) |> redirect(to: path)

  defp failed(conn, reason, path),
    do: conn |> put_flash(:error, error_message(reason)) |> redirect(to: path)

  defp error_message(:primary_form_required),
    do: gettext("Keep the primary word form. Edit it above instead.")

  defp error_message(:already_exists),
    do: gettext("This example already exists for one of the selected words.")

  defp error_message(:example_too_long),
    do: gettext("This example is too long to check. Shorten it and try again.")

  defp error_message(:not_found),
    do: gettext("This record is no longer available. Refresh the page.")

  defp error_message(_reason),
    do: gettext("The change could not be saved. Check the word links and try again.")
end
