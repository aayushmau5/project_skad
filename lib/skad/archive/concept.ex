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
    |> update_change(:editorial_label, &normalize_required_text/1)
    |> update_change(:editorial_note, &normalize_optional_text/1)
    |> validate_required([:editorial_label])
    |> validate_length(:editorial_label, max: 255)
    |> validate_length(:editorial_note, max: 5_000)
    |> unique_constraint(:public_id)
  end

  defp normalize_required_text(text) when is_binary(text), do: String.trim(text)
  defp normalize_required_text(text), do: text

  defp normalize_optional_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_optional_text(text), do: text
end
