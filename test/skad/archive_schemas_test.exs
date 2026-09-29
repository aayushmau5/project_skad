defmodule Skad.ArchiveSchemasTest do
  use Skad.DataCase

  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink
  alias Skad.Archive.Language

  test "persists the archive record graph" do
    {:ok, language} =
      %Language{}
      |> Language.changeset(%{
        slug: "english",
        code: "en",
        name: "English",
        direction: :ltr
      })
      |> Repo.insert()

    {:ok, concept} =
      %Concept{}
      |> Concept.changeset(%{editorial_label: "WATER"})
      |> Repo.insert()

    {:ok, entry} =
      %Entry{language_id: language.id, concept_id: concept.id}
      |> Entry.changeset(%{
        part_of_speech: "noun",
        definitions: [
          %{language: "english", text: "A clear liquid used for drinking."}
        ]
      })
      |> Repo.insert()

    {:ok, form} =
      %EntryForm{
        entry_id: entry.id,
        language_id: language.id,
        normalized_text: "water"
      }
      |> EntryForm.changeset(%{text: "water", kind: :spelling, is_primary: true})
      |> Repo.insert()

    {:ok, example} =
      %Example{language_id: language.id, normalized_text: "drink water"}
      |> Example.changeset(%{
        text: "Drink water.",
        translations: []
      })
      |> Repo.insert()

    {:ok, link} =
      %ExampleLink{example_id: example.id, entry_id: entry.id}
      |> ExampleLink.changeset(%{
        start_offset: 6,
        end_offset: 11,
        surface_text: "water",
        role: :focus
      })
      |> Repo.insert()

    assert {:ok, _public_id} = Ecto.UUID.cast(entry.public_id)
    assert form.entry_id == entry.id
    assert link.example_id == example.id
  end

  test "rejects malformed nested text, enums, and offsets" do
    entry_changeset =
      Entry.changeset(
        %Entry{language_id: 1, concept_id: 1},
        %{definitions: [%{language: "english", text: ""}]}
      )

    form_changeset =
      EntryForm.changeset(
        %EntryForm{entry_id: 1, language_id: 1, normalized_text: "word"},
        %{text: "word", kind: :phonetic}
      )

    link_changeset =
      ExampleLink.changeset(
        %ExampleLink{example_id: 1, entry_id: 1},
        %{start_offset: 4, end_offset: 4, surface_text: "word", role: :focus}
      )

    refute entry_changeset.valid?
    refute form_changeset.valid?
    assert "must be greater than start offset" in errors_on(link_changeset).end_offset
  end
end
