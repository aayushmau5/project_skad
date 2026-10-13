defmodule Skad.Archive.IngestionTest do
  use Skad.DataCase

  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.Ingestion
  alias Skad.Archive.Language

  test "imports separate alternatives with shared meanings, context, and searchable descriptions" do
    data = manifest()
    assert {:ok, %{inserted: 2, skipped: 0}} = Ingestion.import(data)
    language = Archive.get_language_by_slug("hamskad")
    [first_spec, second_spec] = hd(data["meanings"])["entries"]
    first = Archive.get_public_entry(first_spec["public_id"])
    second = Archive.get_public_entry(second_spec["public_id"])

    assert first.concept_id == second.concept_id
    assert first.place_label == "Sangla"
    assert first.variety_label == "Tukpa"
    assert Enum.map(first.definitions, & &1.language) == ["english", "hindi"]
    assert [%{entry: %{public_id: id}} | _] = Archive.exact_lookup("रीसुर", language)
    assert id == first.public_id
    assert length(Archive.search("Avalanche", language)) == 2
    assert length(Archive.search("बर्फ", language)) == 2
  end

  test "rerunning skips stable imported IDs and preserves subsequent moderator edits" do
    data = manifest()
    assert {:ok, %{inserted: 2}} = Ingestion.import(data)
    spec = hd(hd(data["meanings"])["entries"])
    entry = Repo.get_by!(Entry, public_id: spec["public_id"])
    Repo.update!(Ecto.Changeset.change(entry, usage_note: "Reviewed by an elder"))

    assert {:ok, %{inserted: 0, skipped: 2}} = Ingestion.import(data)
    assert Repo.aggregate(Entry, :count) == 2
    assert Repo.aggregate(Concept, :count) == 1
    assert Repo.get!(Entry, entry.id).usage_note == "Reviewed by an elder"
  end

  test "an invalid later entry rolls back the language, concepts, entries, and search index" do
    data = manifest()
    [first, second] = hd(data["meanings"])["entries"]
    second = put_in(second, ["entry", "definitions"], [])
    data = put_in(data, ["meanings", Access.at(0), "entries"], [first, second])

    assert {:error, {:entry_failed, [3], _reason}} = Ingestion.import(data)
    assert Repo.aggregate(Language, :count) == 0
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.query!("SELECT count(*) FROM entry_search").rows == [[0]]
  end

  test "rejects malformed identities and identity conflicts without partial data" do
    data = manifest()
    assert {:error, :invalid_manifest} = Ingestion.import(%{"version" => 2})
    invalid = put_in(data, ["meanings", Access.at(0), "public_id"], "invalid")
    assert {:error, {:invalid_public_id, "invalid"}} = Ingestion.import(invalid)
    assert Repo.aggregate(Language, :count) == 0

    assert {:ok, _counts} = Ingestion.import(data)
    conflict = put_in(data, ["meanings", Access.at(0), "public_id"], Ecto.UUID.generate())
    assert {:error, {:identity_conflict, _id}} = Ingestion.import(conflict)
    assert Repo.aggregate(Concept, :count) == 1
  end

  test "rejects inactive languages" do
    {:ok, _language} =
      Archive.create_language(%{slug: "hamskad", name: "Hamskad", direction: :ltr, active: false})

    assert {:error, :language_inactive} = Ingestion.import(manifest())
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "rejects duplicate manifest IDs instead of silently dropping a record" do
    data = manifest()
    spec = hd(hd(data["meanings"])["entries"])

    invalid =
      put_in(
        data,
        ["meanings", Access.at(0), "entries", Access.at(1), "public_id"],
        spec["public_id"]
      )

    assert {:error, :duplicate_public_id} = Ingestion.import(invalid)
    assert Repo.aggregate(Language, :count) == 0
  end

  test "CSV preparation self-checks run with the project suite" do
    script = Path.expand("../../scripts/test_prepare_hamskad.py", __DIR__)
    assert {output, 0} = System.cmd("python3", ["-B", script], stderr_to_stdout: true)
    assert output =~ "OK"
  end

  defp manifest do
    entries =
      for {word, row} <- [{"रीसुर", 2}, {"लीसूर", 3}] do
        %{
          "public_id" => Ecto.UUID.generate(),
          "source_rows" => [row],
          "entry" => %{
            "definitions" => [
              %{"language" => "english", "text" => "Avalanche"},
              %{"language" => "hindi", "text" => "बर्फ की सरकती हुई चट्टान"}
            ],
            "place_label" => "Sangla",
            "variety_label" => "Tukpa"
          },
          "forms" => [%{"text" => word, "kind" => "spelling", "is_primary" => true}]
        }
      end

    %{
      "version" => 1,
      "language" => %{"slug" => "hamskad", "name" => "Hamskad", "direction" => "ltr"},
      "meanings" => [
        %{
          "public_id" => Ecto.UUID.generate(),
          "concept" => %{"editorial_label" => "Avalanche", "editorial_note" => "CSV rows 2, 3"},
          "entries" => entries
        }
      ]
    }
  end
end
