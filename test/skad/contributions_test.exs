defmodule Skad.ContributionsTest do
  use Skad.DataCase

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
end
