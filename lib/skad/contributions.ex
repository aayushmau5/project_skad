defmodule Skad.Contributions do
  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.Scope
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Contributions.EntryChangeSubmission
  alias Skad.Contributions.NewEntrySubmission
  alias Skad.Contributions.Revision
  alias Skad.Contributions.Submission
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Repo

  @submitted_media_key "media_public_ids"

  @review_transitions %{
    pending: [:reviewing, :clarification_needed, :rejected],
    reviewing: [:clarification_needed, :rejected],
    clarification_needed: [:reviewing, :rejected]
  }

  def change_concept(scope, concept, attrs \\ %{})

  def change_concept(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Concept{} = concept,
        attrs
      ) do
    Archive.change_concept(concept, attrs)
  end

  def change_concept(_scope, %Concept{}, _attrs), do: {:error, :unauthorized}

  def create_concept(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
        attrs
      )
      when is_map(attrs) do
    Multi.new()
    |> Multi.insert(:concept, Archive.change_concept(%Concept{}, attrs))
    |> Multi.insert(:revision, fn %{concept: concept} ->
      concept_revision(concept, :create, nil, moderator)
    end)
    |> Repo.transaction()
    |> concept_result()
  end

  def create_concept(_scope, _attrs), do: {:error, :unauthorized}

  def update_concept(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
        %Concept{id: id},
        attrs
      )
      when is_integer(id) and is_map(attrs) do
    concept =
      Concept
      |> where([concept], concept.id == ^id and is_nil(concept.archived_at))
      |> Repo.one()

    case concept do
      nil -> {:error, :concept_not_found}
      concept -> update_stored_concept(concept, attrs, moderator)
    end
  end

  def update_concept(_scope, %Concept{}, _attrs), do: {:error, :unauthorized}

  def change_new_entry(attrs \\ %{}) when is_map(attrs) do
    NewEntrySubmission.changeset(%NewEntrySubmission{}, attrs)
  end

  def submit_new_entry(attrs, media_public_ids \\ [])

  def submit_new_entry(attrs, media_public_ids)
      when is_map(attrs) and is_list(media_public_ids) do
    changeset = change_new_entry(attrs)

    if changeset.valid? do
      new_entry = Changeset.apply_changes(changeset)
      payload = NewEntrySubmission.to_payload(new_entry)

      case Repo.get_by(Submission, client_submission_id: new_entry.client_submission_id) do
        nil -> insert_new_entry(new_entry, payload, changeset, media_public_ids)
        submission -> idempotent_result(submission, payload, media_public_ids)
      end
    else
      {:error, changeset}
    end
  end

  def submit_new_entry(_attrs, _media_public_ids), do: {:error, :invalid_attributes}

  def change_entry_change(kind, entry, attrs \\ %{})

  def change_entry_change(kind, %Skad.Archive.Entry{} = entry, attrs)
      when kind in [:correction, :addition] and is_map(attrs) do
    base =
      EntryChangeSubmission.from_entry(
        entry,
        Map.get(attrs, :client_submission_id) || Map.get(attrs, "client_submission_id")
      )

    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("language_slug", entry.language.slug)
      |> then(fn attrs ->
        if kind == :addition, do: Map.put(attrs, "primary_form", base.primary_form), else: attrs
      end)

    EntryChangeSubmission.changeset(kind, base, attrs)
  end

  def submit_entry_change(kind, %Skad.Archive.Entry{} = entry, attrs)
      when kind in [:correction, :addition] and is_map(attrs) do
    changeset = change_entry_change(kind, entry, attrs)

    if changeset.valid? do
      change = Changeset.apply_changes(changeset)
      payload = EntryChangeSubmission.to_payload(kind, change)

      case Repo.get_by(Submission, client_submission_id: change.client_submission_id) do
        nil -> insert_entry_change(kind, entry, change, payload, changeset)
        submission -> entry_change_idempotent_result(submission, kind, entry, payload)
      end
    else
      {:error, changeset}
    end
  end

  def submit_entry_change(_kind, _entry, _attrs), do: {:error, :invalid_attributes}

  def get_receipt(public_id) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Submission
      |> where([submission], submission.public_id == ^public_id)
      |> select([submission], %{
        public_id: submission.public_id,
        status: submission.status,
        received_at: submission.received_at
      })
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def list_submissions_for_review(%Scope{
        moderator_account: %ModeratorAccount{active: true}
      }) do
    Submission
    |> where(
      [submission],
      submission.status in [:pending, :reviewing, :clarification_needed]
    )
    |> order_by([submission], asc: submission.received_at, asc: submission.id)
    |> preload(:reviewed_by_account)
    |> Repo.all()
  end

  def list_submissions_for_review(_scope), do: []

  def get_submission_for_review(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        public_id
      ) do
    with {:ok, public_id} <- Ecto.UUID.cast(public_id) do
      Submission
      |> where([submission], submission.public_id == ^public_id)
      |> preload(:reviewed_by_account)
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def get_submission_for_review(_scope, _public_id), do: nil

  def list_submission_media(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{} = submission
      ) do
    Media.list_submission_items(submission)
  end

  def list_submission_media(_scope, %Submission{}), do: []

  def attach_submission_media(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{} = submission,
        %Item{} = item
      ) do
    Media.attach_item_to_submission(submission, item)
  end

  def attach_submission_media(_scope, %Submission{}, %Item{}),
    do: {:error, :unauthorized}

  def replace_submission_audio(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{} = submission,
        %Item{} = item
      ) do
    Media.replace_submission_audio(submission, item)
  end

  def replace_submission_audio(_scope, %Submission{}, %Item{}),
    do: {:error, :unauthorized}

  def remove_submission_media(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{} = submission,
        %Item{} = item
      ) do
    Media.remove_submission_item(submission, item)
  end

  def remove_submission_media(_scope, %Submission{}, %Item{}),
    do: {:error, :unauthorized}

  def preview_submission_media(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{} = submission,
        %Item{} = item
      ) do
    Media.preview_submission_item(submission, item)
  end

  def preview_submission_media(_scope, %Submission{}, %Item{}),
    do: {:error, :unauthorized}

  def effective_payload(%Submission{reviewed_payload: payload}) when is_map(payload),
    do: proposal_payload(payload)

  def effective_payload(%Submission{payload: payload}), do: proposal_payload(payload)

  def suggest_example_links(%Submission{} = submission) do
    payload = effective_payload(submission)

    case payload["example"] do
      nil ->
        {:ok, []}

      text when is_binary(text) ->
        case Archive.get_language_by_slug(payload["language_slug"]) do
          %{active: true} = language ->
            Archive.suggest_example_links(language, text, payload["primary_form"])

          _missing_or_inactive ->
            {:error, :language_inactive}
        end
    end
  end

  def change_submission_for_review(scope, submission, attrs \\ %{})

  def change_submission_for_review(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{kind: :new_entry} = submission,
        attrs
      )
      when is_map(attrs) do
    submission
    |> effective_payload()
    |> Map.put("client_submission_id", submission.client_submission_id)
    |> Map.merge(stringify_keys(attrs))
    |> change_new_entry()
  end

  def change_submission_for_review(
        %Scope{moderator_account: %ModeratorAccount{active: true}},
        %Submission{kind: kind, target_type: "entry"} = submission,
        attrs
      )
      when kind in [:correction, :addition] and is_map(attrs) do
    case Archive.get_public_entry(submission.target_public_id) do
      %Skad.Archive.Entry{} = entry ->
        submission
        |> effective_payload()
        |> Map.put("client_submission_id", submission.client_submission_id)
        |> Map.merge(stringify_keys(attrs))
        |> then(&change_entry_change(kind, entry, &1))

      nil ->
        {:error, :target_not_found}
    end
  end

  def change_submission_for_review(_scope, %Submission{}, _attrs),
    do: {:error, :unauthorized}

  def update_submission_for_review(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator} = scope,
        %Submission{id: id},
        attrs
      )
      when is_integer(id) and is_map(attrs) do
    with %Submission{} = submission <- Repo.get(Submission, id),
         :ok <- editable?(submission) do
      changeset = change_submission_for_review(scope, submission, attrs)

      if changeset.valid? do
        reviewed = Changeset.apply_changes(changeset)

        case Archive.get_language_by_slug(reviewed.language_slug) do
          %{active: true} ->
            save_submission_edits(
              submission,
              moderator,
              reviewed_payload(submission.kind, reviewed)
            )

          _missing_or_inactive ->
            {:error, Changeset.add_error(changeset, :language_slug, "is not active")}
        end
      else
        {:error, changeset}
      end
    else
      nil -> {:error, :submission_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_submission_for_review(_scope, %Submission{}, _attrs),
    do: {:error, :unauthorized}

  defp reviewed_payload(:new_entry, reviewed), do: NewEntrySubmission.to_payload(reviewed)

  defp reviewed_payload(kind, reviewed) when kind in [:correction, :addition],
    do: EntryChangeSubmission.to_payload(kind, reviewed)

  def moderate_submission(scope, submission, status, note \\ nil)

  def moderate_submission(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
        %Submission{} = submission,
        status,
        note
      ) do
    note = normalize_review_note(note)

    cond do
      status not in Map.get(@review_transitions, submission.status, []) ->
        {:error, :invalid_transition}

      status in [:clarification_needed, :rejected] and is_nil(note) ->
        {:error, :review_note_required}

      true ->
        reviewed_at = DateTime.utc_now(:second)
        event = review_event(status, moderator, reviewed_at, note)

        submission
        |> Submission.moderation_changeset(%{
          status: status,
          review_history: submission.review_history ++ [event],
          reviewed_at: reviewed_at,
          review_note: note
        })
        |> Changeset.put_change(:reviewed_by_account_id, moderator.id)
        |> Repo.update()
        |> preload_reviewed_by_account()
    end
  end

  def moderate_submission(_scope, %Submission{}, _status, _note), do: {:error, :unauthorized}

  def approve_submission(
        scope,
        submission,
        note \\ nil,
        example_choices \\ %{},
        concept_params \\ %{}
      )

  def approve_submission(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
        %Submission{kind: :new_entry, id: id},
        note,
        example_choices,
        concept_params
      )
      when is_integer(id) do
    note = normalize_review_note(note)

    with %Submission{} = submission <- Repo.get(Submission, id),
         :ok <- approvable?(submission),
         payload = effective_payload(submission),
         {:ok, language, archive_attrs} <-
           new_entry_archive_attrs(payload),
         {:ok, concept, archive_attrs} <- concept_choice(concept_params, archive_attrs),
         {:ok, example_plan} <- example_plan(language, payload, example_choices),
         {:ok, multi} <-
           approval_multi(submission, moderator, note)
           |> meaning_multi(concept, language, archive_attrs) do
      multi
      |> Media.publish_submission_items_multi(submission)
      |> add_example_multi(language, example_plan)
      |> Multi.insert(:revision, fn changes ->
        %Revision{
          target_type: "entry",
          target_public_id: changes.entry.public_id,
          action: :create,
          actor_type: :moderator,
          moderator_account_id: moderator.id,
          submission_id: submission.id
        }
        |> Revision.changeset(%{
          after_state: entry_snapshot(changes, language, example_plan),
          reason: note
        })
      end)
      |> Repo.transaction()
      |> approval_result()
    else
      nil -> {:error, :submission_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def approve_submission(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
        %Submission{kind: kind, id: id},
        note,
        example_choices,
        _concept_params
      )
      when kind in [:correction, :addition] and is_integer(id) do
    note = normalize_review_note(note)

    with %Submission{kind: ^kind} = submission <- Repo.get(Submission, id),
         :ok <- approvable?(submission),
         %Skad.Archive.Entry{} = entry <- Archive.get_public_entry(submission.target_public_id) do
      approve_entry_change(submission, entry, moderator, note, example_choices)
    else
      nil -> {:error, :target_not_found}
      {:error, reason} -> {:error, reason}
      _changed_kind -> {:error, :invalid_transition}
    end
  end

  def approve_submission(_scope, %Submission{}, _note, _example_choices, _concept_params),
    do: {:error, :unauthorized}

  defp approve_entry_change(
         %Submission{kind: :correction} = submission,
         entry,
         moderator,
         note,
         _choices
       ) do
    payload = effective_payload(submission)
    before_state = canonical_entry_snapshot(entry)

    with {:ok, archive_attrs} <- correction_archive_attrs(payload),
         {:ok, multi} <-
           approval_multi(submission, moderator, note)
           |> Archive.correct_entry_multi(entry, archive_attrs) do
      multi
      |> Multi.insert(:revision, fn changes ->
        entry_revision(
          changes.entry,
          submission,
          moderator,
          note,
          before_state,
          corrected_entry_snapshot(before_state, changes)
        )
      end)
      |> Repo.transaction()
      |> approval_result()
    end
  end

  defp approve_entry_change(
         %Submission{kind: :addition} = submission,
         entry,
         moderator,
         note,
         choices
       ) do
    payload = effective_payload(submission)
    before_state = canonical_entry_snapshot(entry)
    form_attrs = addition_form_attrs(payload)

    with {:ok, language} <- active_submission_language(payload),
         {:ok, example_plan} <- example_plan(language, payload, choices, entry.public_id),
         {:ok, multi} <-
           approval_multi(submission, moderator, note)
           |> Archive.add_to_entry_multi(entry, form_attrs) do
      multi
      |> add_example_multi(language, example_plan)
      |> Multi.insert(:revision, fn changes ->
        entry_revision(
          changes.entry,
          submission,
          moderator,
          note,
          before_state,
          added_entry_snapshot(before_state, changes, example_plan)
        )
      end)
      |> Repo.transaction()
      |> approval_result()
    end
  end

  defp concept_choice(concept_params, archive_attrs) when is_map(concept_params) do
    case concept_param(concept_params, :public_id) do
      public_id when public_id in [nil, ""] ->
        default_attrs = Map.fetch!(archive_attrs, :concept)

        concept_attrs = %{
          editorial_label:
            concept_param(concept_params, :editorial_label, default_attrs.editorial_label),
          editorial_note: concept_param(concept_params, :editorial_note)
        }

        {:ok, nil, Map.put(archive_attrs, :concept, concept_attrs)}

      public_id when is_binary(public_id) ->
        case Archive.get_concept(String.trim(public_id)) do
          nil -> {:error, :concept_not_found}
          concept -> {:ok, concept, archive_attrs}
        end

      _invalid_public_id ->
        {:error, :concept_not_found}
    end
  end

  defp concept_choice(_concept_params, _archive_attrs), do: {:error, :concept_not_found}

  defp concept_param(params, key, default \\ nil) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key)) || default
  end

  defp meaning_multi(multi, nil, language, archive_attrs),
    do: Archive.new_meaning_multi(multi, language, archive_attrs)

  defp meaning_multi(multi, %Concept{} = concept, language, archive_attrs),
    do: Archive.existing_meaning_multi(multi, concept, language, archive_attrs)

  defp insert_new_entry(new_entry, payload, command_changeset, media_public_ids) do
    case Archive.get_language_by_slug(new_entry.language_slug) do
      %{active: true} ->
        stored_payload = put_submitted_media(payload, media_public_ids)

        Multi.new()
        |> Multi.insert(
          :submission,
          Submission.changeset(%Submission{kind: :new_entry}, %{
            client_submission_id: new_entry.client_submission_id,
            payload: stored_payload
          })
        )
        |> Media.claim_submission_items_multi(media_public_ids)
        |> Repo.transaction()
        |> inserted_result(payload, media_public_ids)

      _missing_or_inactive ->
        {:error, Changeset.add_error(command_changeset, :language_slug, "is not active")}
    end
  end

  defp insert_entry_change(kind, entry, change, payload, command_changeset) do
    case Archive.get_public_entry(entry.public_id) do
      %Skad.Archive.Entry{} = target ->
        %Submission{
          kind: kind,
          target_type: "entry",
          target_public_id: target.public_id
        }
        |> Submission.changeset(%{
          client_submission_id: change.client_submission_id,
          payload: payload
        })
        |> Repo.insert()
        |> case do
          {:ok, submission} ->
            {:ok, receipt(submission)}

          {:error, %Changeset{} = changeset} ->
            if Keyword.has_key?(changeset.errors, :client_submission_id) do
              submission =
                Repo.get_by!(Submission,
                  client_submission_id: Changeset.get_field(changeset, :client_submission_id)
                )

              entry_change_idempotent_result(submission, kind, target, payload)
            else
              {:error, changeset}
            end
        end

      nil ->
        {:error, Changeset.add_error(command_changeset, :primary_form, "entry is unavailable")}
    end
  end

  defp entry_change_idempotent_result(
         %Submission{
           kind: kind,
           target_type: "entry",
           target_public_id: target_public_id,
           payload: stored_payload
         } = submission,
         kind,
         %{public_id: target_public_id},
         payload
       ) do
    if stored_payload == payload,
      do: {:ok, receipt(submission)},
      else: {:error, :idempotency_conflict}
  end

  defp entry_change_idempotent_result(_submission, _kind, _entry, _payload),
    do: {:error, :idempotency_conflict}

  defp inserted_result({:ok, %{submission: submission}}, _payload, _media_public_ids),
    do: {:ok, receipt(submission)}

  defp inserted_result(
         {:error, :submission, %Changeset{} = changeset, _changes},
         payload,
         media_public_ids
       ) do
    if Keyword.has_key?(changeset.errors, :client_submission_id) do
      submission =
        Repo.get_by!(Submission,
          client_submission_id: Changeset.get_field(changeset, :client_submission_id)
        )

      idempotent_result(submission, payload, media_public_ids)
    else
      {:error, changeset}
    end
  end

  defp inserted_result({:error, :media, reason, _changes}, _payload, _media_public_ids),
    do: {:error, reason}

  defp idempotent_result(
         %Submission{kind: :new_entry, payload: stored_payload} = submission,
         payload,
         media_public_ids
       ) do
    stored_media_public_ids = Map.get(stored_payload, @submitted_media_key, [])
    stored_payload = proposal_payload(stored_payload)

    if stored_payload == payload and
         Enum.sort(stored_media_public_ids) == Enum.sort(media_public_ids) do
      {:ok, receipt(submission)}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp idempotent_result(_submission, _payload, _media_public_ids),
    do: {:error, :idempotency_conflict}

  defp put_submitted_media(payload, []), do: payload

  defp put_submitted_media(payload, media_public_ids) do
    Map.put(payload, @submitted_media_key, Enum.sort(media_public_ids))
  end

  defp proposal_payload(payload), do: Map.delete(payload, @submitted_media_key)

  defp receipt(submission) do
    %{
      public_id: submission.public_id,
      status: submission.status,
      received_at: submission.received_at
    }
  end

  defp normalize_review_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      note -> note
    end
  end

  defp normalize_review_note(_note), do: nil

  defp approvable?(%Submission{status: status, kind: kind})
       when status in [:pending, :reviewing] and kind in [:new_entry, :correction, :addition],
       do: :ok

  defp approvable?(%Submission{status: status}) when status in [:pending, :reviewing],
    do: {:error, :unsupported_submission_kind}

  defp approvable?(%Submission{}), do: {:error, :invalid_transition}

  defp editable?(%Submission{status: status, kind: kind})
       when status in [:pending, :reviewing] and kind in [:new_entry, :correction, :addition],
       do: :ok

  defp editable?(%Submission{status: status}) when status in [:pending, :reviewing],
    do: {:error, :unsupported_submission_kind}

  defp editable?(%Submission{}), do: {:error, :invalid_transition}

  defp save_submission_edits(submission, moderator, payload) do
    if payload == effective_payload(submission) do
      {:ok, Repo.preload(submission, :reviewed_by_account)}
    else
      reviewed_at = DateTime.utc_now(:second)

      event = %{
        "action" => "edited",
        "moderator_account_id" => moderator.id,
        "reviewed_at" => DateTime.to_iso8601(reviewed_at),
        "changed_fields" => changed_fields(effective_payload(submission), payload)
      }

      submission
      |> Submission.moderation_changeset(%{
        status: :reviewing,
        reviewed_payload: payload,
        review_history: submission.review_history ++ [event],
        reviewed_at: reviewed_at
      })
      |> Changeset.put_change(:reviewed_by_account_id, moderator.id)
      |> Repo.update()
      |> preload_reviewed_by_account()
    end
  end

  defp changed_fields(original, reviewed) do
    reviewed
    |> Map.keys()
    |> Enum.filter(&(Map.get(original, &1) != Map.get(reviewed, &1)))
    |> Enum.sort()
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp correction_archive_attrs(
         %{
           "language_slug" => language_slug,
           "primary_form" => primary_form,
           "definition" => definition
         } = payload
       )
       when is_binary(language_slug) and is_binary(primary_form) and is_binary(definition) do
    {:ok,
     %{
       primary_form: primary_form,
       entry: %{
         definitions: [%{language: language_slug, text: definition}],
         part_of_speech: payload["part_of_speech"],
         usage_note: payload["usage_note"],
         cultural_note: payload["cultural_note"]
       }
     }}
  end

  defp correction_archive_attrs(_payload), do: {:error, :unsupported_payload}

  defp addition_form_attrs(%{"alternate_form" => nil}), do: nil
  defp addition_form_attrs(%{"alternate_form" => ""}), do: nil

  defp addition_form_attrs(%{"alternate_form" => text, "form_kind" => kind})
       when is_binary(text) and is_binary(kind) do
    %{text: text, kind: kind, is_primary: false}
  end

  defp addition_form_attrs(_payload), do: nil

  defp active_submission_language(%{"language_slug" => language_slug}) do
    case Archive.get_language_by_slug(language_slug) do
      %{active: true} = language -> {:ok, language}
      _missing_or_inactive -> {:error, :language_inactive}
    end
  end

  defp active_submission_language(_payload), do: {:error, :unsupported_payload}

  defp new_entry_archive_attrs(
         %{
           "language_slug" => language_slug,
           "primary_form" => primary_form,
           "definition" => definition
         } = payload
       )
       when is_binary(language_slug) and is_binary(primary_form) and is_binary(definition) do
    case Archive.get_language_by_slug(language_slug) do
      %{active: true} = language ->
        {:ok, language,
         %{
           concept: %{editorial_label: primary_form},
           entry: %{
             definitions: [%{language: language_slug, text: definition}],
             part_of_speech: payload["part_of_speech"],
             usage_note: payload["usage_note"],
             cultural_note: payload["cultural_note"]
           },
           forms: [%{text: primary_form, kind: :spelling, is_primary: true}]
         }}

      _missing_or_inactive ->
        {:error, :language_inactive}
    end
  end

  defp new_entry_archive_attrs(_payload), do: {:error, :unsupported_payload}

  defp approval_multi(submission, moderator, note) do
    reviewed_at = DateTime.utc_now(:second)
    event = review_event(:approved, moderator, reviewed_at, note)

    approval_query =
      from stored_submission in Submission,
        where:
          stored_submission.id == ^submission.id and
            stored_submission.status == ^submission.status

    Multi.new()
    |> Multi.update_all(:approval_claim, approval_query,
      set: [
        status: :approved,
        review_history: submission.review_history ++ [event],
        reviewed_by_account_id: moderator.id,
        reviewed_at: reviewed_at,
        review_note: note
      ]
    )
    |> Multi.run(:submission, fn repo, %{approval_claim: {count, _rows}} ->
      if count == 1,
        do: {:ok, repo.get!(Submission, submission.id)},
        else: {:error, :invalid_transition}
    end)
  end

  defp example_plan(language, payload, choices, focus_entry_public_id \\ :new_entry)

  defp example_plan(_language, %{"example" => nil}, _choices, _focus_entry_public_id),
    do: {:ok, nil}

  defp example_plan(language, payload, choices, focus_entry_public_id) do
    with text when is_binary(text) <- payload["example"],
         primary_form when is_binary(primary_form) <- payload["primary_form"],
         {:ok, suggestions} <- Archive.suggest_example_links(language, text, primary_form),
         true <- Enum.any?(suggestions, &(&1.role == :focus)) || {:error, :example_focus_missing},
         {:ok, links} <- confirmed_example_links(suggestions, choices, focus_entry_public_id) do
      {:ok, %{example: %{text: text, translations: []}, links: links}}
    else
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _invalid_payload -> {:error, :unsupported_payload}
    end
  end

  defp confirmed_example_links(suggestions, choices, focus_entry_public_id)
       when is_map(choices) do
    suggestions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {suggestion, index}, {:ok, links} ->
      link = %{
        start_offset: suggestion.start_offset,
        end_offset: suggestion.end_offset,
        role: suggestion.role
      }

      case suggestion.role do
        :focus ->
          {:cont, {:ok, [Map.put(link, :entry_public_id, focus_entry_public_id) | links]}}

        :reference ->
          choice = Map.get(choices, Integer.to_string(index), Map.get(choices, index))

          cond do
            choice in [nil, ""] ->
              {:cont, {:ok, links}}

            entry = Enum.find(suggestion.candidates, &(&1.public_id == choice)) ->
              {:cont, {:ok, [Map.put(link, :entry_public_id, entry.public_id) | links]}}

            true ->
              {:halt, {:error, :invalid_example_links}}
          end
      end
    end)
    |> case do
      {:ok, links} -> {:ok, Enum.reverse(links)}
      error -> error
    end
  end

  defp confirmed_example_links(_suggestions, _choices, _focus_entry_public_id),
    do: {:error, :invalid_example_links}

  defp add_example_multi(multi, _language, nil), do: multi

  defp add_example_multi(multi, language, example_plan) do
    Multi.merge(multi, fn %{entry: entry} ->
      links =
        Enum.map(example_plan.links, fn
          %{entry_public_id: :new_entry} = link ->
            %{link | entry_public_id: entry.public_id}

          link ->
            link
        end)

      case Archive.usage_example_multi(Multi.new(), language, %{
             example: example_plan.example,
             links: links
           }) do
        {:ok, example_multi} -> example_multi
        {:error, reason} -> Multi.error(Multi.new(), :example, reason)
      end
    end)
  end

  defp entry_snapshot(changes, language, example_plan) do
    snapshot = %{
      "public_id" => changes.entry.public_id,
      "concept_public_id" => changes.concept.public_id,
      "language_slug" => language.slug,
      "definitions" =>
        Enum.map(changes.entry.definitions, fn definition ->
          %{"language" => definition.language, "text" => definition.text}
        end),
      "forms" =>
        Enum.map(changes.forms, fn form ->
          %{
            "text" => form.text,
            "kind" => Atom.to_string(form.kind),
            "is_primary" => form.is_primary
          }
        end),
      "part_of_speech" => changes.entry.part_of_speech,
      "usage_note" => changes.entry.usage_note,
      "cultural_note" => changes.entry.cultural_note
    }

    if example_plan do
      Map.put(snapshot, "example", %{
        "public_id" => changes.example.public_id,
        "text" => changes.example.text,
        "links" =>
          Enum.map(example_plan.links, fn link ->
            %{
              "entry_public_id" =>
                if(link.entry_public_id == :new_entry,
                  do: changes.entry.public_id,
                  else: link.entry_public_id
                ),
              "start_offset" => link.start_offset,
              "end_offset" => link.end_offset,
              "role" => Atom.to_string(link.role)
            }
          end)
      })
    else
      snapshot
    end
  end

  defp canonical_entry_snapshot(entry) do
    %{
      "public_id" => entry.public_id,
      "concept_public_id" => entry.concept.public_id,
      "language_slug" => entry.language.slug,
      "definitions" =>
        Enum.map(entry.definitions, fn definition ->
          %{"language" => definition.language, "text" => definition.text}
        end),
      "forms" => Enum.map(entry.forms, &form_snapshot/1),
      "part_of_speech" => entry.part_of_speech,
      "usage_note" => entry.usage_note,
      "cultural_note" => entry.cultural_note,
      "examples" =>
        entry.example_links
        |> Enum.map(& &1.example)
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(fn example ->
          %{"public_id" => example.public_id, "text" => example.text}
        end)
    }
  end

  defp corrected_entry_snapshot(before_state, changes) do
    before_state
    |> Map.put(
      "definitions",
      Enum.map(changes.entry.definitions, fn definition ->
        %{"language" => definition.language, "text" => definition.text}
      end)
    )
    |> Map.put(
      "forms",
      Enum.map(before_state["forms"], fn form ->
        if form["is_primary"], do: form_snapshot(changes.primary_form), else: form
      end)
    )
    |> Map.put("part_of_speech", changes.entry.part_of_speech)
    |> Map.put("usage_note", changes.entry.usage_note)
    |> Map.put("cultural_note", changes.entry.cultural_note)
  end

  defp added_entry_snapshot(before_state, changes, example_plan) do
    after_state =
      case Map.get(changes, :form) do
        nil -> before_state
        form -> Map.update!(before_state, "forms", &(&1 ++ [form_snapshot(form)]))
      end

    if example_plan do
      example = %{"public_id" => changes.example.public_id, "text" => changes.example.text}
      Map.update!(after_state, "examples", &(&1 ++ [example]))
    else
      after_state
    end
  end

  defp form_snapshot(form) do
    %{
      "text" => form.text,
      "kind" => Atom.to_string(form.kind),
      "is_primary" => form.is_primary
    }
  end

  defp entry_revision(entry, submission, moderator, note, before_state, after_state) do
    %Revision{
      target_type: "entry",
      target_public_id: entry.public_id,
      action: :update,
      actor_type: :moderator,
      moderator_account_id: moderator.id,
      submission_id: submission.id
    }
    |> Revision.changeset(%{
      before_state: before_state,
      after_state: after_state,
      reason: note
    })
  end

  defp update_stored_concept(concept, attrs, moderator) do
    before_state = concept_snapshot(concept)

    Multi.new()
    |> Multi.update(:concept, Archive.change_concept(concept, attrs))
    |> Multi.insert(:revision, fn %{concept: updated_concept} ->
      concept_revision(updated_concept, :update, before_state, moderator)
    end)
    |> Repo.transaction()
    |> concept_result()
  end

  defp concept_revision(concept, action, before_state, moderator) do
    %Revision{
      target_type: "concept",
      target_public_id: concept.public_id,
      action: action,
      actor_type: :moderator,
      moderator_account_id: moderator.id
    }
    |> Revision.changeset(%{
      before_state: before_state,
      after_state: concept_snapshot(concept)
    })
  end

  defp concept_snapshot(concept) do
    %{
      "public_id" => concept.public_id,
      "editorial_label" => concept.editorial_label,
      "editorial_note" => concept.editorial_note
    }
  end

  defp review_event(status, moderator, reviewed_at, note) do
    %{
      "status" => Atom.to_string(status),
      "moderator_account_id" => moderator.id,
      "reviewed_at" => DateTime.to_iso8601(reviewed_at),
      "note" => note
    }
  end

  defp approval_result({:ok, %{entry: entry, submission: submission}}) do
    {:ok,
     %{
       entry: Archive.get_public_entry(entry.public_id),
       submission: Repo.preload(submission, :reviewed_by_account)
     }}
  end

  defp approval_result({:error, _operation, reason, _changes}), do: {:error, reason}

  defp concept_result({:ok, %{concept: concept}}), do: {:ok, concept}
  defp concept_result({:error, _operation, reason, _changes}), do: {:error, reason}

  defp preload_reviewed_by_account({:ok, submission}) do
    {:ok, Repo.preload(submission, :reviewed_by_account, force: true)}
  end

  defp preload_reviewed_by_account(result), do: result
end
