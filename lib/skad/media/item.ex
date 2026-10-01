defmodule Skad.Media.Item do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:audio, :image]
  @processing_states [:uploaded, :validated, :processing, :ready, :failed]
  @visibilities [:quarantine, :private, :public, :withdrawn, :pending_deletion]

  schema "media" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :kind, Ecto.Enum, values: @kinds
    field :original_object_key, :string
    field :public_object_key, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :duration_ms, :integer
    field :width, :integer
    field :height, :integer
    field :variety_label, :string
    field :place_label, :string
    field :attribution_text, :string
    field :processing_state, Ecto.Enum, values: @processing_states, default: :uploaded
    field :visibility, Ecto.Enum, values: @visibilities, default: :quarantine
    field :archived_at, :utc_datetime

    belongs_to :entry, Skad.Archive.Entry
    belongs_to :concept, Skad.Archive.Concept
    belongs_to :submission, Skad.Contributions.Submission
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :kind,
      :original_object_key,
      :public_object_key,
      :mime_type,
      :byte_size,
      :sha256,
      :duration_ms,
      :width,
      :height,
      :variety_label,
      :place_label,
      :attribution_text,
      :processing_state,
      :visibility
    ])
    |> validate_required([
      :kind,
      :original_object_key,
      :mime_type,
      :byte_size,
      :sha256,
      :processing_state,
      :visibility
    ])
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_number(:duration_ms, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_format(:public_object_key, ~r/\S/)
    |> validate_kind_metadata()
    |> validate_public_state()
    |> unique_constraint(:public_id)
    |> unique_constraint(:original_object_key)
    |> unique_constraint(:public_object_key)
    |> unique_constraint(:submission_id, name: :media_one_active_audio_per_submission)
    |> unique_constraint(:entry_id, name: :media_one_active_audio_per_entry)
    |> foreign_key_constraint(:entry_id)
    |> foreign_key_constraint(:concept_id)
    |> foreign_key_constraint(:submission_id)
  end

  defp validate_kind_metadata(changeset) do
    case get_field(changeset, :kind) do
      :audio ->
        changeset
        |> require_empty(:width, "must be empty for audio")
        |> require_empty(:height, "must be empty for audio")

      :image ->
        require_empty(changeset, :duration_ms, "must be empty for images")

      _other ->
        changeset
    end
  end

  defp validate_public_state(changeset) do
    if get_field(changeset, :visibility) == :public do
      changeset
      |> validate_required([:public_object_key])
      |> require_ready()
      |> require_target()
    else
      changeset
    end
  end

  defp require_empty(changeset, field, message) do
    if is_nil(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, message)
  end

  defp require_ready(changeset) do
    if get_field(changeset, :processing_state) == :ready do
      changeset
    else
      add_error(changeset, :processing_state, "must be ready when media is public")
    end
  end

  defp require_target(changeset) do
    if get_field(changeset, :entry_id) || get_field(changeset, :concept_id) do
      changeset
    else
      add_error(changeset, :entry_id, "or concept must be present when media is public")
    end
  end
end
