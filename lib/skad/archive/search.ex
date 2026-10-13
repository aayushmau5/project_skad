defmodule Skad.Archive.Search do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink
  alias Skad.Repo

  @limit 20

  # Rank written-form groups before limiting, so homographs cannot crowd out other words.
  def word_matches(query, language_id) do
    prefix =
      query
      |> String.replace("[", "[[]")
      |> String.replace("*", "[*]")
      |> String.replace("?", "[?]")

    sql = """
    WITH full_text AS MATERIALIZED (
      SELECT entry_id, rank AS score, forms, definitions, notes, examples
      FROM entry_search
      WHERE entry_search MATCH ?3
      AND rank MATCH 'bm25(0.0, 0.0, 10.0, 5.0, 2.0, 1.0)'
    ), direct AS (
      SELECT e.id, e.concept_id,
        CASE WHEN f.normalized_text = ?1 AND f.is_primary THEN 0
             WHEN f.normalized_text = ?1 THEN 1 ELSE 2 END AS priority,
        0 AS score, 'form' AS source, NULL AS forms, NULL AS definitions,
        NULL AS notes, NULL AS examples
      FROM entry_forms f
      JOIN entries e ON e.id = f.entry_id
      JOIN concepts c ON c.id = e.concept_id
      WHERE f.normalized_text GLOB ?2 AND e.archived_at IS NULL AND c.archived_at IS NULL
      UNION ALL
      SELECT e.id, e.concept_id, 3, f.score, 'fts', f.forms, f.definitions, f.notes, f.examples
      FROM full_text f
      JOIN entries e ON e.id = f.entry_id
      JOIN concepts c ON c.id = e.concept_id
      WHERE e.archived_at IS NULL AND c.archived_at IS NULL
    ), candidates AS (
      SELECT d.* FROM direct d
      JOIN entries e ON e.id = d.id
      WHERE ?4 IS NULL OR e.language_id = ?4
      UNION ALL
      SELECT e.id, e.concept_id, 4, 0, 'concept', NULL, NULL, NULL, NULL
      FROM entries e
      JOIN concepts c ON c.id = e.concept_id
      JOIN (SELECT DISTINCT concept_id FROM direct) d ON d.concept_id = e.concept_id
      WHERE e.archived_at IS NULL AND c.archived_at IS NULL
      AND (?4 IS NULL OR e.language_id = ?4)
    ), ranked AS (
      SELECT d.*, ROW_NUMBER() OVER (
        PARTITION BY e.language_id, p.normalized_text
        ORDER BY d.priority, d.score, e.id
      ) AS position
      FROM candidates d
      JOIN entries e ON e.id = d.id
      JOIN entry_forms p ON p.entry_id = e.id AND p.is_primary
    )
    SELECT id, source, forms, definitions, notes, examples
    FROM ranked WHERE position = 1
    ORDER BY priority, score, id LIMIT ?5
    """

    Repo.query!(sql, [query, prefix <> "*", fts_query(query), language_id, @limit]).rows
    |> Enum.map(fn [id, source, forms, definitions, notes, examples] ->
      {source, excerpt} =
        if source == "fts",
          do: match_source(query, forms, definitions, notes, examples),
          else: {if(source == "form", do: :form, else: :concept), nil}

      %{id: id, source: source, excerpt: excerpt}
    end)
  end

  def word_match(entry, query, match) do
    matched_form =
      if match.source == :form do
        entry.forms
        |> Enum.filter(&String.starts_with?(&1.normalized_text, query))
        |> Enum.min_by(
          &{if(&1.normalized_text == query, do: 0, else: 1), if(&1.is_primary, do: 0, else: 1),
           &1.id},
          fn -> Enum.find(entry.forms, &matches_text?(&1.text, query)) end
        )
      end

    %{
      entry: entry,
      matched_form: matched_form,
      match_source: if(matched_form, do: matched_form.kind, else: match.source),
      match_excerpt: match.excerpt
    }
  end

  def filter_entries(entries, query) when is_binary(query) and query != "" do
    where(
      entries,
      [entry],
      fragment(
        "? IN (SELECT entry_id FROM entry_search WHERE entry_search MATCH ?)",
        entry.id,
        ^fts_query(query)
      )
    )
  end

  def filter_entries(entries, _query), do: entries

  def full_text_lookup(query, language_id) when is_binary(query) and query != "" do
    sql = """
    SELECT entry_id, forms, definitions, notes, examples
    FROM entry_search
    WHERE entry_search MATCH ?
    AND rank MATCH 'bm25(0.0, 0.0, 10.0, 5.0, 2.0, 1.0)'
    #{if language_id, do: "AND language_id = ?", else: ""}
    ORDER BY rank
    LIMIT ?
    """

    params =
      if language_id,
        do: [fts_query(query), language_id, @limit],
        else: [fts_query(query), @limit]

    matches =
      sql
      |> Repo.query!(params)
      |> Map.fetch!(:rows)

    entry_ids = Enum.map(matches, &hd/1)

    entries_by_id =
      Entry
      |> join(:inner, [entry], concept in assoc(entry, :concept))
      |> where(
        [entry, concept],
        entry.id in ^entry_ids and is_nil(entry.archived_at) and is_nil(concept.archived_at)
      )
      |> Repo.all()
      |> Repo.preload([:language, :concept, forms: forms_query()])
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(matches, fn [entry_id, forms, definitions, notes, examples] ->
      case Map.fetch(entries_by_id, entry_id) do
        {:ok, entry} ->
          {source, excerpt} = match_source(query, forms, definitions, notes, examples)

          matched_form =
            if source == :form,
              do: Enum.find(entry.forms, &matches_text?(&1.text, query)),
              else: nil

          [
            %{
              entry: entry,
              matched_form: matched_form,
              match_source: source,
              match_excerpt: excerpt
            }
          ]

        :error ->
          []
      end
    end)
  end

  def full_text_lookup(_query, _language_id), do: []

  def refresh(repo, entry_ids) do
    entry_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn entry_id, {:ok, refreshed} ->
      case refresh_entry(repo, entry_id) do
        {:ok, entry_id} -> {:cont, {:ok, [entry_id | refreshed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, refreshed} -> {:ok, Enum.reverse(refreshed)}
      error -> error
    end
  end

  def rebuild do
    Repo.transaction(fn ->
      with {:ok, _result} <- Repo.query("DELETE FROM entry_search"),
           entry_ids <- active_entry_ids(),
           {:ok, _refreshed} <- refresh(Repo, entry_ids) do
        length(entry_ids)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp refresh_entry(repo, entry_id) do
    case searchable_entry(repo, entry_id) do
      nil -> delete_entry(repo, entry_id)
      entry -> replace_entry(repo, entry)
    end
  end

  defp searchable_entry(repo, entry_id) do
    Entry
    |> join(:inner, [entry], concept in assoc(entry, :concept))
    |> where(
      [entry, concept],
      entry.id == ^entry_id and is_nil(entry.archived_at) and is_nil(concept.archived_at)
    )
    |> preload([entry], forms: ^forms_query())
    |> repo.one()
  end

  defp replace_entry(repo, entry) do
    with {:ok, _deleted} <- repo.query("DELETE FROM entry_search WHERE rowid = ?", [entry.id]),
         {:ok, _inserted} <-
           repo.query(
             """
             INSERT INTO entry_search(
               rowid, entry_id, language_id, forms, definitions, notes, examples
             ) VALUES (?, ?, ?, ?, ?, ?, ?)
             """,
             [
               entry.id,
               entry.id,
               entry.language_id,
               join_text(entry.forms, & &1.text),
               join_text(entry.definitions, & &1.text),
               join_text([entry.usage_note, entry.cultural_note]),
               focus_examples(repo, entry.id) |> join_text()
             ]
           ) do
      {:ok, entry.id}
    end
  end

  defp delete_entry(repo, entry_id) do
    case repo.query("DELETE FROM entry_search WHERE rowid = ?", [entry_id]) do
      {:ok, _result} -> {:ok, entry_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp focus_examples(repo, entry_id) do
    ExampleLink
    |> join(:inner, [link], example in Example, on: example.id == link.example_id)
    |> where(
      [link, example],
      link.entry_id == ^entry_id and link.role == :focus and is_nil(example.archived_at)
    )
    |> group_by([_link, example], [example.id, example.text])
    |> order_by([_link, example], asc: example.id)
    |> select([_link, example], example.text)
    |> repo.all()
  end

  defp active_entry_ids do
    Entry
    |> join(:inner, [entry], concept in assoc(entry, :concept))
    |> where([entry, concept], is_nil(entry.archived_at) and is_nil(concept.archived_at))
    |> order_by([entry], asc: entry.id)
    |> select([entry], entry.id)
    |> Repo.all()
  end

  defp forms_query do
    from form in EntryForm,
      order_by: [desc: form.is_primary, asc: form.id]
  end

  defp join_text(items, mapper \\ & &1) do
    items
    |> Enum.map(mapper)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n")
  end

  defp fts_query(query) do
    query
    |> String.split()
    |> Enum.map_join(" AND ", fn term ->
      escaped = String.replace(term, "\"", "\"\"")
      "\"#{escaped}\"*"
    end)
  end

  defp match_source(query, forms, definitions, notes, examples) do
    [form: forms, meaning: definitions, example: examples, context: notes]
    |> Enum.find_value({:related, nil}, fn {source, text} ->
      if line = matching_line(text, query), do: {source, line}
    end)
  end

  defp matching_line(text, query) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.find(&matches_text?(&1, query))
  end

  defp matching_line(_text, _query), do: nil

  defp matches_text?(text, query) when is_binary(text) do
    text = String.downcase(text)
    Enum.all?(String.split(query), &String.contains?(text, &1))
  end

  defp matches_text?(_text, _query), do: false
end
