defmodule Skad.Contributions do
  import Ecto.Query

  alias Ecto.Changeset
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.Scope
  alias Skad.Archive
  alias Skad.Contributions.NewEntrySubmission
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

        event = %{
          "status" => Atom.to_string(status),
          "moderator_account_id" => moderator.id,
          "reviewed_at" => DateTime.to_iso8601(reviewed_at),
          "note" => note
        }

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

  defp preload_reviewed_by_account({:ok, submission}) do
    {:ok, Repo.preload(submission, :reviewed_by_account, force: true)}
  end

  defp preload_reviewed_by_account(result), do: result
end
