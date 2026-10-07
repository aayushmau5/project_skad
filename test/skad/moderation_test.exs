defmodule Skad.ModerationTest do
  use Skad.DataCase
  import Skad.ModerationFixtures

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Archive.{Concept, Entry, EntryForm, Example, ExampleLink}
  alias Skad.Contributions.Revision
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Moderation

  setup do
    records()
  end

  test "rejects writes without an active moderator", %{
    water: water,
    example: example,
    scope: scope
  } do
    inactive = %{scope | moderator_account: %{scope.moderator_account | active: false}}

    for scope <- [nil, inactive] do
      assert {:error, :unauthorized} = Moderation.update_entry(scope, water, %{})

      assert {:error, :unauthorized} =
               Moderation.update_example(scope, example, %{text: "Changed"}, [])

      assert {:error, :unauthorized} = Moderation.delete_entry(scope, water, deletion())
      assert {:error, :unauthorized} = Moderation.delete_example(scope, example, deletion())
      assert {:error, :unauthorized} = Moderation.delete_concept(scope, water.concept, deletion())
    end

    assert Repo.aggregate(Revision, :count) == 0
  end

  test "edits the primary form, all meanings and context with searchable revision history", %{
    water: water,
    scope: scope
  } do
    assert {:ok, updated} =
             Moderation.update_entry(scope, water, %{
               "primary_form" => "  Drinking water  ",
               "language_id" => 999,
               "definitions" => [
                 %{"language" => "english", "text" => "Safe drinking water."},
                 %{"language" => "hindi", "text" => "पीने का पानी"}
               ],
               "usage_note" => "Offer to guests.",
               "cultural_note" => "Shared at gatherings.",
               "variety_label" => "Local",
               "place_label" => "Village",
               "part_of_speech" => "noun"
             })

    assert Enum.find(updated.forms, & &1.is_primary).text == "Drinking water"
    assert length(updated.definitions) == 2
    assert updated.language_id == water.language_id
    assert updated.place_label == "Village"
    assert [%{entry: %{id: id}} | _] = Archive.search("drinking")
    assert id == water.id
    assert Archive.exact_lookup("Water") == []
    revision = Repo.one!(Revision)
    assert revision.moderator_account_id == scope.moderator_account.id
    assert revision.before_state["forms"] |> Enum.any?(&(&1["text"] == "Water"))
    assert revision.after_state["forms"] |> Enum.any?(&(&1["text"] == "Drinking water"))
  end

  test "rolls back the word and search when its new primary form collides", %{
    water: water,
    scope: scope
  } do
    alternate = Enum.find(water.forms, &(not &1.is_primary))
    alternate |> Changeset.change(kind: :spelling) |> Repo.update!()

    assert {:error, %Changeset{}} =
             Moderation.update_entry(scope, water, %{
               primary_form: "H₂O",
               usage_note: "Must roll back."
             })

    assert Repo.get!(Entry, water.id).usage_note == "For drinking."
    assert [%{entry: %{id: id}}] = Archive.exact_lookup("Water")
    assert id == water.id
    assert Repo.aggregate(Revision, :count) == 0
  end

  test "edits and deletes alternate forms while preserving the primary and ownership", %{
    water: water,
    drink: drink,
    scope: scope
  } do
    alternate = Enum.find(water.forms, &(not &1.is_primary))
    primary = Enum.find(water.forms, & &1.is_primary)

    assert {:error, :not_found} =
             Moderation.update_form(scope, drink, alternate.id, %{text: "Wrong owner"})

    assert {:error, :primary_form_required} =
             Moderation.delete_form(scope, water, primary.id, deletion())

    assert {:ok, _} =
             Moderation.update_form(scope, water, alternate.id, %{
               text: "Aqua",
               kind: "historical",
               is_primary: true
             })

    assert Repo.get!(EntryForm, alternate.id).is_primary == false
    assert [%{entry: %{id: id}}] = Archive.exact_lookup("Aqua")
    assert id == water.id
    assert {:ok, _} = Moderation.delete_form(scope, water, alternate.id, deletion())
    assert Repo.get(EntryForm, alternate.id) == nil
    assert Archive.exact_lookup("Aqua") == []
    assert Repo.get!(EntryForm, primary.id).is_primary
    assert Repo.aggregate(Revision, :count) == 2
  end

  test "replaces example links and refreshes every linked word atomically", %{
    water: water,
    drink: drink,
    example: example,
    scope: scope
  } do
    links = [
      %{entry_public_id: drink.public_id, start_offset: 7, end_offset: 12, role: :focus},
      %{entry_public_id: water.public_id, start_offset: 13, end_offset: 18, role: :focus}
    ]

    assert {:ok, updated} =
             Moderation.update_example(
               scope,
               example,
               %{
                 text: "Please drink water.",
                 translations: [%{language: "hindi", text: "कृपया पानी पिएँ।"}]
               },
               links
             )

    assert updated.text == "Please drink water."
    assert Enum.map(updated.links, & &1.surface_text) |> Enum.sort() == ["drink", "water"]

    assert Archive.search("please") |> Enum.map(& &1.entry.id) |> Enum.sort() ==
             Enum.sort([drink.id, water.id])

    assert Repo.aggregate(ExampleLink, :count) == 2

    assert {:error, :overlapping_links} =
             Moderation.update_example(scope, updated, %{text: "Please drink water now."}, [
               hd(links),
               %{entry_public_id: water.public_id, start_offset: 10, end_offset: 18, role: :focus}
             ])

    assert Repo.get!(Example, example.id).text == "Please drink water."
    assert Repo.aggregate(Revision, :count) == 1
    assert {:ok, _} = Moderation.delete_example(scope, updated, deletion())
    assert Archive.search("please") == []
    assert Archive.get_public_entry(water.public_id).example_links == []
    assert Repo.get!(Example, example.id).archived_at != nil
  end

  test "requires confirmed deletion, keeps shared examples readable and withdraws audio", %{
    water: water,
    drink: drink,
    example: example,
    scope: scope
  } do
    audio = insert_audio(water)

    assert {:error, %Changeset{}} =
             Moderation.delete_entry(scope, water, %{"reason" => "No confirmation"})

    assert Archive.get_public_entry(water.public_id)
    assert {:ok, _} = Moderation.delete_entry(scope, water, deletion())
    assert Archive.get_public_entry(water.public_id) == nil
    assert Archive.exact_lookup("Water") == []

    assert Archive.get_public_entry(drink.public_id).example_links |> Enum.map(& &1.example.id) ==
             [example.id]

    assert Archive.get_public_entry(drink.public_id).example_links
           |> hd()
           |> Map.fetch!(:example)
           |> Map.fetch!(:links)
           |> Enum.all?(&(&1.entry != nil))

    assert Media.get_public_item(audio.public_id) == nil
    assert Repo.get!(Item, audio.id).visibility == :pending_deletion
    assert Repo.get!(Entry, water.id).archived_at != nil
    assert Repo.aggregate(Revision, :count) == 2
    assert {:ok, _} = Moderation.delete_concept(scope, water.concept, deletion())
    assert Repo.get!(Concept, water.concept_id).archived_at != nil
  end

  test "protects concepts containing words and restricts media edits to descriptive fields", %{
    water: water,
    scope: scope
  } do
    assert {:error, :concept_has_words} =
             Moderation.delete_concept(scope, water.concept, deletion())

    audio = insert_audio(water)

    assert {:ok, updated} =
             Moderation.update_media(scope, audio, %{
               attribution_text: "Recorded by community",
               place_label: "Village",
               public_object_key: "tampered",
               visibility: "quarantine",
               entry_id: 999
             })

    assert updated.attribution_text == "Recorded by community"
    assert updated.public_object_key == audio.public_object_key
    assert updated.visibility == :public
    assert updated.entry_id == water.id
    assert Repo.one!(Revision).after_state["attribution_text"] == "Recorded by community"
  end

  defp insert_audio(entry) do
    %Item{
      kind: :audio,
      original_object_key: "quarantine/test.mp3",
      public_object_key: "public/test.mp3",
      mime_type: "audio/mpeg",
      byte_size: 100,
      sha256: String.duplicate("a", 64),
      processing_state: :ready,
      visibility: :public,
      entry_id: entry.id
    }
    |> Repo.insert!()
  end
end
