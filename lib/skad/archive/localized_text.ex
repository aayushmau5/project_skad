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
    |> update_change(:text, fn text -> if is_binary(text), do: String.trim(text), else: text end)
    |> validate_required([:language, :text])
    |> validate_length(:text, max: 5_000)
  end
end
