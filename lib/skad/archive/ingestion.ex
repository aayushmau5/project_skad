defmodule Skad.Archive.Ingestion do
  @moduledoc """
  Imports prepared manifests atomically, retaining imported UUIDs across reruns.
  Existing records are skipped, including records subsequently edited by moderators.
  """

  alias Ecto.Multi
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Repo

  def import(%{"version" => 1, "language" => %{"slug" => slug} = attrs, "meanings" => meanings})
      when is_binary(slug) and slug != "" and is_list(meanings) and meanings != [] do
    Repo.transaction(fn ->
      validate_identities!(meanings)
      language = Archive.get_language_by_slug(slug) || unwrap!(Archive.create_language(attrs))

      unless language.active, do: Repo.rollback(:language_inactive)

      Enum.reduce(meanings, %{inserted: 0, skipped: 0}, fn meaning, counts ->
        import_meaning(meaning, language, counts)
      end)
    end)
  end

  def import(_manifest), do: {:error, :invalid_manifest}

  defp validate_identities!(meanings) do
    ids =
      Enum.flat_map(meanings, fn
        %{"public_id" => id, "entries" => entries} when is_list(entries) ->
          [
            uuid!(id)
            | Enum.map(entries, fn
                %{"public_id" => id} -> uuid!(id)
                _invalid -> Repo.rollback(:invalid_entry)
              end)
          ]

        _invalid ->
          Repo.rollback(:invalid_meaning)
      end)

    unless length(ids) == MapSet.size(MapSet.new(ids)),
      do: Repo.rollback(:duplicate_public_id)
  end

  defp import_meaning(
         %{"public_id" => public_id, "concept" => attrs, "entries" => entries},
         language,
         counts
       )
       when is_map(attrs) and is_list(entries) and entries != [] do
    public_id = uuid!(public_id)
    concept = Repo.get_by(Concept, public_id: public_id)

    {counts, _concept} =
      Enum.reduce(entries, {counts, concept}, fn spec, {counts, concept} ->
        case existing_entry(spec, language, public_id) do
          %Entry{} ->
            {%{counts | skipped: counts.skipped + 1}, concept}

          nil ->
            concept =
              concept ||
                unwrap!(
                  %Concept{public_id: public_id}
                  |> Concept.changeset(attrs)
                  |> Repo.insert()
                )

            insert_entry!(spec, language, concept)
            {%{counts | inserted: counts.inserted + 1}, concept}
        end
      end)

    counts
  end

  defp import_meaning(_meaning, _language, _counts), do: Repo.rollback(:invalid_meaning)

  defp existing_entry(
         %{"public_id" => public_id, "entry" => attrs, "forms" => forms},
         language,
         concept_public_id
       )
       when is_map(attrs) and is_list(forms) do
    case Repo.get_by(Entry, public_id: uuid!(public_id)) |> Repo.preload(:concept) do
      nil ->
        nil

      %{language_id: language_id, concept: %{public_id: ^concept_public_id}} = entry
      when language_id == language.id ->
        entry

      _conflict ->
        Repo.rollback({:identity_conflict, public_id})
    end
  end

  defp existing_entry(_spec, _language, _concept_public_id),
    do: Repo.rollback(:invalid_entry)

  defp insert_entry!(spec, language, concept) do
    with {:ok, multi} <- Archive.existing_meaning_multi(Multi.new(), concept, language, spec),
         {:ok, _changes} <-
           multi
           |> Multi.update(:import_identity, fn %{entry: entry} ->
             Ecto.Changeset.change(entry, public_id: uuid!(spec["public_id"]))
           end)
           |> Repo.transaction() do
      :ok
    else
      {:error, _operation, reason, _changes} ->
        Repo.rollback({:entry_failed, spec["source_rows"], reason})

      {:error, reason} ->
        Repo.rollback({:entry_failed, spec["source_rows"], reason})
    end
  end

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Repo.rollback({:invalid_public_id, value})
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
