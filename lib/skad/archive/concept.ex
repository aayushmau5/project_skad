defmodule Skad.Archive.Concept do
  use Ecto.Schema
  import Ecto.Changeset

  schema "concepts" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :editorial_label, :string
    field :editorial_note, :string
    field :archived_at, :utc_datetime

    has_many :entries, Skad.Archive.Entry
    has_many :media, Skad.Media.Item
  end

  def changeset(concept, attrs) do
    concept
    |> cast(attrs, [:editorial_label, :editorial_note])
    |> validate_required([:editorial_label])
    |> unique_constraint(:public_id)
  end
end
