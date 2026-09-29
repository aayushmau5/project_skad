defmodule Skad.Archive.Language do
  use Ecto.Schema
  import Ecto.Changeset

  schema "languages" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :slug, :string
    field :code, :string
    field :name, :string
    field :direction, Ecto.Enum, values: [:ltr, :rtl]
    field :active, :boolean, default: true

    has_many :entries, Skad.Archive.Entry
    has_many :examples, Skad.Archive.Example
  end

  def changeset(language, attrs) do
    language
    |> cast(attrs, [:slug, :code, :name, :direction, :active])
    |> validate_required([:slug, :name, :direction, :active])
    |> unique_constraint(:public_id)
    |> unique_constraint(:slug)
    |> unique_constraint(:code)
  end
end
