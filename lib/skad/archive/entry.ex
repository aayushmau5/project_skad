defmodule Skad.Archive.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  alias Skad.Archive.LocalizedText

  schema "entries" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :part_of_speech, :string
    field :variety_label, :string
    field :place_label, :string
    field :usage_note, :string
    field :cultural_note, :string
    field :archived_at, :utc_datetime

    belongs_to :language, Skad.Archive.Language
    belongs_to :concept, Skad.Archive.Concept
    embeds_many :definitions, LocalizedText, on_replace: :delete
    has_many :forms, Skad.Archive.EntryForm
    has_many :example_links, Skad.Archive.ExampleLink
    has_many :media, Skad.Media.Item
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :part_of_speech,
      :variety_label,
      :place_label,
      :usage_note,
      :cultural_note
    ])
    |> cast_embed(:definitions, required: true, with: &LocalizedText.changeset/2)
    |> validate_required([:language_id, :concept_id])
    |> unique_constraint(:public_id)
  end
end
