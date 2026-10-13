defmodule Skad.Contributions.NewEntrySubmission do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :client_submission_id, Ecto.UUID
    field :language_slug, :string
    field :primary_form, :string, redact: true
    field :definition, :string, redact: true
    field :definition_language, :string
    field :source_entry_public_id, Ecto.UUID
    field :part_of_speech, :string, redact: true
    field :usage_note, :string, redact: true
    field :cultural_note, :string, redact: true
    field :example, :string, redact: true
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :client_submission_id,
      :language_slug,
      :primary_form,
      :definition,
      :definition_language,
      :source_entry_public_id,
      :part_of_speech,
      :usage_note,
      :cultural_note,
      :example
    ])
    |> normalize_text_fields()
    |> validate_required([
      :client_submission_id,
      :language_slug,
      :primary_form,
      :definition
    ])
    |> validate_length(:language_slug, max: 100)
    |> validate_length(:definition_language, max: 100)
    |> validate_length(:primary_form, max: 255)
    |> validate_length(:definition, max: 2_000)
    |> validate_length(:part_of_speech, max: 100)
    |> validate_length(:usage_note, max: 5_000)
    |> validate_length(:cultural_note, max: 5_000)
    |> validate_length(:example, max: 5_000)
    |> then(fn changeset ->
      if Map.has_key?(attrs, :definition_language) or Map.has_key?(attrs, "definition_language"),
        do: validate_required(changeset, [:definition_language]),
        else: changeset
    end)
  end

  def to_payload(%__MODULE__{} = submission) do
    %{
      "language_slug" => submission.language_slug,
      "primary_form" => submission.primary_form,
      "definition" => submission.definition,
      "part_of_speech" => submission.part_of_speech,
      "usage_note" => submission.usage_note,
      "cultural_note" => submission.cultural_note,
      "example" => submission.example
    }
    |> then(fn payload ->
      Enum.reduce([:definition_language, :source_entry_public_id], payload, fn field, payload ->
        case Map.fetch!(Map.from_struct(submission), field) do
          nil -> payload
          value -> Map.put(payload, Atom.to_string(field), value)
        end
      end)
    end)
  end

  defp normalize_text_fields(changeset) do
    Enum.reduce(
      [
        :language_slug,
        :primary_form,
        :definition,
        :definition_language,
        :part_of_speech,
        :usage_note,
        :cultural_note,
        :example
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
