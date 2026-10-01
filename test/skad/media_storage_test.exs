defmodule Skad.MediaStorageTest do
  use Skad.DataCase

  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.Language
  alias Skad.Contributions.Submission

  test "enforces one active audio item per entry while retaining withdrawn history" do
    entry_id = insert_entry()
    insert_media(entry_id: entry_id)

    assert_raise Exqlite.Error, fn ->
      insert_media(entry_id: entry_id)
    end

    Repo.query!(
      "UPDATE media SET visibility = 'withdrawn' WHERE entry_id = ?",
      [entry_id]
    )

    insert_media(entry_id: entry_id)

    assert [[2]] =
             Repo.query!("SELECT count(*) FROM media WHERE entry_id = ?", [entry_id]).rows
  end

  test "enforces one active audio item per submission while retaining withdrawn history" do
    submission_id = insert_submission()
    insert_media(submission_id: submission_id)

    assert_raise Exqlite.Error, fn ->
      insert_media(submission_id: submission_id)
    end

    Repo.query!(
      "UPDATE media SET visibility = 'withdrawn' WHERE submission_id = ?",
      [submission_id]
    )

    insert_media(submission_id: submission_id)

    assert [[2]] =
             Repo.query!("SELECT count(*) FROM media WHERE submission_id = ?", [submission_id]).rows
  end

  test "enforces media type, metadata, lifecycle, and uniqueness constraints" do
    assert_raise Exqlite.Error, fn ->
      insert_media(kind: "video")
    end

    assert_raise Exqlite.Error, fn ->
      insert_media(width: 100, height: 100)
    end

    assert_raise Exqlite.Error, fn ->
      insert_media(visibility: "public")
    end

    object_key = "private/originals/duplicate.wav"
    insert_media(original_object_key: object_key)

    assert_raise Exqlite.Error, fn ->
      insert_media(original_object_key: object_key)
    end
  end

  defp insert_media(overrides) do
    suffix = System.unique_integer([:positive])

    values =
      Map.merge(
        %{
          public_id: Ecto.UUID.generate(),
          kind: "audio",
          entry_id: nil,
          concept_id: nil,
          submission_id: nil,
          original_object_key: "private/originals/#{suffix}.wav",
          public_object_key: nil,
          mime_type: "audio/wav",
          byte_size: 1_024,
          sha256: "sha256-#{suffix}",
          duration_ms: 1_000,
          width: nil,
          height: nil,
          processing_state: "uploaded",
          visibility: "quarantine"
        },
        Map.new(overrides)
      )

    [[id]] =
      Repo.query!(
        """
        INSERT INTO media(
          public_id,
          kind,
          entry_id,
          concept_id,
          submission_id,
          original_object_key,
          public_object_key,
          mime_type,
          byte_size,
          sha256,
          duration_ms,
          width,
          height,
          processing_state,
          visibility
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING id
        """,
        [
          values.public_id,
          values.kind,
          values.entry_id,
          values.concept_id,
          values.submission_id,
          values.original_object_key,
          values.public_object_key,
          values.mime_type,
          values.byte_size,
          values.sha256,
          values.duration_ms,
          values.width,
          values.height,
          values.processing_state,
          values.visibility
        ]
      ).rows

    id
  end

  defp insert_submission do
    %Submission{kind: :new_entry}
    |> Submission.changeset(%{
      client_submission_id: Ecto.UUID.generate(),
      payload: %{"primary_form" => "water"}
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
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
    |> Map.fetch!(:id)
  end
end
