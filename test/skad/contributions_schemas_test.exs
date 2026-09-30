defmodule Skad.ContributionsSchemasTest do
  use Skad.DataCase

  alias Skad.Contributions.Submission

  test "persists a pending submission with server-generated receipt fields" do
    {:ok, submission} = insert_submission()

    assert {:ok, _public_id} = Ecto.UUID.cast(submission.public_id)
    assert submission.kind == :new_entry
    assert submission.status == :pending
    assert submission.payload == %{"definition" => "private contribution text", "version" => 1}
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
               payload: %{"version" => 1}
             })
             |> Repo.insert()

    assert "must be present with target type" in errors_on(changeset).target_public_id
  end

  defp insert_submission(client_submission_id \\ Ecto.UUID.generate()) do
    %Submission{kind: :new_entry}
    |> Submission.changeset(%{
      client_submission_id: client_submission_id,
      payload: %{"definition" => "private contribution text", "version" => 1}
    })
    |> Repo.insert()
  end
end
