defmodule Skad.Media do
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Contributions.Submission
  alias Skad.Media.Item
  alias Skad.Media.Storage
  alias Skad.Repo

  @audio_mime_types ~w(audio/m4a audio/mpeg audio/mp4 audio/ogg audio/wav audio/webm audio/x-m4a audio/x-wav)
  @image_mime_types ~w(image/jpeg image/png image/webp)
  @max_audio_bytes 25 * 1024 * 1024
  @max_image_bytes 10 * 1024 * 1024
  @max_submission_images 5

  def change_item(%Item{} = item, attrs \\ %{}) when is_map(attrs) do
    Item.changeset(item, attrs)
  end

  def create_item(attrs) when is_map(attrs) do
    %Item{}
    |> change_item(attrs)
    |> Repo.insert()
  end

  def create_item(_attrs), do: {:error, :invalid_attributes}

  def create_item(%Entry{} = entry, attrs) when is_map(attrs) do
    with {:ok, entry} <- available_target(entry) do
      %Item{entry_id: entry.id}
      |> change_item(attrs)
      |> Repo.insert()
    end
  end

  def create_item(%Concept{} = concept, attrs) when is_map(attrs) do
    with {:ok, concept} <- available_target(concept) do
      %Item{concept_id: concept.id}
      |> change_item(attrs)
      |> Repo.insert()
    end
  end

  def create_item(%Submission{} = submission, attrs) when is_map(attrs) do
    with {:ok, submission} <- available_target(submission) do
      %Item{submission_id: submission.id}
      |> change_item(attrs)
      |> Repo.insert()
    end
  end

  def create_item(_target, _attrs), do: {:error, :invalid_attributes}

  def list_concept_images(%Concept{id: id}) when is_integer(id) do
    Item
    |> where(
      [item],
      item.concept_id == ^id and item.kind == :image and is_nil(item.archived_at)
    )
    |> order_by([item], desc: item.id)
    |> Repo.all()
  end

  def list_concept_images(_concept), do: []

  def get_public_entry_audio(%Entry{id: id}) when is_integer(id) do
    Item
    |> where(
      [item],
      item.entry_id == ^id and item.kind == :audio and item.visibility == :public and
        is_nil(item.archived_at)
    )
    |> Repo.one()
  end

  def get_public_entry_audio(_entry), do: nil

  def get_public_item(public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Item
      |> where(
        [item],
        item.public_id == ^public_id and item.visibility == :public and
          is_nil(item.archived_at)
      )
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def list_public_concept_images(%Concept{id: id}) when is_integer(id) do
    Item
    |> where(
      [item],
      item.concept_id == ^id and item.kind == :image and item.visibility == :public and
        is_nil(item.archived_at)
    )
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  def list_public_concept_images(_concept), do: []

  def list_submission_items(%Submission{id: id}) when is_integer(id) do
    list_submission_items_with_repo(Repo, id)
  end

  def list_submission_items(_submission), do: []

  def prepare_upload(attrs) when is_map(attrs) do
    kind = attrs |> upload_value(:kind) |> normalized_kind()
    object_key = "private/#{object_directory(kind)}/#{Ecto.UUID.generate()}"

    changeset =
      %Item{}
      |> change_item(upload_attrs(attrs, kind, object_key))
      |> validate_upload(kind)

    with {:ok, item} <- Changeset.apply_action(changeset, :prepare),
         {:ok, instructions} <- Storage.presign_put(item.original_object_key, item.mime_type) do
      {:ok, Map.put(instructions, :completion, upload_completion(item))}
    end
  end

  def prepare_upload(_attrs), do: {:error, :invalid_attributes}

  def prepare_audio_upload(attrs) when is_map(attrs),
    do: prepare_upload(Map.put(attrs, :kind, :audio))

  def prepare_audio_upload(_attrs), do: {:error, :invalid_attributes}

  def prepare_image_upload(%Concept{} = concept, attrs) when is_map(attrs) do
    with {:ok, _concept} <- available_target(concept) do
      prepare_upload(Map.put(attrs, :kind, :image))
    end
  end

  def prepare_image_upload(_concept, _attrs), do: {:error, :invalid_attributes}

  def complete_upload(completion), do: complete_upload(nil, completion)

  def complete_upload(owner, completion) when is_map(completion) do
    case normalized_completion(completion) do
      %{version: 1, kind: kind} = completion when kind in [:audio, :image] ->
        with {:ok, completion} <- validated_completion(completion) do
          complete_validated_upload(owner, completion)
        end

      _invalid_completion ->
        {:error, :invalid_upload}
    end
  end

  def complete_upload(_owner, _completion), do: {:error, :invalid_upload}

  def complete_image_upload(%Concept{} = concept, completion) when is_map(completion) do
    if normalized_kind(upload_value(completion, :kind)) == :image,
      do: complete_upload(concept, completion),
      else: {:error, :invalid_upload}
  end

  def complete_image_upload(_concept, _completion), do: {:error, :invalid_upload}

  defp complete_validated_upload(owner, completion) do
    public_object_key =
      String.replace_prefix(completion.original_object_key, "private/", "public/")

    with {:ok, owner} <- available_owner(owner),
         nil <- Repo.get_by(Item, original_object_key: completion.original_object_key),
         {:ok, object} <- Storage.head_object(completion.original_object_key),
         :ok <- object_matches(object, completion),
         :ok <- Storage.copy_object(completion.original_object_key, public_object_key) do
      owner
      |> item_for_owner()
      |> change_item(%{
        kind: completion.kind,
        original_object_key: completion.original_object_key,
        public_object_key: public_object_key,
        mime_type: completion.mime_type,
        byte_size: completion.byte_size,
        sha256: completion.sha256,
        processing_state: :ready,
        variety_label: completion.variety_label,
        place_label: completion.place_label,
        attribution_text: completion.attribution_text
      })
      |> Repo.insert()
    else
      %Item{} = item -> idempotent_completion(item, owner, completion)
      {:error, reason} -> {:error, reason}
    end
  end

  def claim_submission_items_multi(multi, public_ids, expected_kind \\ nil)

  def claim_submission_items_multi(%Multi{} = multi, public_ids, expected_kind)
      when is_list(public_ids) and expected_kind in [nil, :audio, :image] do
    Multi.run(multi, :media, fn repo, %{submission: submission} ->
      claim_submission_items(repo, submission, public_ids, expected_kind)
    end)
  end

  def validate_entry_submission(%Entry{} = entry, :audio, [public_id]) do
    case get_item(public_id) do
      %Item{
        kind: :audio,
        processing_state: :ready,
        visibility: :quarantine,
        submission_id: nil,
        entry_id: nil,
        concept_id: nil
      } = item ->
        case get_public_entry_audio(entry) do
          %Item{sha256: sha256} when sha256 == item.sha256 -> {:error, :already_exists}
          _other -> :ok
        end

      _invalid_item ->
        {:error, :invalid_media}
    end
  end

  def validate_entry_submission(%Entry{} = entry, :image, public_ids)
      when is_list(public_ids) and public_ids != [] and
             length(public_ids) <= @max_submission_images do
    items = Enum.map(public_ids, &get_item/1)

    valid? =
      Enum.uniq(public_ids) == public_ids and
        Enum.all?(items, fn
          %Item{
            kind: :image,
            processing_state: :ready,
            visibility: :quarantine,
            submission_id: nil,
            entry_id: nil,
            concept_id: nil
          } ->
            true

          _other ->
            false
        end)

    existing_hashes =
      entry.concept
      |> list_public_concept_images()
      |> MapSet.new(& &1.sha256)

    cond do
      not valid? -> {:error, :invalid_media}
      Enum.any?(items, &MapSet.member?(existing_hashes, &1.sha256)) -> {:error, :already_exists}
      true -> :ok
    end
  end

  def validate_entry_submission(%Entry{}, kind, _public_ids) when kind in [:audio, :image],
    do: {:error, :invalid_media}

  def attach_item_to_submission(%Submission{} = submission, %Item{id: id})
      when is_integer(id) do
    with {:ok, submission} <- available_target(submission),
         %Item{} = item <- available_unowned_item(id),
         :ok <- attachment_available?(submission, item) do
      item
      |> Changeset.change(submission_id: submission.id)
      |> Repo.update()
    else
      nil -> {:error, :item_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_item_to_submission(_submission, _item), do: {:error, :invalid_attributes}

  def replace_submission_audio(%Submission{} = submission, %Item{id: id})
      when is_integer(id) do
    with {:ok, submission} <- available_target(submission),
         %Item{kind: :audio} = item <- available_unowned_item(id) do
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        Item
        |> where(
          [stored],
          stored.submission_id == ^submission.id and stored.kind == :audio and
            is_nil(stored.archived_at) and
            stored.visibility not in [:withdrawn, :pending_deletion]
        )
        |> Repo.update_all(set: [visibility: :pending_deletion, archived_at: now])

        item
        |> Changeset.change(submission_id: submission.id)
        |> Repo.update!()
      end)
    else
      nil -> {:error, :item_not_found}
      %Item{} -> {:error, :invalid_media_kind}
      {:error, reason} -> {:error, reason}
    end
  end

  def replace_submission_audio(_submission, _item), do: {:error, :invalid_attributes}

  def remove_submission_item(%Submission{} = submission, %Item{id: id})
      when is_integer(id) do
    with {:ok, submission} <- available_target(submission),
         %Item{} = item <- active_submission_item(submission.id, id) do
      item
      |> Changeset.change(
        visibility: :pending_deletion,
        archived_at: DateTime.utc_now(:second)
      )
      |> Repo.update()
    else
      nil -> {:error, :item_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def remove_submission_item(_submission, _item), do: {:error, :invalid_attributes}

  def remove_concept_image(%Concept{} = concept, %Item{id: id}) when is_integer(id) do
    with {:ok, concept} <- available_target(concept),
         %Item{} = item <- active_concept_image(concept.id, id) do
      item
      |> Changeset.change(
        visibility: :pending_deletion,
        archived_at: DateTime.utc_now(:second)
      )
      |> Repo.update()
    else
      nil -> {:error, :item_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def remove_concept_image(_concept, _item), do: {:error, :invalid_attributes}

  def preview_submission_item(%Submission{} = submission, %Item{id: id})
      when is_integer(id) do
    with {:ok, submission} <- available_target(submission),
         %Item{} = item <- active_submission_item(submission.id, id) do
      Storage.presign_get(item.original_object_key)
    else
      nil -> {:error, :item_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def preview_submission_item(_submission, _item), do: {:error, :invalid_attributes}

  def publish_submission_items_multi(%Multi{} = multi, %Submission{} = submission) do
    Multi.run(multi, :media, fn repo, %{entry: entry, concept: concept} ->
      publish_submission_items(repo, submission, entry, concept)
    end)
  end

  def get_item(public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Item
      |> where([item], item.public_id == ^public_id and is_nil(item.archived_at))
      |> Repo.one()
      |> preload_target()
    else
      :error -> nil
    end
  end

  def update_item(%Item{id: id}, attrs) when is_integer(id) and is_map(attrs) do
    case active_item(id) do
      nil ->
        {:error, :item_not_found}

      item ->
        item
        |> change_item(attrs)
        |> validate_public_target()
        |> Repo.update()
    end
  end

  def update_item(%Item{}, _attrs), do: {:error, :item_not_found}

  defp claim_submission_items(_repo, _submission, [], nil), do: {:ok, []}

  defp claim_submission_items(repo, submission, public_ids, expected_kind) do
    with {:ok, public_ids} <- cast_public_ids(public_ids),
         true <- Enum.uniq(public_ids) == public_ids,
         items <- unowned_items(repo, public_ids),
         true <- length(items) == length(public_ids),
         :ok <- validate_submission_limits(items, expected_kind),
         item_ids = Enum.map(items, & &1.id),
         {count, _rows} <-
           Item
           |> where([item], item.id in ^item_ids)
           |> where(
             [item],
             is_nil(item.submission_id) and is_nil(item.entry_id) and
               is_nil(item.concept_id) and is_nil(item.archived_at)
           )
           |> repo.update_all(set: [submission_id: submission.id]),
         true <- count == length(items) do
      {:ok, list_submission_items_with_repo(repo, submission.id)}
    else
      _invalid_or_changed -> {:error, :invalid_media}
    end
  end

  defp cast_public_ids(public_ids) do
    Enum.reduce_while(public_ids, {:ok, []}, fn public_id, {:ok, cast_ids} ->
      case Ecto.UUID.cast(public_id) do
        {:ok, cast_id} -> {:cont, {:ok, [cast_id | cast_ids]}}
        :error -> {:halt, {:error, :invalid_media}}
      end
    end)
    |> case do
      {:ok, cast_ids} -> {:ok, Enum.reverse(cast_ids)}
      error -> error
    end
  end

  defp unowned_items(repo, public_ids) do
    Item
    |> where(
      [item],
      item.public_id in ^public_ids and is_nil(item.submission_id) and
        is_nil(item.entry_id) and is_nil(item.concept_id) and is_nil(item.archived_at) and
        item.visibility == :quarantine
    )
    |> order_by([item], asc: item.public_id)
    |> repo.all()
  end

  defp validate_submission_limits(items, nil) do
    audio_count = Enum.count(items, &(&1.kind == :audio))
    image_count = Enum.count(items, &(&1.kind == :image))

    if audio_count <= 1 and image_count <= @max_submission_images and
         audio_count + image_count == length(items),
       do: :ok,
       else: {:error, :invalid_media}
  end

  defp validate_submission_limits([%Item{kind: :audio}], :audio), do: :ok

  defp validate_submission_limits(items, :image) do
    if items != [] and length(items) <= @max_submission_images and
         Enum.all?(items, &(&1.kind == :image)),
       do: :ok,
       else: {:error, :invalid_media}
  end

  defp validate_submission_limits(_items, _expected_kind), do: {:error, :invalid_media}

  defp attachment_available?(submission, %Item{kind: :audio}) do
    if submission_item_count(submission.id, :audio) == 0,
      do: :ok,
      else: {:error, :audio_already_attached}
  end

  defp attachment_available?(submission, %Item{kind: :image}) do
    if submission_item_count(submission.id, :image) < @max_submission_images,
      do: :ok,
      else: {:error, :image_limit_reached}
  end

  defp submission_item_count(submission_id, kind) do
    Item
    |> where(
      [item],
      item.submission_id == ^submission_id and item.kind == ^kind and
        is_nil(item.archived_at) and item.visibility not in [:withdrawn, :pending_deletion]
    )
    |> Repo.aggregate(:count)
  end

  defp publish_submission_items(repo, submission, entry, concept) do
    items = list_submission_items_with_repo(repo, submission.id)

    with :ok <- reject_published_duplicates(repo, items, entry, concept),
         :ok <- archive_replaced_audio(repo, items, entry) do
      items
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, published} ->
        ownership =
          case item.kind do
            :audio -> [submission_id: nil, entry_id: entry.id, concept_id: nil]
            :image -> [submission_id: nil, entry_id: nil, concept_id: concept.id]
          end

        changeset =
          item
          |> Changeset.change(ownership)
          |> Item.changeset(%{visibility: :public})

        case repo.update(changeset) do
          {:ok, item} -> {:cont, {:ok, [item | published]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
      |> case do
        {:ok, published} -> {:ok, Enum.reverse(published)}
        error -> error
      end
    end
  end

  defp reject_published_duplicates(repo, items, entry, concept) do
    audio_hash =
      Item
      |> where(
        [item],
        item.entry_id == ^entry.id and item.kind == :audio and item.visibility == :public and
          is_nil(item.archived_at)
      )
      |> select([item], item.sha256)
      |> repo.one()

    image_hashes =
      Item
      |> where(
        [item],
        item.concept_id == ^concept.id and item.kind == :image and item.visibility == :public and
          is_nil(item.archived_at)
      )
      |> select([item], item.sha256)
      |> repo.all()
      |> MapSet.new()

    duplicate? =
      Enum.any?(items, fn
        %Item{kind: :audio, sha256: sha256} -> sha256 == audio_hash
        %Item{kind: :image, sha256: sha256} -> MapSet.member?(image_hashes, sha256)
      end)

    if duplicate?, do: {:error, :already_exists}, else: :ok
  end

  defp archive_replaced_audio(repo, items, entry) do
    if Enum.any?(items, &(&1.kind == :audio)) do
      now = DateTime.utc_now(:second)

      Item
      |> where(
        [item],
        item.entry_id == ^entry.id and item.kind == :audio and is_nil(item.archived_at) and
          item.visibility not in [:withdrawn, :pending_deletion]
      )
      |> repo.update_all(set: [visibility: :pending_deletion, archived_at: now])
    end

    :ok
  end

  defp list_submission_items_with_repo(repo, submission_id) do
    Item
    |> where(
      [item],
      item.submission_id == ^submission_id and is_nil(item.archived_at) and
        item.visibility not in [:withdrawn, :pending_deletion]
    )
    |> order_by([item], asc: item.kind, asc: item.id)
    |> repo.all()
  end

  defp available_unowned_item(id) do
    Item
    |> where(
      [item],
      item.id == ^id and is_nil(item.submission_id) and is_nil(item.entry_id) and
        is_nil(item.concept_id) and is_nil(item.archived_at) and
        item.visibility == :quarantine
    )
    |> Repo.one()
  end

  defp active_submission_item(submission_id, item_id) do
    Item
    |> where(
      [item],
      item.id == ^item_id and item.submission_id == ^submission_id and
        is_nil(item.archived_at) and item.visibility not in [:withdrawn, :pending_deletion]
    )
    |> Repo.one()
  end

  defp active_concept_image(concept_id, item_id) do
    Item
    |> where(
      [item],
      item.id == ^item_id and item.concept_id == ^concept_id and item.kind == :image and
        is_nil(item.archived_at) and item.visibility not in [:withdrawn, :pending_deletion]
    )
    |> Repo.one()
  end

  defp active_item(id) do
    Item
    |> where([item], item.id == ^id and is_nil(item.archived_at))
    |> Repo.one()
  end

  defp upload_attrs(attrs, kind, object_key) do
    %{
      kind: kind,
      original_object_key: object_key,
      mime_type: attrs |> upload_value(:mime_type) |> normalized_mime_type(),
      byte_size: upload_value(attrs, :byte_size),
      sha256: attrs |> upload_value(:sha256) |> normalized_sha256(),
      variety_label: attrs |> upload_value(:variety_label) |> normalized_optional_text(),
      place_label: attrs |> upload_value(:place_label) |> normalized_optional_text(),
      attribution_text: attrs |> upload_value(:attribution_text) |> normalized_optional_text()
    }
  end

  defp normalized_completion(completion) do
    %{
      version: upload_value(completion, :version),
      kind: completion |> upload_value(:kind) |> normalized_kind(),
      original_object_key: upload_value(completion, :original_object_key),
      mime_type: completion |> upload_value(:mime_type) |> normalized_mime_type(),
      byte_size: upload_value(completion, :byte_size),
      sha256: completion |> upload_value(:sha256) |> normalized_sha256(),
      variety_label: completion |> upload_value(:variety_label) |> normalized_optional_text(),
      place_label: completion |> upload_value(:place_label) |> normalized_optional_text(),
      attribution_text:
        completion |> upload_value(:attribution_text) |> normalized_optional_text()
    }
  end

  defp validate_upload(changeset, :audio) do
    changeset
    |> Changeset.validate_inclusion(:mime_type, @audio_mime_types)
    |> Changeset.validate_number(:byte_size, less_than_or_equal_to: @max_audio_bytes)
    |> Changeset.validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
  end

  defp validate_upload(changeset, :image) do
    changeset
    |> Changeset.validate_inclusion(:mime_type, @image_mime_types)
    |> Changeset.validate_number(:byte_size, less_than_or_equal_to: @max_image_bytes)
    |> Changeset.validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
  end

  defp validate_upload(changeset, _kind), do: changeset

  defp validated_completion(completion) do
    changeset =
      %Item{}
      |> change_item(completion)
      |> validate_upload(completion.kind)
      |> validate_server_owned_key(completion.kind)

    with {:ok, item} <- Changeset.apply_action(changeset, :complete) do
      {:ok, upload_completion(item)}
    end
  end

  defp validate_server_owned_key(changeset, kind) do
    key = Changeset.get_field(changeset, :original_object_key)
    prefix = "private/#{object_directory(kind)}/"

    with key when is_binary(key) <- key,
         true <- String.starts_with?(key, prefix),
         public_id <- String.replace_prefix(key, prefix, ""),
         {:ok, _public_id} <- Ecto.UUID.cast(public_id) do
      changeset
    else
      _invalid_key -> Changeset.add_error(changeset, :original_object_key, "is invalid")
    end
  end

  defp upload_completion(item) do
    %{
      version: 1,
      kind: item.kind,
      original_object_key: item.original_object_key,
      mime_type: item.mime_type,
      byte_size: item.byte_size,
      sha256: item.sha256,
      variety_label: item.variety_label,
      place_label: item.place_label,
      attribution_text: item.attribution_text
    }
  end

  defp object_matches(object, completion) do
    if object.byte_size == completion.byte_size and object.mime_type == completion.mime_type,
      do: :ok,
      else: {:error, :object_metadata_mismatch}
  end

  defp idempotent_completion(item, owner, completion) do
    if same_upload?(item, completion) and owner_compatible?(item, owner),
      do: {:ok, item},
      else: {:error, :upload_conflict}
  end

  defp same_upload?(item, completion) do
    item.kind == completion.kind and item.mime_type == completion.mime_type and
      item.byte_size == completion.byte_size and item.sha256 == completion.sha256
  end

  defp owner_compatible?(_item, nil), do: true
  defp owner_compatible?(item, %Entry{id: id}), do: item.entry_id == id
  defp owner_compatible?(item, %Concept{id: id}), do: item.concept_id == id
  defp owner_compatible?(item, %Submission{id: id}), do: item.submission_id == id

  defp item_for_owner(nil), do: %Item{}
  defp item_for_owner(%Entry{id: id}), do: %Item{entry_id: id}
  defp item_for_owner(%Concept{id: id}), do: %Item{concept_id: id}
  defp item_for_owner(%Submission{id: id}), do: %Item{submission_id: id}

  defp available_owner(nil), do: {:ok, nil}
  defp available_owner(owner), do: available_target(owner)

  defp upload_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp normalized_kind("audio"), do: :audio
  defp normalized_kind("image"), do: :image
  defp normalized_kind(kind), do: kind

  defp object_directory(:audio), do: "audio"
  defp object_directory(:image), do: "images"
  defp object_directory(_kind), do: "uploads"

  defp normalized_mime_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalized_mime_type(value), do: value

  defp normalized_sha256(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalized_sha256(value), do: value

  defp normalized_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalized_optional_text(value), do: value

  defp available_target(%Entry{id: id}) when is_integer(id) do
    entry =
      Entry
      |> join(:inner, [entry], concept in assoc(entry, :concept))
      |> where(
        [entry, concept],
        entry.id == ^id and is_nil(entry.archived_at) and is_nil(concept.archived_at)
      )
      |> Repo.one()

    if entry, do: {:ok, entry}, else: {:error, :target_unavailable}
  end

  defp available_target(%Concept{id: id}) when is_integer(id) do
    concept =
      Concept
      |> where([concept], concept.id == ^id and is_nil(concept.archived_at))
      |> Repo.one()

    if concept, do: {:ok, concept}, else: {:error, :target_unavailable}
  end

  defp available_target(%Submission{id: id}) when is_integer(id) do
    submission =
      Submission
      |> where(
        [submission],
        submission.id == ^id and
          submission.status in [:pending, :reviewing, :clarification_needed]
      )
      |> Repo.one()

    if submission, do: {:ok, submission}, else: {:error, :target_unavailable}
  end

  defp available_target(_target), do: {:error, :target_unavailable}

  defp validate_public_target(changeset) do
    if Changeset.get_field(changeset, :visibility) == :public and
         not public_target_available?(changeset) do
      Changeset.add_error(changeset, :entry_id, "or concept must reference an active target")
    else
      changeset
    end
  end

  defp public_target_available?(changeset) do
    entry_id = Changeset.get_field(changeset, :entry_id)
    concept_id = Changeset.get_field(changeset, :concept_id)

    available_entry?(entry_id) or available_concept?(concept_id)
  end

  defp available_entry?(id) when is_integer(id) do
    Entry
    |> join(:inner, [entry], concept in assoc(entry, :concept))
    |> where(
      [entry, concept],
      entry.id == ^id and is_nil(entry.archived_at) and is_nil(concept.archived_at)
    )
    |> Repo.exists?()
  end

  defp available_entry?(_id), do: false

  defp available_concept?(id) when is_integer(id) do
    Concept
    |> where([concept], concept.id == ^id and is_nil(concept.archived_at))
    |> Repo.exists?()
  end

  defp available_concept?(_id), do: false

  defp preload_target(nil), do: nil
  defp preload_target(item), do: Repo.preload(item, [:entry, :concept, :submission])
end
