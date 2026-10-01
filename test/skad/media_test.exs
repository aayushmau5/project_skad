defmodule Skad.MediaTest do
  use Skad.DataCase

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Media
  alias Skad.Media.Item

  test "creates and retrieves quarantined metadata" do
    assert {:ok, item} = Media.create_item(valid_audio_attrs())
    assert item.visibility == :quarantine
    assert item.processing_state == :uploaded
    assert item.entry_id == nil
    assert item.concept_id == nil

    loaded = Media.get_item(item.public_id)
    assert loaded.id == item.id
    assert Ecto.assoc_loaded?(loaded.entry)
    assert Ecto.assoc_loaded?(loaded.concept)
    assert Media.get_item("not-a-uuid") == nil
  end

  test "creates metadata against active entry and concept targets" do
    entry = insert_entry()
    concept = Repo.get!(Concept, entry.concept_id)

    assert {:ok, audio} = Media.create_item(entry, valid_audio_attrs())
    assert audio.entry_id == entry.id
    assert audio.concept_id == nil

    assert {:ok, image} = Media.create_item(concept, valid_image_attrs())
    assert image.entry_id == nil
    assert image.concept_id == concept.id
  end

  test "persists a valid public update and rejects an unavailable public target" do
    entry = insert_entry()
    assert {:ok, item} = Media.create_item(entry, valid_audio_attrs())

    assert {:ok, public_item} =
             Media.update_item(item, %{
               processing_state: :ready,
               visibility: :public,
               public_object_key: "public/audio/#{item.public_id}.opus"
             })

    assert public_item.processing_state == :ready
    assert public_item.visibility == :public

    entry
    |> Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, changeset} =
             Media.update_item(public_item, %{attribution_text: "Community recording"})

    assert "or concept must reference an active target" in errors_on(changeset).entry_id
    assert Repo.get!(Item, item.id).attribution_text == nil
  end

  test "rejects archived targets and archived media" do
    entry = insert_entry()
    concept = Repo.get!(Concept, entry.concept_id)
    assert {:ok, item} = Media.create_item(valid_audio_attrs())
    archived_at = DateTime.utc_now(:second)

    concept |> Changeset.change(archived_at: archived_at) |> Repo.update!()
    item |> Changeset.change(archived_at: archived_at) |> Repo.update!()

    assert {:error, :target_unavailable} = Media.create_item(concept, valid_image_attrs())
    assert {:error, :target_unavailable} = Media.create_item(entry, valid_audio_attrs())
    assert Media.get_item(item.public_id) == nil
    assert {:error, :item_not_found} = Media.update_item(item, %{place_label: "Kinnaur"})
  end

  defp valid_audio_attrs do
    %{
      kind: :audio,
      original_object_key: "private/audio/#{Ecto.UUID.generate()}.wav",
      mime_type: "audio/wav",
      byte_size: 1_024,
      sha256: Ecto.UUID.generate(),
      duration_ms: 1_000
    }
  end

  defp valid_image_attrs do
    %{
      kind: :image,
      original_object_key: "private/images/#{Ecto.UUID.generate()}.jpg",
      mime_type: "image/jpeg",
      byte_size: 2_048,
      sha256: Ecto.UUID.generate(),
      width: 640,
      height: 480
    }
  end

  defp insert_entry do
    {:ok, language} =
      Archive.create_language(%{
        slug: "language-#{System.unique_integer([:positive])}",
        name: "Test language",
        direction: :ltr
      })

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    entry
  end
end
