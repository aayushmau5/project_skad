defmodule SkadWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use SkadWeb, :html

  embed_templates "page_html/*"

  def archive_path(language, page, locale) do
    params = %{page: page, ui_language: locale}
    params = if language, do: Map.put(params, :language, language.slug), else: params
    ~p"/archive?#{params}"
  end

  attr :results, :list, required: true
  attr :languages, :list, required: true

  def search_results(assigns) do
    ~H"""
    <section
      id="search-results"
      class="search-results"
      aria-labelledby="results-heading"
      data-result-count={length(@results)}
    >
      <h2 id="results-heading">{gettext("Results")}</h2>
      <div :if={@results == []} id="no-search-results">
        <p>{gettext("We haven’t found this word yet. Try another spelling or search by meaning.")}</p>
        <.link id="contribute-missing-word" href={~p"/contribute"}>{gettext(
          "Know this word? Share it for review"
        )}</.link>
      </div>
      <ol :if={@results != []} class="result-list">
        <li
          :for={result <- @results}
          id={"search-result-#{result.entry.public_id}"}
          class="result-card"
        >
          <.link
            href={~p"/entries/#{result.entry.public_id}"}
            class="result-link"
            lang={result.entry.language.code || result.entry.language.slug}
            dir={to_string(result.entry.language.direction)}
          >
            {primary_form_text(result.entry)}
          </.link>
          <p class="result-meta">
            {Enum.join(
              Enum.reject(
                [
                  language_label(result.entry.language),
                  result.entry.variety_label,
                  result.entry.place_label
                ],
                &is_nil/1
              ),
              " · "
            )}
          </p>
          <p
            :if={result_definition(result)}
            lang={result_definition_language(result, @languages)}
            dir="auto"
          >
            {result_definition(result)}
          </p>
          <p :if={result.matched_form && !result.matched_form.is_primary} class="result-meta">
            {form_match_label(result.matched_form.kind)}
            <span
              lang={result.entry.language.code || result.entry.language.slug}
              dir={to_string(result.entry.language.direction)}
            >{result.matched_form.text}</span>
          </p>
          <p :if={result.match_source in [:example, :context]} class="result-meta result-match">
            {context_match_label(result.match_source)}
            <span
              lang={result.entry.language.code || result.entry.language.slug}
              dir={to_string(result.entry.language.direction)}
            >{result.match_excerpt}</span>
          </p>
          <p :if={result.match_source == :concept} class="result-meta">
            {gettext("Related meaning")}
          </p>
        </li>
      </ol>
    </section>
    """
  end

  def primary_form(entry), do: Enum.find(entry.forms, & &1.is_primary)

  def primary_form_text(entry) do
    case primary_form(entry) do
      nil -> gettext("Untitled entry")
      form -> form.text
    end
  end

  def first_definition(entry) do
    case entry.definitions do
      [definition | _] -> definition.text
      [] -> nil
    end
  end

  def result_definition(%{match_source: :meaning, match_excerpt: excerpt})
      when is_binary(excerpt),
      do: excerpt

  def result_definition(result), do: first_definition(result.entry)

  def result_definition_language(result, languages) do
    definition = Enum.find(result.entry.definitions, &(&1.text == result_definition(result)))
    if definition, do: content_language(definition.language, languages), else: nil
  end

  def form_match_label(:transliteration), do: gettext("Matched transliteration:")
  def form_match_label(_kind), do: gettext("Matched form:")

  def context_match_label(:example), do: gettext("Matched example:")
  def context_match_label(:context), do: gettext("Matched in context:")

  def definition_language(entry, languages) do
    case entry.definitions do
      [definition | _] -> content_language(definition.language, languages)
      [] -> nil
    end
  end

  # Localized archive text stores language slugs; assistive technology needs
  # the corresponding language code. Keep the original slug in data-language.
  def content_language(tag, languages) do
    case Enum.find(languages, &(&1.slug == tag)) do
      nil -> tag
      language -> language.code || tag
    end
  end

  def form_label(:spelling), do: gettext("Spelling")
  def form_label(:alias), do: gettext("Local or alternative form")
  def form_label(:transliteration), do: gettext("Transliteration")
  def form_label(:historical), do: gettext("Historical form")

  def audio_duration(nil), do: gettext("Duration not recorded")
  def audio_duration(ms), do: gettext("Duration: %{seconds} seconds", seconds: div(ms, 1000))

  def equivalent_entries(entry) do
    Enum.reject(entry.concept.entries, &(&1.id == entry.id))
  end

  def examples(entry) do
    entry.example_links
    |> Enum.map(& &1.example)
    |> Enum.uniq_by(& &1.id)
  end

  def text_segments(text, spans) do
    {segments, offset} =
      Enum.reduce(spans, {[], 0}, fn span, {segments, offset} ->
        before = binary_part(text, offset, span.start_offset - offset)
        segments = if before == "", do: segments, else: [{:text, before} | segments]

        {[{:match, span} | segments], span.end_offset}
      end)

    after_matches = binary_part(text, offset, byte_size(text) - offset)
    segments = if after_matches == "", do: segments, else: [{:text, after_matches} | segments]

    Enum.reverse(segments)
  end
end
