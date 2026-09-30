defmodule Skad.Contributions do
  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.Scope
  alias Skad.Archive
  alias Skad.Contributions.NewEntrySubmission
  alias Skad.Contributions.Revision
  alias Skad.Contributions.Submission
  alias Skad.Repo

  @review_transitions %{
    pending: [:reviewing, :clarification_needed, :rejected],
    reviewing: [:clarification_needed, :rejected],
    clarification_needed: [:reviewing, :rejected]
  }

  def change_new_entry(attrs \\ %{}) when is_map(attrs) do
    NewEntrySubmission.changeset(%NewEntrySubmission{}, attrs)
  end

  def submit_new_entry(attrs) when is_map(attrs) do
    changeset = change_new_entry(attrs)

    if changeset.valid? do
      new_entry = Changeset.apply_changes(changeset)
      payload = NewEntrySubmission.to_payload(new_entry)

      case Repo.get_by(Submission, client_submission_id: new_entry.client_submission_id) do
        nil -> insert_new_entry(new_entry, payload, changeset)
        submission -> idempotent_result(submission, payload)
      end
    else
      {:error, changeset}
    end
  end

  def submit_new_entry(_attrs), do: {:error, :invalid_attributes}

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

  def effective_payload(%Submission{reviewed_payload: payload}) when is_map(payload), do: payload
  def effective_payload(%Submission{payload: payload}), do: payload

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
              NewEntrySubmission.to_payload(reviewed)
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

  def approve_submission(scope, submission, note \\ nil, example_choices \\ %{})

  def approve_submission(
        %Scope{moderator_account: %ModeratorAccount{active: true} = moderator},
        %Submission{id: id},
        note,
        example_choices
      )
      when is_integer(id) do
    note = normalize_review_note(note)

    with %Submission{} = submission <- Repo.get(Submission, id),
         :ok <- approvable?(submission),
         payload = effective_payload(submission),
         {:ok, language, archive_attrs} <-
           new_entry_archive_attrs(payload),
         {:ok, example_plan} <- example_plan(language, payload, example_choices),
         {:ok, multi} <-
           approval_multi(submission, moderator, note)
           |> Archive.new_meaning_multi(language, archive_attrs) do
      multi
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

  def approve_submission(_scope, %Submission{}, _note, _example_choices),
    do: {:error, :unauthorized}

  defp insert_new_entry(new_entry, payload, command_changeset) do
    case Archive.get_language_by_slug(new_entry.language_slug) do
      %{active: true} ->
        %Submission{kind: :new_entry}
        |> Submission.changeset(%{
          client_submission_id: new_entry.client_submission_id,
          payload: payload
        })
        |> Repo.insert()
        |> inserted_result(payload)

      _missing_or_inactive ->
        {:error, Changeset.add_error(command_changeset, :language_slug, "is not active")}
    end
  end

  defp inserted_result({:ok, submission}, _payload), do: {:ok, receipt(submission)}

  defp inserted_result({:error, changeset}, payload) do
    if Keyword.has_key?(changeset.errors, :client_submission_id) do
      submission =
        Repo.get_by!(Submission,
          client_submission_id: Changeset.get_field(changeset, :client_submission_id)
        )

      idempotent_result(submission, payload)
    else
      {:error, changeset}
    end
  end

  defp idempotent_result(%Submission{kind: :new_entry, payload: payload} = submission, payload) do
    {:ok, receipt(submission)}
  end

  defp idempotent_result(_submission, _payload), do: {:error, :idempotency_conflict}

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

  defp approvable?(%Submission{status: status, kind: :new_entry})
       when status in [:pending, :reviewing],
       do: :ok

  defp approvable?(%Submission{status: status}) when status in [:pending, :reviewing],
    do: {:error, :unsupported_submission_kind}

  defp approvable?(%Submission{}), do: {:error, :invalid_transition}

  defp editable?(%Submission{status: status, kind: :new_entry})
       when status in [:pending, :reviewing],
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

  defp example_plan(_language, %{"example" => nil}, _choices), do: {:ok, nil}

  defp example_plan(language, payload, choices) do
    with text when is_binary(text) <- payload["example"],
         primary_form when is_binary(primary_form) <- payload["primary_form"],
         {:ok, suggestions} <- Archive.suggest_example_links(language, text, primary_form),
         true <- Enum.any?(suggestions, &(&1.role == :focus)) || {:error, :example_focus_missing},
         {:ok, links} <- confirmed_example_links(suggestions, choices) do
      {:ok, %{example: %{text: text, translations: []}, links: links}}
    else
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _invalid_payload -> {:error, :unsupported_payload}
    end
  end

  defp confirmed_example_links(suggestions, choices) when is_map(choices) do
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
          {:cont, {:ok, [Map.put(link, :entry_public_id, :new_entry) | links]}}

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

  defp confirmed_example_links(_suggestions, _choices), do: {:error, :invalid_example_links}

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

  defp preload_reviewed_by_account({:ok, submission}) do
    {:ok, Repo.preload(submission, :reviewed_by_account, force: true)}
  end

  defp preload_reviewed_by_account(result), do: result
end
