defmodule Skad.Archive.EntryForm do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entry_forms" do
    field :text, :string
    field :normalized_text, :string

    field :kind, Ecto.Enum, values: [:spelling, :transliteration, :historical, :alias]

    field :is_primary, :boolean, default: false

    belongs_to :entry, Skad.Archive.Entry
    belongs_to :language, Skad.Archive.Language
  end

  def changeset(entry_form, attrs) do
    entry_form
    |> cast(attrs, [:text, :kind, :is_primary])
    |> validate_required([
      :entry_id,
      :language_id,
      :text,
      :normalized_text,
      :kind,
      :is_primary
    ])
    |> unique_constraint([:entry_id, :normalized_text, :kind])
    |> unique_constraint(:entry_id, name: :entry_forms_one_primary_per_entry_index)
  end
end
