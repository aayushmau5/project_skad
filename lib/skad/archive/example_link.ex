defmodule Skad.Archive.ExampleLink do
  use Ecto.Schema
  import Ecto.Changeset

  schema "example_links" do
    field :start_offset, :integer
    field :end_offset, :integer
    field :surface_text, :string
    field :role, Ecto.Enum, values: [:focus, :reference]

    belongs_to :example, Skad.Archive.Example
    belongs_to :entry, Skad.Archive.Entry
  end

  def changeset(example_link, attrs) do
    example_link
    |> cast(attrs, [:start_offset, :end_offset, :surface_text, :role])
    |> validate_required([
      :example_id,
      :entry_id,
      :start_offset,
      :end_offset,
      :surface_text,
      :role
    ])
    |> validate_number(:start_offset, greater_than_or_equal_to: 0)
    |> validate_offsets()
  end

  defp validate_offsets(changeset) do
    start_offset = get_field(changeset, :start_offset)
    end_offset = get_field(changeset, :end_offset)

    if is_integer(start_offset) and is_integer(end_offset) and end_offset <= start_offset do
      add_error(changeset, :end_offset, "must be greater than start offset")
    else
      changeset
    end
  end
end
