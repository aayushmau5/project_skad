defmodule SkadWeb.ModeratorArchiveHTML do
  use SkadWeb, :html

  alias Skad.Moderation

  embed_templates "moderator_archive_html/*"

  defdelegate word(entry), to: SkadWeb.PageHTML, as: :primary_form_text
  defdelegate language_name(language), to: SkadWeb.CoreComponents, as: :language_label
  defdelegate first_definition(entry), to: SkadWeb.PageHTML
  defdelegate definition_language(entry, languages), to: SkadWeb.PageHTML

  def words_path(query, language, page, locale) do
    params = %{search: %{query: query}, page: page, ui_language: locale}
    params = if language, do: Map.put(params, :language, language.slug), else: params
    ~p"/moderator/words?#{params}"
  end

  def form_options do
    [
      {gettext("Spelling"), "spelling"},
      {gettext("Transliteration"), "transliteration"},
      {gettext("Historical form"), "historical"},
      {gettext("Alias"), "alias"}
    ]
  end

  def translation_language_options(languages, selected) do
    languages =
      Enum.uniq_by(
        languages ++
          [
            %{slug: "english", code: "en", name: "English"},
            %{slug: "hindi", code: "hi", name: "Hindi"}
          ],
        & &1.slug
      )

    options =
      Enum.map(languages, fn language ->
        value =
          if selected not in [nil, ""] && selected == language.code,
            do: selected,
            else: language.slug

        {language_name(language), value}
      end)

    if selected in [nil, ""] || Enum.any?(options, &(elem(&1, 1) == selected)),
      do: options,
      else: options ++ [{selected, selected}]
  end

  def word_form(form, errors) do
    id = "word-form-#{form.id}"
    Phoenix.Component.to_form(errors[id] || Moderation.change_form(form), as: :word_form, id: id)
  end

  def candidate_options(suggestion),
    do: SkadWeb.ModeratorSubmissionHTML.example_candidate_options(suggestion)

  def selected_choice(suggestion, choices) do
    Enum.find(choices, fn choice ->
      to_string(choice["start_offset"]) == to_string(suggestion.start_offset) and
        to_string(choice["end_offset"]) == to_string(suggestion.end_offset)
    end)
  end

  def selected_entry(suggestion, choices) do
    case selected_choice(suggestion, choices) do
      nil ->
        case suggestion.candidates do
          [entry] -> entry.public_id
          _ -> ""
        end

      choice ->
        choice["entry_public_id"]
    end
  end

  def selected_role(suggestion, choices) do
    case selected_choice(suggestion, choices) do
      nil -> to_string(suggestion.role)
      choice -> choice["role"]
    end
  end

  attr :id, :string, required: true
  attr :action, :string, required: true
  attr :label, :string, required: true
  attr :message, :string, required: true
  attr :errors, :map, default: %{}

  def deletion(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        Phoenix.Component.to_form(assigns.errors[assigns.id] || Moderation.change_deletion(),
          as: :deletion,
          id: assigns.id
        )
      )

    ~H"""
    <details id={"#{@id}-confirmation"} open={Map.has_key?(@errors, @id)}>
      <summary>{@label}</summary>
      <p>{@message}</p>
      <.form for={@form} action={@action} method="delete" id={@id} class="auth-form">
        <.input
          field={@form[:reason]}
          type="textarea"
          label={gettext("Reason for deletion")}
          class="auth-input"
          rows="2"
          required
        />
        <.input
          field={@form[:confirmed]}
          type="checkbox"
          label={gettext("I confirm this deletion.")}
          required
        />
        <button id={"#{@id}-submit"} type="submit" class="auth-button danger-button">{@label}</button>
      </.form>
    </details>
    """
  end

  attr :item, :map, required: true
  attr :action, :string, required: true
  attr :errors, :map, default: %{}

  def media_editor(assigns) do
    id = "media-#{assigns.item.public_id}"

    assigns =
      assign(
        assigns,
        :form,
        Phoenix.Component.to_form(assigns.errors[id] || Moderation.change_media(assigns.item),
          as: :media,
          id: id
        )
      )

    assigns = assign(assigns, :form_id, id)

    ~H"""
    <details id={"#{@form_id}-edit"} open={Map.has_key?(@errors, @form_id)}>
      <summary>{gettext("Edit media details")}</summary>
      <.form for={@form} action={@action} method="patch" id={@form_id} class="auth-form">
        <.input field={@form[:attribution_text]} label={gettext("Attribution")} class="auth-input" />
        <.input field={@form[:variety_label]} label={gettext("Language variety")} class="auth-input" />
        <.input field={@form[:place_label]} label={gettext("Village or place")} class="auth-input" />
        <button id={"#{@form_id}-save"} type="submit" class="auth-button">{gettext(
          "Save media details"
        )}</button>
      </.form>
    </details>
    <.deletion
      id={"delete-media-#{@item.public_id}"}
      action={@action}
      errors={@errors}
      label={gettext("Delete media")}
      message={gettext("This removes the recording or image from public pages. Its history is kept.")}
    />
    """
  end
end
