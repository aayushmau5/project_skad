defmodule Skad.Media do
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Media.Item
  alias Skad.Repo

  def change_item(%Item{} = item, attrs \\ %{}) when is_map(attrs) do
    Item.changeset(item, attrs)
  end

  def create_item(attrs) when is_map(attrs) do
    %Item{}
    |> change_item(attrs)
    |> Repo.insert()
  end

  def create_item(_attrs), do: {:error, :invalid_attributes}

  def create_item(%Entry{} = entry, attrs) when is_map(attrs) do
    with {:ok, entry} <- available_target(entry) do
      %Item{entry_id: entry.id}
      |> change_item(attrs)
      |> Repo.insert()
    end
  end

  def create_item(%Concept{} = concept, attrs) when is_map(attrs) do
    with {:ok, concept} <- available_target(concept) do
      %Item{concept_id: concept.id}
      |> change_item(attrs)
      |> Repo.insert()
    end
  end

  def create_item(_target, _attrs), do: {:error, :invalid_attributes}

  def get_item(public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Item
      |> where([item], item.public_id == ^public_id and is_nil(item.archived_at))
      |> Repo.one()
      |> preload_target()
    else
      :error -> nil
    end
  end

  def update_item(%Item{id: id}, attrs) when is_integer(id) and is_map(attrs) do
    case active_item(id) do
      nil ->
        {:error, :item_not_found}

      item ->
        item
        |> change_item(attrs)
        |> validate_public_target()
        |> Repo.update()
    end
  end

  def update_item(%Item{}, _attrs), do: {:error, :item_not_found}

  defp active_item(id) do
    Item
    |> where([item], item.id == ^id and is_nil(item.archived_at))
    |> Repo.one()
  end

  defp available_target(%Entry{id: id}) when is_integer(id) do
    entry =
      Entry
      |> join(:inner, [entry], concept in assoc(entry, :concept))
      |> where(
        [entry, concept],
        entry.id == ^id and is_nil(entry.archived_at) and is_nil(concept.archived_at)
      )
      |> Repo.one()

    if entry, do: {:ok, entry}, else: {:error, :target_unavailable}
  end

  defp available_target(%Concept{id: id}) when is_integer(id) do
    concept =
      Concept
      |> where([concept], concept.id == ^id and is_nil(concept.archived_at))
      |> Repo.one()

    if concept, do: {:ok, concept}, else: {:error, :target_unavailable}
  end

  defp available_target(_target), do: {:error, :target_unavailable}

  defp validate_public_target(changeset) do
    if Changeset.get_field(changeset, :visibility) == :public and
         not public_target_available?(changeset) do
      Changeset.add_error(changeset, :entry_id, "or concept must reference an active target")
    else
      changeset
    end
  end

  defp public_target_available?(changeset) do
    entry_id = Changeset.get_field(changeset, :entry_id)
    concept_id = Changeset.get_field(changeset, :concept_id)

    available_entry?(entry_id) or available_concept?(concept_id)
  end

  defp available_entry?(id) when is_integer(id) do
    Entry
    |> join(:inner, [entry], concept in assoc(entry, :concept))
    |> where(
      [entry, concept],
      entry.id == ^id and is_nil(entry.archived_at) and is_nil(concept.archived_at)
    )
    |> Repo.exists?()
  end

  defp available_entry?(_id), do: false

  defp available_concept?(id) when is_integer(id) do
    Concept
    |> where([concept], concept.id == ^id and is_nil(concept.archived_at))
    |> Repo.exists?()
  end

  defp available_concept?(_id), do: false

  defp preload_target(nil), do: nil
  defp preload_target(item), do: Repo.preload(item, [:entry, :concept])
end
