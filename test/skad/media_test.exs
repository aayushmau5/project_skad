defmodule Skad.MediaTest do
  use Skad.DataCase

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Contributions
  alias Skad.Contributions.Submission
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Media.Storage

  setup {Req.Test, :verify_on_exit!}

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

  test "prepares a short-lived image upload with a server-owned key" do
    concept = insert_concept()

    assert {:ok, instructions} = Media.prepare_image_upload(concept, valid_image_upload_attrs())

    uri = URI.parse(instructions.url)
    assert uri.host == "storage.test"
    assert String.starts_with?(uri.path, "/skad-test/private/images/")
    assert uri.query =~ "X-Amz-Expires=300"
    assert instructions.headers == %{"content-type" => "image/jpeg"}
    assert instructions.completion.kind == :image

    assert {:error, changeset} =
             Media.prepare_image_upload(
               concept,
               valid_image_upload_attrs()
               |> Map.put(:mime_type, "image/svg+xml")
               |> Map.put(:byte_size, 10 * 1024 * 1024 + 1)
               |> Map.put(:sha256, "not-a-sha256")
             )

    assert "is invalid" in errors_on(changeset).mime_type
    assert "must be less than or equal to 10485760" in errors_on(changeset).byte_size
    assert "has invalid format" in errors_on(changeset).sha256
  end

  test "completes an uploaded image idempotently" do
    concept = insert_concept()
    attrs = valid_image_upload_attrs()
    assert {:ok, instructions} = Media.prepare_image_upload(concept, attrs)

    expect_ready_copy(instructions.completion, attrs)

    assert {:ok, item} = Media.complete_image_upload(concept, instructions.completion)
    assert item.concept_id == concept.id
    assert item.original_object_key == instructions.completion.original_object_key

    assert item.public_object_key ==
             String.replace_prefix(item.original_object_key, "private/", "public/")

    assert item.processing_state == :ready
    assert item.visibility == :quarantine

    assert {:ok, repeated_item} =
             Media.complete_image_upload(concept, instructions.completion)

    assert repeated_item.id == item.id
    assert Repo.aggregate(Item, :count) == 1
  end

  test "does not record an upload whose stored size differs" do
    concept = insert_concept()
    attrs = valid_image_upload_attrs()
    assert {:ok, instructions} = Media.prepare_image_upload(concept, attrs)

    Req.Test.expect(Storage, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "1")
      |> Plug.Conn.put_resp_header("content-type", attrs.mime_type)
      |> Plug.Conn.send_resp(200, "")
    end)

    assert {:error, :object_metadata_mismatch} =
             Media.complete_image_upload(concept, instructions.completion)

    assert Repo.aggregate(Item, :count) == 0
  end

  test "does not record uploads when storage metadata is malformed or unavailable" do
    attrs = valid_image_upload_attrs()
    assert {:ok, malformed} = Media.prepare_upload(Map.put(attrs, :kind, :image))

    Req.Test.expect(Storage, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", Integer.to_string(attrs.byte_size))
      |> Plug.Conn.send_resp(200, "")
    end)

    assert {:error, :invalid_object_metadata} = Media.complete_upload(malformed.completion)

    assert {:ok, unavailable} = Media.prepare_upload(Map.put(attrs, :kind, :image))

    Req.Test.expect(Storage, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

    assert {:error, :storage_unavailable} = Media.complete_upload(unavailable.completion)
    assert Repo.aggregate(Item, :count) == 0
  end

  test "does not record an upload when the public copy fails" do
    attrs = valid_image_upload_attrs()
    assert {:ok, instructions} = Media.prepare_upload(Map.put(attrs, :kind, :image))
    expect_ready_copy(instructions.completion, attrs, 503)

    assert {:error, :storage_unavailable} = Media.complete_upload(instructions.completion)
    assert Repo.aggregate(Item, :count) == 0
  end

  test "rejects upload completion metadata that did not come from preparation" do
    assert {:ok, instructions} =
             Media.prepare_audio_upload(%{
               mime_type: "audio/webm",
               byte_size: 8_192,
               sha256: String.duplicate("c", 64)
             })

    forged_completion = %{
      instructions.completion
      | original_object_key: "private/images/#{Ecto.UUID.generate()}"
    }

    assert {:error, changeset} = Media.complete_upload(forged_completion)
    assert "is invalid" in errors_on(changeset).original_object_key
    assert Repo.aggregate(Item, :count) == 0
  end

  test "prepares and completes an unattached audio upload" do
    attrs = %{
      mime_type: "audio/webm;codecs=opus",
      byte_size: 8_192,
      sha256: String.duplicate("c", 64),
      variety_label: "Lower Kinnauri"
    }

    assert {:ok, instructions} = Media.prepare_audio_upload(attrs)
    assert URI.parse(instructions.url).path =~ "/skad-test/private/audio/"
    assert instructions.headers == %{"content-type" => "audio/webm"}
    assert instructions.completion.kind == :audio
    assert instructions.completion.mime_type == "audio/webm"

    expect_ready_copy(instructions.completion, %{byte_size: 8_192, mime_type: "audio/webm"})

    browser_completion =
      Map.new(instructions.completion, fn {key, value} -> {Atom.to_string(key), value} end)

    assert {:ok, item} = Media.complete_upload(browser_completion)
    assert item.kind == :audio
    assert item.entry_id == nil
    assert item.concept_id == nil
    assert item.submission_id == nil
    assert item.processing_state == :ready
    assert item.public_object_key =~ "/audio/"

    assert {:error, changeset} =
             Media.prepare_audio_upload(%{attrs | byte_size: 25 * 1024 * 1024 + 1})

    assert "must be less than or equal to 26214400" in errors_on(changeset).byte_size
  end

  test "attaches, replaces, and removes submission media within the agreed limits" do
    submission = insert_submission()
    first_audio = insert_unowned_audio()
    replacement_audio = insert_unowned_audio()

    assert {:ok, attached_audio} =
             Media.attach_item_to_submission(submission, first_audio)

    assert attached_audio.submission_id == submission.id

    assert {:error, :audio_already_attached} =
             Media.attach_item_to_submission(submission, replacement_audio)

    assert {:ok, replacement_audio} =
             Media.replace_submission_audio(submission, replacement_audio)

    assert replacement_audio.submission_id == submission.id
    assert Repo.get!(Item, first_audio.id).visibility == :pending_deletion
    assert Repo.get!(Item, first_audio.id).archived_at

    images = Enum.map(1..6, fn _index -> insert_unowned_image() end)

    images
    |> Enum.take(5)
    |> Enum.each(fn image ->
      assert {:ok, _image} = Media.attach_item_to_submission(submission, image)
    end)

    assert {:error, :image_limit_reached} =
             Media.attach_item_to_submission(submission, List.last(images))

    image = hd(images)
    assert {:ok, removed} = Media.remove_submission_item(submission, image)
    assert removed.visibility == :pending_deletion
    assert length(Media.list_submission_items(submission)) == 5
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

  defp valid_image_upload_attrs do
    %{
      mime_type: "image/jpeg",
      byte_size: 2_048,
      sha256: String.duplicate("a", 64),
      attribution_text: "Community archive"
    }
  end

  defp expect_ready_copy(completion, attrs, copy_status \\ 200) do
    Req.Test.expect(Storage, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/skad-test/#{completion.original_object_key}"

      conn
      |> Plug.Conn.put_resp_header("content-length", Integer.to_string(attrs.byte_size))
      |> Plug.Conn.put_resp_header("content-type", attrs.mime_type)
      |> Plug.Conn.send_resp(200, "")
    end)

    Req.Test.expect(Storage, fn conn ->
      destination = String.replace_prefix(completion.original_object_key, "private/", "public/")

      assert conn.method == "PUT"
      assert conn.request_path == "/skad-test/#{destination}"

      assert Plug.Conn.get_req_header(conn, "x-amz-copy-source") == [
               "/skad-test/#{completion.original_object_key}"
             ]

      Plug.Conn.send_resp(conn, copy_status, "")
    end)
  end

  defp insert_concept do
    %Concept{}
    |> Concept.changeset(%{editorial_label: "WATER"})
    |> Repo.insert!()
  end

  defp insert_submission do
    slug = "submission-language-#{System.unique_integer([:positive])}"

    {:ok, _language} =
      Archive.create_language(%{
        slug: slug,
        name: "Submission language",
        direction: :ltr
      })

    {:ok, receipt} =
      Contributions.submit_new_entry(%{
        client_submission_id: Ecto.UUID.generate(),
        language_slug: slug,
        primary_form: "word",
        definition: "meaning"
      })

    Repo.get_by!(Submission, public_id: receipt.public_id)
  end

  defp insert_unowned_audio do
    {:ok, item} = Media.create_item(valid_audio_attrs())
    item
  end

  defp insert_unowned_image do
    {:ok, item} = Media.create_item(valid_image_attrs())
    item
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
