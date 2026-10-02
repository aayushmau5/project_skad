defmodule Skad.Contributions.EntryChangeSubmission do
  use Ecto.Schema

  import Ecto.Changeset

  alias Skad.Archive.Entry

  @primary_key false
  embedded_schema do
    field :client_submission_id, Ecto.UUID
    field :language_slug, :string
    field :primary_form, :string, redact: true
    field :definition, :string, redact: true
    field :part_of_speech, :string, redact: true
    field :usage_note, :string, redact: true
    field :cultural_note, :string, redact: true
    field :alternate_form, :string, redact: true
    field :form_kind, Ecto.Enum, values: [:spelling, :transliteration, :historical, :alias]
    field :example, :string, redact: true
  end

  def changeset(kind, submission, attrs)
      when kind in [:correction, :addition, :example, :audio, :image] do
    submission
    |> cast(attrs, fields(kind))
    |> normalize_text_fields()
    |> validate_required(required_fields(kind))
    |> validate_length(:language_slug, max: 100)
    |> validate_length(:primary_form, max: 255)
    |> validate_length(:definition, max: 2_000)
    |> validate_length(:part_of_speech, max: 100)
    |> validate_length(:usage_note, max: 5_000)
    |> validate_length(:cultural_note, max: 5_000)
    |> validate_length(:alternate_form, max: 255)
    |> validate_length(:example, max: 5_000)
    |> validate_addition(kind)
  end

  def from_entry(%Entry{} = entry, client_submission_id) do
    primary_form = Enum.find(entry.forms, & &1.is_primary)
    definition = List.first(entry.definitions)

    %__MODULE__{
      client_submission_id: client_submission_id,
      language_slug: entry.language.slug,
      primary_form: primary_form && primary_form.text,
      definition: definition && definition.text,
      part_of_speech: entry.part_of_speech,
      usage_note: entry.usage_note,
      cultural_note: entry.cultural_note,
      form_kind: :alias
    }
  end

  def to_payload(:correction, %__MODULE__{} = submission) do
    Map.take(Map.from_struct(submission), [
      :language_slug,
      :primary_form,
      :definition,
      :part_of_speech,
      :usage_note,
      :cultural_note
    ])
    |> stringify_keys()
  end

  def to_payload(:addition, %__MODULE__{} = submission) do
    %{
      "language_slug" => submission.language_slug,
      "primary_form" => submission.primary_form,
      "alternate_form" => submission.alternate_form,
      "form_kind" => submission.form_kind && Atom.to_string(submission.form_kind),
      "example" => submission.example
    }
  end

  def to_payload(:example, %__MODULE__{} = submission) do
    %{
      "language_slug" => submission.language_slug,
      "primary_form" => submission.primary_form,
      "example" => submission.example
    }
  end

  def to_payload(kind, %__MODULE__{} = submission) when kind in [:audio, :image] do
    %{
      "language_slug" => submission.language_slug,
      "primary_form" => submission.primary_form
    }
  end

  defp fields(:correction) do
    [
      :client_submission_id,
      :language_slug,
      :primary_form,
      :definition,
      :part_of_speech,
      :usage_note,
      :cultural_note
    ]
  end

  defp fields(:addition) do
    [:client_submission_id, :language_slug, :primary_form, :alternate_form, :form_kind, :example]
  end

  defp fields(:example),
    do: [:client_submission_id, :language_slug, :primary_form, :example]

  defp fields(kind) when kind in [:audio, :image],
    do: [:client_submission_id, :language_slug, :primary_form]

  defp required_fields(:correction),
    do: [:client_submission_id, :language_slug, :primary_form, :definition]

  defp required_fields(:addition),
    do: [:client_submission_id, :language_slug, :primary_form]

  defp required_fields(:example),
    do: [:client_submission_id, :language_slug, :primary_form, :example]

  defp required_fields(kind) when kind in [:audio, :image],
    do: [:client_submission_id, :language_slug, :primary_form]

  defp validate_addition(changeset, :addition) do
    if get_field(changeset, :alternate_form) || get_field(changeset, :example) do
      changeset
    else
      add_error(changeset, :alternate_form, "or an example is required")
    end
  end

  defp validate_addition(changeset, :correction), do: changeset
  defp validate_addition(changeset, kind) when kind in [:example, :audio, :image], do: changeset

  defp normalize_text_fields(changeset) do
    Enum.reduce(
      [
        :language_slug,
        :primary_form,
        :definition,
        :part_of_speech,
        :usage_note,
        :cultural_note,
        :alternate_form,
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

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
