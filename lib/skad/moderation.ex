defmodule Skad.Moderation do
  import Ecto.Query
  import Ecto.Changeset

  alias Ecto.Multi
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.Scope
  alias Skad.Archive
  alias Skad.Archive.{Concept, Entry, EntryForm, Example, Search}
  alias Skad.Contributions.Revision
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Repo

  def change_entry(entry, attrs \\ %{}) do
    primary = Enum.find(entry.forms, & &1.is_primary)

    %{entry | primary_form: primary.text}
    |> Entry.changeset(attrs)
    |> cast(attrs, [:primary_form])
    |> update_change(:primary_form, &trim/1)
    |> validate_required([:primary_form])
    |> validate_length(:primary_form, max: 255)
    |> validate_length(:part_of_speech, max: 100)
    |> validate_length(:variety_label, max: 255)
    |> validate_length(:place_label, max: 255)
    |> validate_length(:usage_note, max: 5_000)
    |> validate_length(:cultural_note, max: 5_000)
  end

  def change_form(form, attrs \\ %{}) do
    attrs = Map.take(attrs, ["text", "kind", :text, :kind])

    form
    |> EntryForm.changeset(attrs)
    |> update_change(:text, &trim/1)
    |> validate_length(:text, min: 1, max: 255)
    |> then(fn changeset ->
      put_change(changeset, :normalized_text, normalize(get_field(changeset, :text)))
    end)
  end

  def change_example(example, attrs \\ %{}) do
    example
    |> Example.changeset(attrs)
    |> update_change(:text, &trim/1)
    |> validate_length(:text, min: 1, max: 5_000)
    |> then(fn changeset ->
      put_change(changeset, :normalized_text, normalize(get_field(changeset, :text)))
    end)
  end

  def change_media(item, attrs \\ %{}) do
    attrs =
      Map.take(attrs, [
        "attribution_text",
        "variety_label",
        "place_label",
        :attribution_text,
        :variety_label,
        :place_label
      ])

    item
    |> Item.changeset(attrs)
    |> validate_length(:attribution_text, max: 1_000)
    |> validate_length(:variety_label, max: 255)
    |> validate_length(:place_label, max: 255)
  end

  def change_deletion(attrs \\ %{}) do
    {%{}, %{reason: :string, confirmed: :boolean}}
    |> cast(attrs, [:reason, :confirmed])
    |> update_change(:reason, &trim/1)
    |> validate_required([:reason])
    |> validate_length(:reason, max: 1_000)
    |> validate_acceptance(:confirmed)
  end

  def update_entry(scope, entry, attrs) do
    revise(scope, "entry", entry.public_id, :update, nil, fn stored ->
      changeset = change_entry(stored, attrs)
      primary = Enum.find(stored.forms, & &1.is_primary)

      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _form} <- Repo.update(change_form(primary, %{text: updated.primary_form})),
           {:ok, _ids} <- Search.refresh(Repo, [stored.id]) do
        {:ok, Archive.get_public_entry(stored.public_id)}
      else
        {:error, %Ecto.Changeset{data: %EntryForm{}}} ->
          {:error, add_error(changeset, :primary_form, "matches another form of this word")}

        error ->
          error
      end
    end)
  end

  def update_form(scope, entry, form_id, attrs) do
    revise(scope, "entry", entry.public_id, :update, nil, fn stored ->
      with %EntryForm{} = form <-
             Enum.find(stored.forms, &(to_string(&1.id) == to_string(form_id))),
           {:ok, _form} <- Repo.update(change_form(form, attrs)),
           {:ok, _ids} <- Search.refresh(Repo, [stored.id]) do
        {:ok, Archive.get_public_entry(stored.public_id)}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def delete_form(scope, entry, form_id, attrs) do
    with {:ok, reason} <- deletion_reason(attrs) do
      revise(scope, "entry", entry.public_id, :update, reason, fn stored ->
        case Enum.find(stored.forms, &(to_string(&1.id) == to_string(form_id))) do
          %EntryForm{is_primary: false} = form ->
            with {:ok, _form} <- Repo.delete(form),
                 {:ok, _ids} <- Search.refresh(Repo, [stored.id]) do
              {:ok, Archive.get_public_entry(stored.public_id)}
            end

          %EntryForm{} ->
            {:error, :primary_form_required}

          nil ->
            {:error, :not_found}
        end
      end)
    end
  end

  def update_example(scope, example, attrs, links) do
    revise(scope, "example", example.public_id, :update, nil, fn stored ->
      changeset = change_example(stored, attrs)

      if changeset.valid? do
        updated = apply_changes(changeset)
        attrs = %{text: updated.text, translations: texts(updated.translations)}

        with true <- valid_link_languages?(stored.language_id, links),
             {:ok, multi} <- Archive.replace_example_multi(Multi.new(), stored, attrs, links),
             {:ok, _changes} <- Repo.transaction(multi) do
          {:ok, Archive.get_example(stored.public_id)}
        else
          false -> {:error, :invalid_links}
          {:error, _operation, reason, _changes} -> {:error, reason}
          error -> error
        end
      else
        {:error, %{changeset | action: :update}}
      end
    end)
  end

  def update_media(scope, item, attrs) do
    revise(scope, "media", item.public_id, :update, nil, &Repo.update(change_media(&1, attrs)))
  end

  def delete_entry(scope, entry, attrs) do
    with {:ok, reason} <- deletion_reason(attrs) do
      revise(scope, "entry", entry.public_id, :archive, reason, fn stored ->
        media =
          Repo.all(
            from item in Item, where: item.entry_id == ^stored.id and is_nil(item.archived_at)
          )

        with :ok <- delete_attached_media(scope, media, attrs),
             {:ok, archived} <- archive(stored),
             {:ok, _ids} <- Search.refresh(Repo, [stored.id]) do
          {:ok, %{archived | forms: stored.forms}}
        end
      end)
    end
  end

  def delete_example(scope, example, attrs) do
    with {:ok, reason} <- deletion_reason(attrs) do
      revise(scope, "example", example.public_id, :archive, reason, fn stored ->
        with {:ok, archived} <- archive(stored),
             {:ok, _ids} <- Search.refresh(Repo, Enum.map(stored.links, & &1.entry_id)) do
          {:ok, archived}
        end
      end)
    end
  end

  def delete_media(scope, item, attrs) do
    with {:ok, reason} <- deletion_reason(attrs) do
      revise(scope, "media", item.public_id, :archive, reason, fn stored ->
        stored
        |> change(visibility: :pending_deletion, archived_at: DateTime.utc_now(:second))
        |> Repo.update()
      end)
    end
  end

  def delete_concept(scope, concept, attrs) do
    with {:ok, reason} <- deletion_reason(attrs) do
      revise(scope, "concept", concept.public_id, :archive, reason, fn stored ->
        if stored.entries != [] do
          {:error, :concept_has_words}
        else
          media = Media.list_concept_images(stored)
          with :ok <- delete_attached_media(scope, media, attrs), do: archive(stored)
        end
      end)
    end
  end

  defp revise(
         %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
         type,
         public_id,
         action,
         reason,
         work
       ) do
    Repo.transaction(fn ->
      stored = load_record(type, public_id) || Repo.rollback(:not_found)
      before_state = snapshot(stored)

      updated =
        case work.(stored) do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end

      revision = %Revision{
        target_type: type,
        target_public_id: public_id,
        action: action,
        actor_type: :moderator,
        moderator_account_id: moderator.id
      }

      case Repo.insert(
             Revision.changeset(revision, %{
               before_state: before_state,
               after_state: snapshot(updated),
               reason: reason
             })
           ) do
        {:ok, _revision} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp revise(_scope, _type, _public_id, _action, _reason, _work), do: {:error, :unauthorized}

  defp load_record("entry", id), do: Archive.get_public_entry(id)
  defp load_record("example", id), do: Archive.get_example(id)
  defp load_record("concept", id), do: Archive.get_concept(id)
  defp load_record("media", id), do: Media.get_item(id)

  defp snapshot(%Entry{} = entry) do
    entry
    |> Map.take([
      :public_id,
      :part_of_speech,
      :variety_label,
      :place_label,
      :usage_note,
      :cultural_note,
      :archived_at
    ])
    |> Map.put(:language_slug, entry.language.slug)
    |> Map.put(:concept_public_id, entry.concept.public_id)
    |> Map.put(:definitions, texts(entry.definitions))
    |> Map.put(:forms, Enum.map(entry.forms, &Map.take(&1, [:id, :text, :kind, :is_primary])))
  end

  defp snapshot(%Example{} = example) do
    example
    |> Map.take([:public_id, :text, :archived_at])
    |> Map.put(:translations, texts(example.translations))
    |> Map.put(
      :links,
      Enum.map(example.links, fn link ->
        link
        |> Map.take([:start_offset, :end_offset, :surface_text, :role])
        |> Map.put(:entry_public_id, link.entry.public_id)
      end)
    )
  end

  defp snapshot(%Item{} = item),
    do:
      Map.take(item, [
        :public_id,
        :kind,
        :variety_label,
        :place_label,
        :attribution_text,
        :visibility,
        :archived_at
      ])

  defp snapshot(%Concept{} = concept),
    do: Map.take(concept, [:public_id, :editorial_label, :editorial_note, :archived_at])

  defp texts(items), do: Enum.map(items, &Map.take(&1, [:language, :text]))

  defp normalize(text) when is_binary(text),
    do: text |> String.normalize(:nfc) |> String.trim() |> String.downcase()

  defp normalize(_text), do: nil
  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(text), do: text

  defp archive(record),
    do: record |> change(archived_at: DateTime.utc_now(:second)) |> Repo.update()

  defp deletion_reason(attrs) do
    case apply_action(change_deletion(attrs), :delete) do
      {:ok, deletion} -> {:ok, deletion.reason}
      error -> error
    end
  end

  defp delete_attached_media(scope, items, attrs) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case delete_media(scope, item, attrs) do
        {:ok, _item} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_link_languages?(language_id, links) when is_list(links) do
    Enum.all?(links, fn attrs ->
      id = Map.get(attrs, "entry_public_id") || Map.get(attrs, :entry_public_id)

      case Archive.get_public_entry(id) do
        %Entry{language_id: ^language_id} -> true
        _ -> false
      end
    end)
  end

  defp valid_link_languages?(_language_id, _links), do: false
end
