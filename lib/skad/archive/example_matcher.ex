defmodule Skad.Archive.ExampleMatcher do
  @moduledoc false

  import Ecto.Query

  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Language
  alias Skad.Repo

  @max_tokens 100
  @word ~r/[\p{L}\p{N}\p{M}]+(?:['’ʼ-][\p{L}\p{N}\p{M}]+)*/u

  def suggest(%Language{id: language_id}, text) do
    tokens = Regex.scan(@word, text, return: :index) |> Enum.map(&hd/1)

    if length(tokens) > @max_tokens do
      {:error, :example_too_long}
    else
      candidates = candidates(text, tokens)
      matches = matching_entries(language_id, candidates)

      suggestions =
        candidates
        |> Enum.flat_map(fn candidate ->
          case Map.get(matches, candidate.normalized_text, []) do
            [] -> []
            entries -> [Map.put(candidate, :candidates, entries)]
          end
        end)
        |> Enum.sort_by(fn candidate ->
          {-candidate.token_count, -(candidate.end_offset - candidate.start_offset),
           candidate.start_offset}
        end)
        |> Enum.reduce([], fn candidate, selected ->
          if Enum.any?(selected, &overlap?(&1, candidate)),
            do: selected,
            else: [candidate | selected]
        end)
        |> Enum.sort_by(& &1.start_offset)
        |> Enum.map(fn suggestion ->
          %{
            start_offset: suggestion.start_offset,
            end_offset: suggestion.end_offset,
            surface_text: suggestion.surface_text,
            candidates: suggestion.candidates,
            ambiguous?: length(suggestion.candidates) > 1
          }
        end)

      {:ok, suggestions}
    end
  end

  defp candidates(text, tokens) do
    last_index = length(tokens) - 1

    for {{start_offset, _length}, start_index} <- Enum.with_index(tokens),
        end_index <- start_index..last_index do
      {end_start, end_length} = Enum.at(tokens, end_index)
      end_offset = end_start + end_length
      surface_text = binary_part(text, start_offset, end_offset - start_offset)

      %{
        start_offset: start_offset,
        end_offset: end_offset,
        surface_text: surface_text,
        normalized_text: normalize_text(surface_text),
        token_count: end_index - start_index + 1
      }
    end
  end

  defp matching_entries(_language_id, []), do: %{}

  defp matching_entries(language_id, candidates) do
    normalized_texts = candidates |> Enum.map(& &1.normalized_text) |> Enum.uniq()

    rows =
      EntryForm
      |> join(:inner, [form], entry in Entry, on: entry.id == form.entry_id)
      |> join(:inner, [_form, entry], concept in assoc(entry, :concept))
      |> where(
        [form, entry, concept],
        form.language_id == ^language_id and form.normalized_text in ^normalized_texts and
          is_nil(entry.archived_at) and is_nil(concept.archived_at)
      )
      |> select([form, entry], {form.normalized_text, entry})
      |> Repo.all()

    entries_by_id =
      rows
      |> Enum.map(fn {_normalized_text, entry} -> entry end)
      |> Enum.uniq_by(& &1.id)
      |> Repo.preload([:concept, :language, :forms])
      |> Map.new(&{&1.id, &1})

    rows
    |> Enum.group_by(
      fn {normalized_text, _entry} -> normalized_text end,
      fn {_normalized_text, entry} -> Map.fetch!(entries_by_id, entry.id) end
    )
    |> Map.new(fn {normalized_text, entries} ->
      {normalized_text, entries |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)}
    end)
  end

  defp overlap?(left, right) do
    left.start_offset < right.end_offset and right.start_offset < left.end_offset
  end

  defp normalize_text(text) do
    text
    |> String.normalize(:nfc)
    |> String.trim()
    |> String.downcase()
  end
end
