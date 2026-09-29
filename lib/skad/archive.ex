defmodule Skad.Archive do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink
  alias Skad.Archive.Language
  alias Skad.Repo

  def list_active_languages do
    Language
    |> where([language], language.active)
    |> order_by([language], asc: language.name)
    |> Repo.all()
  end

  def get_language_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Language, slug: slug)
  end

  def create_language(attrs) do
    %Language{}
    |> Language.changeset(attrs)
    |> Repo.insert()
  end

  def publish_new_meaning(%Language{active: false}, _attrs),
    do: {:error, :language_inactive}

  def publish_new_meaning(%Language{} = language, attrs) when is_map(attrs) do
    concept_attrs = attr(attrs, :concept, %{})
    entry_attrs = attr(attrs, :entry, %{})
    forms_attrs = attr(attrs, :forms, [])

    with :ok <- validate_forms(forms_attrs) do
      Multi.new()
      |> Multi.insert(:concept, Concept.changeset(%Concept{}, concept_attrs))
      |> Multi.insert(:entry, fn %{concept: concept} ->
        Entry.changeset(
          %Entry{language_id: language.id, concept_id: concept.id},
          entry_attrs
        )
      end)
      |> Multi.run(:forms, fn repo, %{entry: entry} ->
        insert_forms(repo, entry, forms_attrs)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{entry: entry}} -> {:ok, preload_public_entry(entry)}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  def publish_new_meaning(_language, _attrs), do: {:error, :invalid_attributes}

  def get_public_entry(public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Entry
      |> join(:inner, [entry], concept in assoc(entry, :concept))
      |> where(
        [entry, concept],
        entry.public_id == ^public_id and is_nil(entry.archived_at) and
          is_nil(concept.archived_at)
      )
      |> Repo.one()
      |> preload_public_entry()
    else
      :error -> nil
    end
  end

  defp preload_public_entry(nil), do: nil

  defp preload_public_entry(entry) do
    forms_query = from form in EntryForm, order_by: [desc: form.is_primary, asc: form.id]
    entries_query = from entry in Entry, where: is_nil(entry.archived_at), order_by: entry.id
    examples_query = from example in Example, where: is_nil(example.archived_at)

    entry_example_links_query =
      from link in ExampleLink,
        join: example in assoc(link, :example),
        where: is_nil(example.archived_at),
        order_by: [asc: example.id, asc: link.start_offset]

    links_query =
      from link in ExampleLink,
        order_by: [asc: link.start_offset, asc: link.id]

    Repo.preload(entry,
      language: [],
      forms: forms_query,
      concept: [entries: {entries_query, [:language, forms: forms_query]}],
      example_links:
        {entry_example_links_query,
         [
           example:
             {examples_query,
              [
                :language,
                links: {links_query, [entry: {entries_query, [forms: forms_query]}]}
              ]}
         ]}
    )
  end

  defp insert_forms(repo, entry, forms_attrs) do
    forms_attrs
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, forms} ->
      entry_form = %EntryForm{
        entry_id: entry.id,
        language_id: entry.language_id,
        normalized_text: attrs |> attr(:text) |> normalize_text()
      }

      case repo.insert(EntryForm.changeset(entry_form, attrs)) do
        {:ok, form} -> {:cont, {:ok, [form | forms]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, forms} -> {:ok, Enum.reverse(forms)}
      error -> error
    end
  end

  defp validate_forms(forms) when is_list(forms) do
    cond do
      forms == [] ->
        {:error, :forms_required}

      not Enum.all?(forms, &is_map/1) ->
        {:error, :invalid_forms}

      Enum.count(forms, &primary?/1) != 1 ->
        {:error, :exactly_one_primary_form_required}

      true ->
        :ok
    end
  end

  defp validate_forms(_forms), do: {:error, :invalid_forms}

  defp primary?(attrs) do
    case Ecto.Type.cast(:boolean, attr(attrs, :is_primary, false)) do
      {:ok, value} -> value
      :error -> false
    end
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.normalize(:nfc)
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(_text), do: nil

  defp attr(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
