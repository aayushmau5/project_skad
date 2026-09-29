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

  @exact_lookup_limit 20

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

  def exact_lookup(query, language \\ nil) do
    with normalized when is_binary(normalized) and normalized != "" <- normalize_text(query),
         {:ok, language_id} <- lookup_language_id(language) do
      matching_forms =
        EntryForm
        |> where([form], form.normalized_text == ^normalized)
        |> maybe_filter_language(language_id)
        |> group_by([form], form.entry_id)
        |> select([form], %{
          entry_id: form.entry_id,
          primary_match: fragment("MAX(CASE WHEN ? THEN 1 ELSE 0 END)", form.is_primary)
        })

      forms_query =
        from form in EntryForm,
          order_by: [desc: form.is_primary, asc: form.id]

      Entry
      |> join(:inner, [entry], match in subquery(matching_forms), on: match.entry_id == entry.id)
      |> join(:inner, [entry, _match], concept in assoc(entry, :concept))
      |> where(
        [entry, _match, concept],
        is_nil(entry.archived_at) and is_nil(concept.archived_at)
      )
      |> order_by([entry, match], desc: match.primary_match, asc: entry.id)
      |> limit(@exact_lookup_limit)
      |> Repo.all()
      |> Repo.preload([:language, :concept, forms: forms_query])
      |> Enum.map(fn entry ->
        matched_form = Enum.find(entry.forms, &(&1.normalized_text == normalized))
        %{entry: entry, matched_form: matched_form}
      end)
    else
      _invalid_query_or_language -> []
    end
  end

  def publish_new_meaning(%Language{} = language, attrs) when is_map(attrs) do
    concept_attrs = attr(attrs, :concept, %{})
    entry_attrs = attr(attrs, :entry, %{})
    forms_attrs = attr(attrs, :forms, [])

    with {:ok, language} <- active_language(language),
         :ok <- validate_forms(forms_attrs) do
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
      |> public_entry_result()
    end
  end

  def publish_new_meaning(_language, _attrs), do: {:error, :invalid_attributes}

  def publish_equivalent(%Entry{} = source_entry, %Language{} = language, attrs)
      when is_map(attrs) do
    entry_attrs = attr(attrs, :entry, %{})
    forms_attrs = attr(attrs, :forms, [])

    with {:ok, language} <- active_language(language),
         {:ok, concept} <- available_concept(source_entry),
         :ok <- validate_forms(forms_attrs) do
      Multi.new()
      |> Multi.insert(
        :entry,
        Entry.changeset(
          %Entry{language_id: language.id, concept_id: concept.id},
          entry_attrs
        )
      )
      |> Multi.run(:forms, fn repo, %{entry: entry} ->
        insert_forms(repo, entry, forms_attrs)
      end)
      |> Repo.transaction()
      |> public_entry_result()
    end
  end

  def publish_equivalent(_source_entry, _language, _attrs),
    do: {:error, :invalid_attributes}

  def publish_usage_example(%Language{} = language, attrs) when is_map(attrs) do
    example_attrs = attr(attrs, :example, %{})
    links_attrs = attr(attrs, :links, [])

    with {:ok, language} <- active_language(language),
         :ok <- validate_link_set(links_attrs) do
      example = %Example{
        language_id: language.id,
        normalized_text: example_attrs |> attr(:text) |> normalize_text()
      }

      Multi.new()
      |> Multi.insert(:example, Example.changeset(example, example_attrs))
      |> Multi.run(:links, fn repo, %{example: example} ->
        insert_example_links(repo, example, links_attrs)
      end)
      |> Repo.transaction()
      |> public_example_result()
    end
  end

  def publish_usage_example(_language, _attrs),
    do: {:error, :invalid_attributes}

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

  defp public_entry_result({:ok, %{entry: entry}}),
    do: {:ok, preload_public_entry(entry)}

  defp public_entry_result({:error, _operation, reason, _changes}),
    do: {:error, reason}

  defp public_example_result({:ok, %{example: example}}) do
    links_query = from link in ExampleLink, order_by: [asc: link.start_offset, asc: link.id]

    {:ok,
     Repo.preload(example,
       language: [],
       links: {links_query, [entry: [:language, :forms]]}
     )}
  end

  defp public_example_result({:error, _operation, reason, _changes}),
    do: {:error, reason}

  defp active_language(%Language{id: id}) when is_integer(id) do
    case Repo.get_by(Language, id: id, active: true) do
      nil -> {:error, :language_inactive}
      language -> {:ok, language}
    end
  end

  defp active_language(_language), do: {:error, :language_inactive}

  defp lookup_language_id(nil), do: {:ok, nil}
  defp lookup_language_id(%Language{id: id}) when is_integer(id), do: {:ok, id}
  defp lookup_language_id(_language), do: :error

  defp maybe_filter_language(query, nil), do: query

  defp maybe_filter_language(query, language_id) do
    where(query, [form], form.language_id == ^language_id)
  end

  defp available_concept(%Entry{id: id}) when is_integer(id) do
    concept =
      Entry
      |> join(:inner, [entry], concept in assoc(entry, :concept))
      |> where(
        [entry, concept],
        entry.id == ^id and is_nil(entry.archived_at) and is_nil(concept.archived_at)
      )
      |> select([_entry, concept], concept)
      |> Repo.one()

    if concept, do: {:ok, concept}, else: {:error, :meaning_unavailable}
  end

  defp available_concept(_entry), do: {:error, :meaning_unavailable}

  defp insert_example_links(repo, example, links_attrs) do
    with {:ok, links} <- prepare_links(repo, example.text, links_attrs),
         :ok <- validate_non_overlapping(links) do
      links
      |> Enum.reduce_while({:ok, []}, fn link, {:ok, inserted} ->
        example_link = %ExampleLink{
          example_id: example.id,
          entry_id: link.entry.id
        }

        attrs = %{
          start_offset: link.start_offset,
          end_offset: link.end_offset,
          surface_text: link.surface_text,
          role: link.role
        }

        case repo.insert(ExampleLink.changeset(example_link, attrs)) do
          {:ok, link} -> {:cont, {:ok, [link | inserted]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
      |> case do
        {:ok, links} -> {:ok, Enum.reverse(links)}
        error -> error
      end
    end
  end

  defp prepare_links(repo, text, links_attrs) do
    links_attrs
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, links} ->
      case prepare_link(repo, text, attrs) do
        {:ok, link} -> {:cont, {:ok, [link | links]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, links} -> {:ok, Enum.reverse(links)}
      error -> error
    end
  end

  defp prepare_link(repo, text, attrs) do
    with {:ok, entry} <- available_entry(repo, attr(attrs, :entry_public_id)),
         {:ok, start_offset} <- cast_integer(attr(attrs, :start_offset)),
         {:ok, end_offset} <- cast_integer(attr(attrs, :end_offset)),
         {:ok, role} <- cast_link_role(attr(attrs, :role)),
         {:ok, surface_text} <- slice_utf8(text, start_offset, end_offset) do
      {:ok,
       %{
         entry: entry,
         start_offset: start_offset,
         end_offset: end_offset,
         surface_text: surface_text,
         role: role
       }}
    end
  end

  defp available_entry(repo, public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id),
         %Entry{} = entry <-
           Entry
           |> join(:inner, [entry], concept in assoc(entry, :concept))
           |> where(
             [entry, concept],
             entry.public_id == ^public_id and is_nil(entry.archived_at) and
               is_nil(concept.archived_at)
           )
           |> repo.one() do
      {:ok, entry}
    else
      _error -> {:error, :entry_unavailable}
    end
  end

  defp validate_link_set(links) when is_list(links) do
    cond do
      links == [] -> {:error, :links_required}
      not Enum.all?(links, &is_map/1) -> {:error, :invalid_links}
      not Enum.any?(links, &focus_link?/1) -> {:error, :focus_link_required}
      true -> :ok
    end
  end

  defp validate_link_set(_links), do: {:error, :invalid_links}

  defp focus_link?(attrs), do: attr(attrs, :role) in [:focus, "focus"]

  defp validate_non_overlapping(links) do
    overlapping? =
      links
      |> Enum.sort_by(&{&1.start_offset, &1.end_offset})
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [left, right] -> left.end_offset > right.start_offset end)

    if overlapping?, do: {:error, :overlapping_links}, else: :ok
  end

  defp cast_integer(value) do
    case Ecto.Type.cast(:integer, value) do
      {:ok, integer} -> {:ok, integer}
      :error -> {:error, :invalid_link_span}
    end
  end

  defp cast_link_role(role) when role in [:focus, "focus"], do: {:ok, :focus}
  defp cast_link_role(role) when role in [:reference, "reference"], do: {:ok, :reference}
  defp cast_link_role(_role), do: {:error, :invalid_link_role}

  defp slice_utf8(text, start_offset, end_offset)
       when is_binary(text) and start_offset >= 0 and end_offset > start_offset and
              end_offset <= byte_size(text) do
    prefix = binary_part(text, 0, start_offset)
    surface_text = binary_part(text, start_offset, end_offset - start_offset)
    suffix = binary_part(text, end_offset, byte_size(text) - end_offset)

    if Enum.all?([prefix, surface_text, suffix], &String.valid?/1) do
      {:ok, surface_text}
    else
      {:error, :invalid_link_span}
    end
  end

  defp slice_utf8(_text, _start_offset, _end_offset),
    do: {:error, :invalid_link_span}

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
