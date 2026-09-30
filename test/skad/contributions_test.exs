defmodule Skad.ContributionsTest do
  use Skad.DataCase

  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.Scope
  alias Skad.Archive
  alias Skad.Contributions
  alias Skad.Contributions.Submission

  test "stores a normalized new-entry proposal and returns a safe receipt" do
    create_language()
    client_submission_id = Ecto.UUID.generate()

    assert {:ok, receipt} =
             Contributions.submit_new_entry(%{
               client_submission_id: client_submission_id,
               language_slug: "english",
               primary_form: "  Water  ",
               definition: "  A clear liquid.  ",
               part_of_speech: " noun ",
               usage_note: " ",
               cultural_note: " Used in ceremonies. "
             })

    assert Map.keys(receipt) |> Enum.sort() == [:public_id, :received_at, :status]
    assert receipt.status == :pending

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert submission.client_submission_id == client_submission_id

    assert submission.payload == %{
             "version" => 1,
             "language_slug" => "english",
             "primary_form" => "Water",
             "definition" => "A clear liquid.",
             "part_of_speech" => "noun",
             "usage_note" => nil,
             "cultural_note" => "Used in ceremonies."
           }
  end

  test "returns the original receipt when an identical request is retried" do
    create_language()
    attrs = valid_attrs()

    assert {:ok, first_receipt} = Contributions.submit_new_entry(attrs)
    assert {:ok, second_receipt} = Contributions.submit_new_entry(attrs)

    assert second_receipt == first_receipt
    assert Repo.aggregate(Submission, :count) == 1
  end

  test "rejects reuse of an idempotency key for different content" do
    create_language()
    attrs = valid_attrs()

    assert {:ok, _receipt} = Contributions.submit_new_entry(attrs)

    assert {:error, :idempotency_conflict} =
             attrs
             |> Map.put(:definition, "Different content")
             |> Contributions.submit_new_entry()

    assert Repo.aggregate(Submission, :count) == 1
  end

  test "validates submission fields and active language" do
    assert {:error, invalid} =
             Contributions.submit_new_entry(%{
               client_submission_id: "not-a-uuid",
               language_slug: "",
               primary_form: "",
               definition: ""
             })

    errors = errors_on(invalid)
    assert "is invalid" in errors.client_submission_id
    assert "can't be blank" in errors.language_slug
    assert "can't be blank" in errors.primary_form
    assert "can't be blank" in errors.definition

    assert {:error, unknown_language} = Contributions.submit_new_entry(valid_attrs())
    assert "is not active" in errors_on(unknown_language).language_slug
  end

  test "looks up receipts without exposing the private payload" do
    create_language()
    assert {:ok, receipt} = Contributions.submit_new_entry(valid_attrs())

    assert Contributions.get_receipt(receipt.public_id) == receipt
    assert Contributions.get_receipt("not-a-uuid") == nil
    assert Contributions.get_receipt(Ecto.UUID.generate()) == nil
  end

  test "lists open submissions and exposes private details only to an active moderator" do
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    first = insert_submission(~U[2026-01-01 00:00:00Z])
    second = insert_submission(~U[2026-01-02 00:00:00Z])

    second
    |> Ecto.Changeset.change(status: :rejected)
    |> Repo.update!()

    assert Enum.map(Contributions.list_submissions_for_review(scope), & &1.id) == [first.id]

    assert Contributions.get_submission_for_review(scope, first.public_id).payload ==
             first.payload

    inactive_scope = Scope.for_moderator(%{moderator | active: false})
    assert Contributions.list_submissions_for_review(inactive_scope) == []
    assert Contributions.get_submission_for_review(inactive_scope, first.public_id) == nil
    assert Contributions.get_submission_for_review(scope, "not-a-uuid") == nil
  end

  test "records valid review transitions and their moderator history" do
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    submission = insert_submission()

    assert {:ok, reviewing} =
             Contributions.moderate_submission(scope, submission, :reviewing)

    assert reviewing.status == :reviewing
    assert reviewing.reviewed_by_account.id == moderator.id

    assert [%{"status" => "reviewing", "note" => nil}] =
             Enum.map(reviewing.review_history, &Map.take(&1, ["status", "note"]))

    assert {:error, :review_note_required} =
             Contributions.moderate_submission(scope, reviewing, :clarification_needed, " ")

    assert {:ok, clarification} =
             Contributions.moderate_submission(
               scope,
               reviewing,
               :clarification_needed,
               "  Which variety?  "
             )

    assert clarification.review_note == "Which variety?"

    assert {:ok, resumed} =
             Contributions.moderate_submission(scope, clarification, :reviewing)

    assert {:ok, rejected} =
             Contributions.moderate_submission(scope, resumed, :rejected, "Cannot verify")

    assert Enum.map(rejected.review_history, & &1["status"]) == [
             "reviewing",
             "clarification_needed",
             "reviewing",
             "rejected"
           ]

    assert {:error, :invalid_transition} =
             Contributions.moderate_submission(scope, rejected, :reviewing)

    inactive_scope = Scope.for_moderator(%{moderator | active: false})

    assert {:error, :unauthorized} =
             Contributions.moderate_submission(inactive_scope, submission, :reviewing)
  end

  defp valid_attrs do
    %{
      client_submission_id: Ecto.UUID.generate(),
      language_slug: "english",
      primary_form: "Water",
      definition: "A clear liquid."
    }
  end

  defp create_language do
    {:ok, language} =
      Archive.create_language(%{
        slug: "english",
        code: "en",
        name: "English",
        direction: :ltr
      })

    language
  end

  defp insert_submission(received_at \\ DateTime.utc_now(:second)) do
    %Submission{kind: :new_entry, received_at: received_at}
    |> Submission.changeset(%{
      client_submission_id: Ecto.UUID.generate(),
      payload: %{"version" => 1, "definition" => "private text"}
    })
    |> Repo.insert!()
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
