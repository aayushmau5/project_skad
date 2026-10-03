defmodule SkadWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use SkadWeb, :html

  embed_templates "page_html/*"

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
