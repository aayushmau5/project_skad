defmodule Skad.Archive do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink
  alias Skad.Archive.ExampleMatcher
  alias Skad.Archive.Language
  alias Skad.Archive.Search
  alias Skad.Repo

  @lookup_limit 20
  @concept_limit 20
  @archive_page_size 20

  def list_active_languages do
    Language
    |> where([language], language.active)
    |> order_by([language], asc: language.name)
    |> Repo.all()
  end

  def count_public_entries do
    public_entries_query()
    |> Repo.aggregate(:count, :id)
  end

  def list_public_entries(language \\ nil, page \\ 1) do
    query =
      public_entries_query()
      |> maybe_filter_entry_language(if(language, do: language.id))

    total_count = Repo.aggregate(query, :count, :id)
    page_count = max(1, div(total_count + @archive_page_size - 1, @archive_page_size))
    page = page |> archive_page() |> min(page_count)

    entries =
      query
      |> join(:inner, [entry], form in assoc(entry, :forms), on: form.is_primary)
      |> order_by([entry, _concept, form], asc: form.normalized_text, asc: entry.id)
      |> limit(@archive_page_size)
      |> offset(^((page - 1) * @archive_page_size))
      |> Repo.all()
      |> Repo.preload([:language, :forms])

    %{entries: entries, page: page, page_count: page_count, total_count: total_count}
  end

  defp public_entries_query do
    Entry
    |> join(:inner, [entry], concept in assoc(entry, :concept))
    |> where([entry, concept], is_nil(entry.archived_at) and is_nil(concept.archived_at))
  end

  defp archive_page(page) when is_integer(page) and page > 0, do: page

  defp archive_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} when number > 0 -> number
      _invalid -> 1
    end
  end

  defp archive_page(_page), do: 1

  def get_language_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Language, slug: slug)
  end

  def create_language(attrs) do
    %Language{}
    |> Language.changeset(attrs)
    |> Repo.insert()
  end

  def change_concept(%Concept{} = concept, attrs \\ %{}) do
    Concept.changeset(concept, attrs)
  end

  def get_concept(public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Concept
      |> where([concept], concept.public_id == ^public_id and is_nil(concept.archived_at))
      |> Repo.one()
      |> preload_concepts()
    else
      :error -> nil
    end
  end

  def search_concepts(query) do
    case normalize_text(query) do
      query when is_binary(query) and query != "" ->
        entry_concept_ids =
          query
          |> search()
          |> Enum.map(& &1.entry.concept_id)
          |> Enum.uniq()

        Concept
        |> where(
          [concept],
          is_nil(concept.archived_at) and
            (concept.id in ^entry_concept_ids or
               fragment("instr(lower(?), ?) > 0", concept.editorial_label, ^query) or
               fragment(
                 "instr(lower(coalesce(?, '')), ?) > 0",
                 concept.editorial_note,
                 ^query
               ))
        )
        |> order_by([concept], asc: concept.editorial_label, asc: concept.id)
        |> limit(@concept_limit)
        |> Repo.all()
        |> preload_concepts()

      _empty_query ->
        []
    end
  end

  def exact_lookup(query, language \\ nil), do: lookup(query, language, :exact)

  def prefix_lookup(query, language \\ nil), do: lookup(query, language, :prefix)

  def search(query, language \\ nil) do
    with normalized when is_binary(normalized) and normalized != "" <- normalize_text(query),
         {:ok, language_id} <- lookup_language_id(language) do
      direct = direct_search(normalized, language, language_id)
      concept_sources = if language_id, do: direct_search(normalized, nil, nil), else: direct

      (direct ++ related_entries(concept_sources, language_id))
      |> Enum.uniq_by(& &1.entry.id)
      |> Enum.take(@lookup_limit)
    else
      _invalid_query_or_language -> []
    end
  end

  def rebuild_search_index, do: Search.rebuild()

  defp direct_search(query, language, language_id) do
    (exact_lookup(query, language) ++
       prefix_lookup(query, language) ++
       Search.full_text_lookup(query, language_id))
    |> Enum.uniq_by(& &1.entry.id)
    |> Enum.take(@lookup_limit)
  end

  defp lookup(query, language, match) do
    with normalized when is_binary(normalized) and normalized != "" <- normalize_text(query),
         {:ok, language_id} <- lookup_language_id(language) do
      matching_forms =
        EntryForm
        |> match_forms(normalized, match)
        |> maybe_filter_language(language_id)
        |> group_by([form], form.entry_id)
        |> select([form], %{
          entry_id: form.entry_id,
          exact_match:
            fragment(
              "MAX(CASE WHEN ? = ? THEN 1 ELSE 0 END)",
              form.normalized_text,
              ^normalized
            ),
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
      |> order_by(
        [entry, match],
        desc: match.exact_match,
        desc: match.primary_match,
        asc: entry.id
      )
      |> limit(@lookup_limit)
      |> Repo.all()
      |> Repo.preload([:language, :concept, forms: forms_query])
      |> Enum.map(fn entry ->
        matched_form = best_matching_form(entry.forms, normalized, match)

        %{
          entry: entry,
          matched_form: matched_form,
          match_source: matched_form.kind,
          match_excerpt: nil
        }
      end)
    else
      _invalid_query_or_language -> []
    end
  end

  defp related_entries([], _language_id), do: []

  defp related_entries(matches, language_id) do
    concept_ids = matches |> Enum.map(& &1.entry.concept_id) |> Enum.uniq()
    forms_query = from form in EntryForm, order_by: [desc: form.is_primary, asc: form.id]

    entries =
      Entry
      |> join(:inner, [entry], concept in assoc(entry, :concept))
      |> where(
        [entry, concept],
        entry.concept_id in ^concept_ids and is_nil(entry.archived_at) and
          is_nil(concept.archived_at)
      )
      |> maybe_filter_entry_language(language_id)
      |> order_by([entry], asc: entry.id)
      |> limit(@lookup_limit)
      |> Repo.all()
      |> Repo.preload([:language, :concept, forms: forms_query])

    Enum.map(
      entries,
      &%{entry: &1, matched_form: nil, match_source: :concept, match_excerpt: nil}
    )
  end

  defp maybe_filter_entry_language(query, nil), do: query

  defp maybe_filter_entry_language(query, language_id) do
    where(query, [entry], entry.language_id == ^language_id)
  end

  def publish_new_meaning(%Language{} = language, attrs) when is_map(attrs) do
    with {:ok, multi} <- new_meaning_multi(Multi.new(), language, attrs) do
      multi
      |> Repo.transaction()
      |> public_entry_result()
    end
  end

  def publish_new_meaning(_language, _attrs), do: {:error, :invalid_attributes}

  @doc false
  def new_meaning_multi(%Multi{} = multi, %Language{} = language, attrs)
      when is_map(attrs) do
    concept_attrs = attr(attrs, :concept, %{})
    entry_attrs = attr(attrs, :entry, %{})
    forms_attrs = attr(attrs, :forms, [])

    with {:ok, language} <- active_language(language),
         :ok <- validate_forms(forms_attrs) do
      {:ok,
       multi
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
       |> Multi.run(:search_index, fn repo, %{entry: entry} ->
         Search.refresh(repo, [entry.id])
       end)}
    end
  end

  def new_meaning_multi(_multi, _language, _attrs), do: {:error, :invalid_attributes}

  def publish_equivalent(%Entry{} = source_entry, %Language{} = language, attrs)
      when is_map(attrs) do
    with {:ok, concept} <- available_concept(source_entry),
         {:ok, multi} <- existing_meaning_multi(Multi.new(), concept, language, attrs) do
      multi |> Repo.transaction() |> public_entry_result()
    end
  end

  def publish_equivalent(_source_entry, _language, _attrs),
    do: {:error, :invalid_attributes}

  @doc false
  def existing_meaning_multi(
        %Multi{} = multi,
        %Concept{} = concept,
        %Language{} = language,
        attrs
      )
      when is_map(attrs) do
    entry_attrs = attr(attrs, :entry, %{})
    forms_attrs = attr(attrs, :forms, [])

    with {:ok, language} <- active_language(language),
         {:ok, concept} <- available_concept(concept),
         :ok <- validate_forms(forms_attrs) do
      {:ok,
       multi
       |> Multi.put(:concept, concept)
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
       |> Multi.run(:search_index, fn repo, %{entry: entry} ->
         Search.refresh(repo, [entry.id])
       end)}
    end
  end

  def existing_meaning_multi(_multi, _concept, _language, _attrs),
    do: {:error, :invalid_attributes}

  def publish_usage_example(%Language{} = language, attrs) when is_map(attrs) do
    with {:ok, multi} <- usage_example_multi(Multi.new(), language, attrs) do
      multi
      |> Repo.transaction()
      |> public_example_result()
    end
  end

  def publish_usage_example(_language, _attrs),
    do: {:error, :invalid_attributes}

  @doc false
  def usage_example_multi(%Multi{} = multi, %Language{} = language, attrs)
      when is_map(attrs) do
    example_attrs = attr(attrs, :example, %{})
    links_attrs = attr(attrs, :links, [])

    with {:ok, language} <- active_language(language),
         :ok <- validate_link_set(links_attrs) do
      example = %Example{
        language_id: language.id,
        normalized_text: example_attrs |> attr(:text) |> normalize_text()
      }

      {:ok,
       multi
       |> Multi.run(:example_duplicate, fn repo, _changes ->
         reject_duplicate_example(repo, language, example.normalized_text, links_attrs)
       end)
       |> Multi.insert(:example, Example.changeset(example, example_attrs))
       |> Multi.run(:example_links, fn repo, %{example: example} ->
         insert_example_links(repo, example, links_attrs)
       end)
       |> Multi.run(:example_search_index, fn repo, %{example_links: links} ->
         entry_ids = for link <- links, link.role == :focus, do: link.entry_id
         Search.refresh(repo, entry_ids)
       end)}
    end
  end

  def usage_example_multi(_multi, _language, _attrs),
    do: {:error, :invalid_attributes}

  def suggest_example_links(%Language{} = language, text) when is_binary(text) do
    with {:ok, language} <- active_language(language) do
      ExampleMatcher.suggest(language, text)
    end
  end

  def suggest_example_links(_language, _text), do: {:error, :invalid_attributes}

  def suggest_example_links(%Language{} = language, text, focus_form)
      when is_binary(text) and is_binary(focus_form) do
    with {:ok, language} <- active_language(language) do
      ExampleMatcher.suggest(language, text, focus_form)
    end
  end

  def suggest_example_links(_language, _text, _focus_form),
    do: {:error, :invalid_attributes}

  @doc false
  def correct_entry_multi(%Multi{} = multi, %Entry{public_id: public_id}, attrs)
      when is_map(attrs) do
    entry_attrs = attr(attrs, :entry, %{})
    primary_form_text = attr(attrs, :primary_form)

    {:ok,
     multi
     |> Multi.run(:entry_target, fn repo, _changes ->
       with {:ok, entry} <- available_entry(repo, public_id) do
         {:ok, repo.preload(entry, [:language, :concept, :forms])}
       end
     end)
     |> Multi.update(:entry, fn %{entry_target: entry} ->
       Entry.changeset(entry, entry_attrs)
     end)
     |> Multi.update(:primary_form, fn %{entry_target: entry} ->
       primary_form = Enum.find(entry.forms, & &1.is_primary)

       primary_form
       |> EntryForm.changeset(%{
         text: primary_form_text,
         kind: primary_form.kind,
         is_primary: true
       })
       |> Ecto.Changeset.put_change(:normalized_text, normalize_text(primary_form_text))
     end)
     |> Multi.run(:search_index, fn repo, %{entry: entry} ->
       Search.refresh(repo, [entry.id])
     end)}
  end

  def correct_entry_multi(_multi, _entry, _attrs), do: {:error, :invalid_attributes}

  @doc false
  def add_to_entry_multi(%Multi{} = multi, %Entry{public_id: public_id}, form_attrs)
      when is_map(form_attrs) or is_nil(form_attrs) do
    multi =
      Multi.run(multi, :entry, fn repo, _changes ->
        with {:ok, entry} <- available_entry(repo, public_id) do
          {:ok, repo.preload(entry, [:language, :concept, :forms])}
        end
      end)
      |> Multi.run(:concept, fn _repo, %{entry: entry} -> {:ok, entry.concept} end)

    if form_attrs do
      multi
      |> Multi.run(:form_duplicate, fn _repo, %{entry: entry} ->
        if entry_has_form?(entry, attr(form_attrs, :text)),
          do: {:error, :already_exists},
          else: {:ok, false}
      end)
      |> Multi.insert(:form, fn %{entry: entry} ->
        EntryForm.changeset(
          %EntryForm{
            entry_id: entry.id,
            language_id: entry.language_id,
            normalized_text: form_attrs |> attr(:text) |> normalize_text()
          },
          form_attrs
        )
      end)
      |> Multi.run(:search_index, fn repo, %{entry: entry} ->
        Search.refresh(repo, [entry.id])
      end)
      |> then(&{:ok, &1})
    else
      {:ok, multi}
    end
  end

  def add_to_entry_multi(_multi, _entry, _form_attrs), do: {:error, :invalid_attributes}

  def entry_has_form?(%Entry{} = entry, text) when is_binary(text) do
    normalized_text = normalize_text(text)
    Enum.any?(entry.forms, &(&1.normalized_text == normalized_text))
  end

  def entry_has_form?(_entry, _text), do: false

  def entry_has_example?(%Entry{} = entry, text) when is_binary(text) do
    normalized_text = normalize_text(text)

    Enum.any?(entry.example_links, fn link ->
      link.example.normalized_text == normalized_text and link.role == :focus
    end)
  end

  def entry_has_example?(_entry, _text), do: false

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
        where: link.role == :focus and is_nil(example.archived_at),
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

  defp preload_concepts(nil), do: nil

  defp preload_concepts(concepts) do
    forms_query = from form in EntryForm, order_by: [desc: form.is_primary, asc: form.id]
    entries_query = from entry in Entry, where: is_nil(entry.archived_at), order_by: entry.id

    Repo.preload(concepts,
      entries: {entries_query, [:language, forms: forms_query]}
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

  defp match_forms(query, normalized, :exact) do
    where(query, [form], form.normalized_text == ^normalized)
  end

  defp match_forms(query, normalized, :prefix) do
    escaped =
      normalized
      |> String.replace("[", "[[]")
      |> String.replace("*", "[*]")
      |> String.replace("?", "[?]")

    where(query, [form], fragment("? GLOB ?", form.normalized_text, ^(escaped <> "*")))
  end

  defp best_matching_form(forms, normalized, match) do
    forms
    |> Enum.filter(&form_matches?(&1, normalized, match))
    |> Enum.min_by(fn form ->
      {
        if(form.normalized_text == normalized, do: 0, else: 1),
        if(form.is_primary, do: 0, else: 1),
        String.length(form.normalized_text),
        form.id
      }
    end)
  end

  defp form_matches?(form, normalized, :exact), do: form.normalized_text == normalized

  defp form_matches?(form, normalized, :prefix),
    do: String.starts_with?(form.normalized_text, normalized)

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

  defp available_concept(%Concept{id: id}) when is_integer(id) do
    concept =
      Concept
      |> where([concept], concept.id == ^id and is_nil(concept.archived_at))
      |> Repo.one()

    case concept do
      nil -> {:error, :meaning_unavailable}
      concept -> {:ok, concept}
    end
  end

  defp available_concept(_entry_or_concept), do: {:error, :meaning_unavailable}

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

  defp reject_duplicate_example(repo, language, normalized_text, links_attrs) do
    focus_entry_public_ids =
      for attrs <- links_attrs,
          focus_link?(attrs),
          public_id = attr(attrs, :entry_public_id),
          {:ok, public_id} <- [Ecto.UUID.cast(public_id)],
          do: public_id

    duplicate? =
      Example
      |> join(:inner, [example], link in ExampleLink, on: link.example_id == example.id)
      |> join(:inner, [_example, link], entry in Entry, on: entry.id == link.entry_id)
      |> where(
        [example, link, entry],
        example.language_id == ^language.id and
          example.normalized_text == ^normalized_text and link.role == :focus and
          entry.public_id in ^focus_entry_public_ids and is_nil(example.archived_at)
      )
      |> repo.exists?()

    if duplicate?, do: {:error, :already_exists}, else: {:ok, false}
  end

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
