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
      nil -> "Untitled entry"
      form -> form.text
    end
  end

  def first_definition(entry) do
    case entry.definitions do
      [definition | _] -> definition.text
      [] -> nil
    end
  end

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
