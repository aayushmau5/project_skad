defmodule Skad.Archive.Words do
  @moduledoc false
  import Ecto.Query

  alias Skad.Archive
  alias Skad.Archive.{Entry, EntryForm, Search}
  alias Skad.Repo

  @page_size 20

  def count, do: Repo.aggregate(from(word in subquery(groups())), :count)

  def recent do
    groups()
    |> order_by([entry], desc: max(entry.id))
    |> limit(3)
    |> Repo.all()
    |> load_words()
  end

  def list(language, page) do
    query = groups(if(language, do: language.id))
    total_count = Repo.aggregate(from(word in subquery(query)), :count)
    page_count = max(1, div(total_count + @page_size - 1, @page_size))
    page = min(page_number(page), page_count)

    words =
      query
      |> order_by([_entry, _concept, form], asc: form.normalized_text, asc: form.language_id)
      |> limit(@page_size)
      |> offset(^((page - 1) * @page_size))
      |> Repo.all()
      |> load_words()

    %{entries: words, page: page, page_count: page_count, total_count: total_count}
  end

  def get(entry) do
    [%{id: entry.id}] |> load_words(true) |> List.first()
  end

  def search(query, language) do
    normalized = Archive.normalize_text(query)

    if is_binary(normalized) and normalized != "" do
      language_id = if language, do: language.id

      Search.word_matches(normalized, language_id)
      |> load_words()
      |> Enum.map(fn word ->
        result = Search.word_match(word.entry, normalized, word)
        Map.put(result, :meanings, word.meanings)
      end)
    else
      []
    end
  end

  defp groups(language_id \\ nil) do
    public_entries()
    |> join(:inner, [entry], form in assoc(entry, :forms), on: form.is_primary)
    |> then(fn query ->
      if language_id,
        do: where(query, [_entry, _concept, form], form.language_id == ^language_id),
        else: query
    end)
    |> group_by([_entry, _concept, form], [form.normalized_text, form.language_id])
    |> select([entry], %{id: min(entry.id)})
  end

  defp public_entries do
    Entry
    |> join(:inner, [entry], concept in assoc(entry, :concept))
    |> where([entry, concept], is_nil(entry.archived_at) and is_nil(concept.archived_at))
  end

  defp load_words(groups, full \\ false) do
    meanings = members(Enum.map(groups, & &1.id), full)

    Enum.flat_map(groups, fn %{id: id} = group ->
      entries = Map.get(meanings, id, [])

      # A moderator can archive the representative after the grouped query completes.
      case Enum.find(entries, &(&1.id == id)) do
        nil -> []
        entry -> [Map.merge(Map.delete(group, :id), %{entry: entry, meanings: entries})]
      end
    end)
  end

  defp members([], _full), do: %{}

  defp members(ids, full) do
    rows =
      public_entries()
      |> join(:inner, [entry], form in assoc(entry, :forms), on: form.is_primary)
      |> join(:inner, [entry, _concept, form], head in EntryForm,
        on:
          head.entry_id in ^ids and head.is_primary and head.language_id == entry.language_id and
            head.normalized_text == form.normalized_text
      )
      |> order_by([entry], asc: entry.id)
      |> select([entry, _concept, _form, head], {head.entry_id, entry})
      |> Repo.all()

    entries = Enum.map(rows, &elem(&1, 1))

    entries =
      if full,
        do: Archive.preload_public_entry(entries),
        else: Repo.preload(entries, [:language, :concept, :forms])

    rows
    |> Enum.map(&elem(&1, 0))
    |> Enum.zip(entries)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp page_number(page) when is_integer(page) and page > 0, do: page

  defp page_number(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp page_number(_page), do: 1
end
