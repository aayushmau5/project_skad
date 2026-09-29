defmodule Skad.ArchiveSearchStorageTest do
  use Skad.DataCase

  test "indexes each public text column but not identifiers" do
    insert_search_row(%{
      forms: "water",
      definitions: "a clear liquid",
      notes: "used in a ritual",
      examples: "the child drinks water"
    })

    assert matching_entry_ids("forms:water") == [1]
    assert matching_entry_ids("definitions:clear") == [1]
    assert matching_entry_ids("notes:ritual") == [1]
    assert matching_entry_ids("examples:child") == [1]
    assert matching_entry_ids("1") == []
    assert matching_entry_ids("99") == []
  end

  test "folds case and Latin diacritics for discovery" do
    insert_search_row(%{forms: "pāni"})

    assert matching_entry_ids("pani") == [1]
    assert matching_entry_ids("PANI") == [1]
  end

  test "keeps Devanagari combining marks inside the word" do
    insert_search_row(%{forms: "पानी"})

    assert matching_entry_ids("पानी") == [1]
    assert matching_entry_ids("पा") == []
    assert matching_entry_ids("पान") == []
  end

  test "weights forms above definitions, notes, and examples" do
    insert_search_row(%{entry_id: 1, forms: "marker"})
    insert_search_row(%{entry_id: 2, definitions: "marker"})
    insert_search_row(%{entry_id: 3, notes: "marker"})
    insert_search_row(%{entry_id: 4, examples: "marker"})

    result =
      Repo.query!(
        """
        SELECT entry_id
        FROM entry_search
        WHERE entry_search MATCH ?
        AND rank MATCH 'bm25(0.0, 0.0, 10.0, 5.0, 2.0, 1.0)'
        ORDER BY rank
        """,
        ["marker"]
      )

    assert List.flatten(result.rows) == [1, 2, 3, 4]
  end

  defp insert_search_row(attrs) do
    values =
      Map.merge(
        %{
          entry_id: 1,
          language_id: 99,
          forms: "",
          definitions: "",
          notes: "",
          examples: ""
        },
        attrs
      )

    Repo.query!(
      """
      INSERT INTO entry_search(
        rowid, entry_id, language_id, forms, definitions, notes, examples
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        values.entry_id,
        values.entry_id,
        values.language_id,
        values.forms,
        values.definitions,
        values.notes,
        values.examples
      ]
    )
  end

  defp matching_entry_ids(query) do
    Repo.query!(
      "SELECT entry_id FROM entry_search WHERE entry_search MATCH ? ORDER BY rowid",
      [query]
    ).rows
    |> List.flatten()
  end
end
