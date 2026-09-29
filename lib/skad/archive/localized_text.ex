defmodule Skad.Archive.LocalizedText do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :language, :string
    field :text, :string
  end

  def changeset(localized_text, attrs) do
    localized_text
    |> cast(attrs, [:language, :text])
    |> validate_required([:language, :text])
  end
end
