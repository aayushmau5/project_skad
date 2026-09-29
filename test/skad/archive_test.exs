defmodule Skad.ArchiveTest do
  use Skad.DataCase

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry

  test "configures and lists active languages" do
    assert Archive.list_active_languages() == []

    assert {:ok, english} =
             Archive.create_language(%{
               slug: "english",
               code: "en",
               name: "English",
               direction: :ltr
             })

    assert {:ok, _inactive} =
             Archive.create_language(%{
               slug: "hindi",
               code: "hi",
               name: "Hindi",
               direction: :ltr,
               active: false
             })

    assert Archive.list_active_languages() == [english]
    assert Archive.get_language_by_slug("english").id == english.id
  end

  test "publishes the first entry for a meaning as one complete record" do
    {:ok, language} = create_language()

    assert {:ok, entry} =
             Archive.publish_new_meaning(language, %{
               "concept" => %{"editorial_label" => "WATER"},
               "entry" => %{
                 "part_of_speech" => "noun",
                 "definitions" => [
                   %{
                     "language" => "english",
                     "text" => "A clear liquid used for drinking."
                   }
                 ]
               },
               "forms" => [
                 %{"text" => "Water", "kind" => "spelling", "is_primary" => "true"},
                 %{"text" => "H₂O", "kind" => "alias", "is_primary" => "false"}
               ]
             })

    assert entry.language.id == language.id
    assert entry.concept.editorial_label == "WATER"
    assert Enum.map(entry.forms, & &1.normalized_text) == ["water", "h₂o"]
    assert Enum.count(entry.concept.entries) == 1
    assert entry.example_links == []

    assert Archive.get_public_entry(entry.public_id).id == entry.id
  end

  test "rejects an incomplete form set before writing anything" do
    {:ok, language} = create_language()

    attrs = %{
      concept: %{editorial_label: "WATER"},
      entry: %{
        definitions: [%{language: "english", text: "A clear liquid."}]
      },
      forms: [
        %{text: "water", kind: :spelling, is_primary: true},
        %{text: "H₂O", kind: :alias, is_primary: true}
      ]
    }

    assert {:error, :exactly_one_primary_form_required} =
             Archive.publish_new_meaning(language, attrs)

    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "rolls back the meaning when a form is invalid" do
    {:ok, language} = create_language()

    attrs = %{
      concept: %{editorial_label: "WATER"},
      entry: %{
        definitions: [%{language: "english", text: "A clear liquid."}]
      },
      forms: [%{text: "water", kind: :unknown, is_primary: true}]
    }

    assert {:error, %Changeset{valid?: false}} = Archive.publish_new_meaning(language, attrs)
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "does not return archived public entries" do
    {:ok, language} = create_language()

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          definitions: [%{language: "english", text: "A clear liquid."}]
        },
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    entry
    |> Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert Archive.get_public_entry(entry.public_id) == nil
  end

  defp create_language do
    Archive.create_language(%{
      slug: "english",
      code: "en",
      name: "English",
      direction: :ltr
    })
  end
end
