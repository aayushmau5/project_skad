defmodule Skad.Contributions.NewEntrySubmission do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :client_submission_id, Ecto.UUID
    field :language_slug, :string
    field :primary_form, :string, redact: true
    field :definition, :string, redact: true
    field :part_of_speech, :string, redact: true
    field :usage_note, :string, redact: true
    field :cultural_note, :string, redact: true
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :client_submission_id,
      :language_slug,
      :primary_form,
      :definition,
      :part_of_speech,
      :usage_note,
      :cultural_note
    ])
    |> normalize_text_fields()
    |> validate_required([
      :client_submission_id,
      :language_slug,
      :primary_form,
      :definition
    ])
    |> validate_length(:language_slug, max: 100)
    |> validate_length(:primary_form, max: 255)
    |> validate_length(:definition, max: 2_000)
    |> validate_length(:part_of_speech, max: 100)
    |> validate_length(:usage_note, max: 5_000)
    |> validate_length(:cultural_note, max: 5_000)
  end

  def to_payload(%__MODULE__{} = submission) do
    %{
      "version" => 1,
      "language_slug" => submission.language_slug,
      "primary_form" => submission.primary_form,
      "definition" => submission.definition,
      "part_of_speech" => submission.part_of_speech,
      "usage_note" => submission.usage_note,
      "cultural_note" => submission.cultural_note
    }
  end

  defp normalize_text_fields(changeset) do
    Enum.reduce(
      [
        :language_slug,
        :primary_form,
        :definition,
        :part_of_speech,
        :usage_note,
        :cultural_note
      ],
      changeset,
      fn field, changeset -> update_change(changeset, field, &normalize_text/1) end
    )
  end

  defp normalize_text(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end
end
