defmodule Skad.Contributions do
  import Ecto.Query

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Contributions.NewEntrySubmission
  alias Skad.Contributions.Submission
  alias Skad.Repo

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
end
