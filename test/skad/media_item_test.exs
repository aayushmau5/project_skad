defmodule Skad.MediaItemTest do
  use Skad.DataCase

  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.Language
  alias Skad.Media.Item

  test "persists media through an entry association" do
    entry = insert_entry()

    item =
      %Item{entry_id: entry.id}
      |> Item.changeset(valid_audio_attrs())
      |> Repo.insert!()

    assert {:ok, _public_id} = Ecto.UUID.cast(item.public_id)
    assert [loaded_item] = Repo.preload(entry, :media).media
    assert loaded_item.id == item.id
  end

  test "validates type-specific metadata and public state" do
    audio_changeset = Item.changeset(%Item{}, Map.put(valid_audio_attrs(), :width, 100))

    image_changeset =
      Item.changeset(
        %Item{},
        valid_audio_attrs()
        |> Map.merge(%{kind: :image, mime_type: "image/jpeg", width: 100, height: 100})
      )

    public_changeset =
      Item.changeset(%Item{}, Map.put(valid_audio_attrs(), :visibility, :public))

    ready_public_changeset =
      Item.changeset(
        %Item{entry_id: 1},
        valid_audio_attrs()
        |> Map.merge(%{
          processing_state: :ready,
          public_object_key: "public/audio/word.opus",
          visibility: :public
        })
      )

    refute audio_changeset.valid?
    assert "must be empty for audio" in errors_on(audio_changeset).width

    refute image_changeset.valid?
    assert "must be empty for images" in errors_on(image_changeset).duration_ms

    refute public_changeset.valid?
    assert "can't be blank" in errors_on(public_changeset).public_object_key

    assert "must be ready when media is public" in errors_on(public_changeset).processing_state

    assert "or concept must be present when media is public" in errors_on(public_changeset).entry_id

    assert ready_public_changeset.valid?
  end

  defp valid_audio_attrs do
    %{
      kind: :audio,
      original_object_key: "private/audio/#{Ecto.UUID.generate()}.wav",
      mime_type: "audio/wav",
      byte_size: 1_024,
      sha256: "checksum",
      duration_ms: 1_000
    }
  end

  defp insert_entry do
    language =
      %Language{}
      |> Language.changeset(%{
        slug: "english-#{System.unique_integer([:positive])}",
        name: "English",
        direction: :ltr
      })
      |> Repo.insert!()

    concept =
      %Concept{}
      |> Concept.changeset(%{editorial_label: "WATER"})
      |> Repo.insert!()

    %Entry{language_id: language.id, concept_id: concept.id}
    |> Entry.changeset(%{
      definitions: [%{language: "english", text: "A clear liquid."}]
    })
    |> Repo.insert!()
  end
end
