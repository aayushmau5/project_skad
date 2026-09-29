defmodule Skad.Archive.Example do
  use Ecto.Schema
  import Ecto.Changeset

  alias Skad.Archive.LocalizedText

  schema "examples" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :text, :string
    field :normalized_text, :string
    field :archived_at, :utc_datetime

    belongs_to :language, Skad.Archive.Language
    embeds_many :translations, LocalizedText, on_replace: :delete
    has_many :links, Skad.Archive.ExampleLink
  end

  def changeset(example, attrs) do
    example
    |> cast(attrs, [:text])
    |> cast_embed(:translations, with: &LocalizedText.changeset/2)
    |> validate_required([:language_id, :text, :normalized_text])
    |> unique_constraint(:public_id)
  end
end
