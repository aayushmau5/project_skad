defmodule Skad.ContributionsSchemasTest do
  use Skad.DataCase

  alias Skad.Accounts.ModeratorAccount
  alias Skad.Contributions.Revision
  alias Skad.Contributions.Submission

  test "persists a pending submission with server-generated receipt fields" do
    {:ok, submission} = insert_submission()

    assert {:ok, _public_id} = Ecto.UUID.cast(submission.public_id)
    assert submission.kind == :new_entry
    assert submission.status == :pending
    assert submission.review_history == []
    assert submission.payload == %{"definition" => "private contribution text"}
    refute inspect(submission) =~ "private contribution text"
    assert submission.received_at
  end

  test "validates client identifiers and maps unique constraints" do
    invalid =
      %Submission{kind: :new_entry}
      |> Submission.changeset(%{client_submission_id: "not-a-uuid", payload: %{}})

    refute invalid.valid?
    assert "is invalid" in errors_on(invalid).client_submission_id

    client_submission_id = Ecto.UUID.generate()
    assert {:ok, _submission} = insert_submission(client_submission_id)
    assert {:error, duplicate} = insert_submission(client_submission_id)
    assert "has already been taken" in errors_on(duplicate).client_submission_id
  end

  test "maps incomplete target constraints" do
    submission = %Submission{kind: :correction, target_type: "entry"}

    assert {:error, changeset} =
             submission
             |> Submission.changeset(%{
               client_submission_id: Ecto.UUID.generate(),
               payload: %{}
             })
             |> Repo.insert()

    assert "must be present with target type" in errors_on(changeset).target_public_id
  end

  test "persists review metadata and revision associations" do
    {:ok, submission} = insert_submission()
    moderator = insert_moderator()
    reviewed_at = DateTime.utc_now(:second)

    assert {:ok, reviewed_submission} =
             submission
             |> Submission.moderation_changeset(%{
               status: :reviewing,
               review_history: [%{"status" => "reviewing"}],
               reviewed_at: reviewed_at,
               review_note: "Checking details"
             })
             |> Ecto.Changeset.put_change(:reviewed_by_account_id, moderator.id)
             |> Repo.update()

    assert reviewed_submission.reviewed_by_account_id == moderator.id
    assert reviewed_submission.review_history == [%{"status" => "reviewing"}]

    target_public_id = Ecto.UUID.generate()

    assert {:ok, revision} =
             %Revision{
               target_type: "entry",
               target_public_id: target_public_id,
               action: :create,
               actor_type: :moderator,
               moderator_account_id: moderator.id,
               submission_id: submission.id
             }
             |> Revision.changeset(%{after_state: %{"definition" => "snapshot secret"}})
             |> Repo.insert()

    assert revision.inserted_at
    assert revision.submission_id == submission.id
    assert revision.moderator_account_id == moderator.id
    refute inspect(revision) =~ "snapshot secret"
  end

  defp insert_submission(client_submission_id \\ Ecto.UUID.generate()) do
    %Submission{kind: :new_entry}
    |> Submission.changeset(%{
      client_submission_id: client_submission_id,
      payload: %{"definition" => "private contribution text"}
    })
    |> Repo.insert()
  end

  defp insert_moderator do
    %ModeratorAccount{
      email: "editor@example.com",
      password_hash: "password-verifier",
      display_name: "Editor"
    }
    |> Repo.insert!()
  end
end
