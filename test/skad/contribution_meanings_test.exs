defmodule Skad.ContributionMeaningsTest do
  use Skad.DataCase
  import Skad.ModerationFixtures

  alias Skad.Archive
  alias Skad.Contributions
  alias Skad.Contributions.Submission

  setup do
    records()
  end

  test "corrections preserve the other translated descriptions", %{water: water, scope: scope} do
    {:ok, water} =
      Skad.Moderation.update_entry(scope, water, %{
        definitions: [
          %{language: "english", text: "A clear liquid."},
          %{language: "hindi", text: "पानी"},
          %{language: "english", text: "Also used for washing."}
        ]
      })

    assert {:ok, receipt} =
             Contributions.submit_entry_change(:correction, water, %{
               client_submission_id: Ecto.UUID.generate(),
               definition: "Safe drinking water.",
               definition_language: "english"
             })

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert {:ok, %{entry: updated}} = Contributions.approve_submission(scope, submission)

    assert Enum.map(updated.definitions, &{&1.language, &1.text}) == [
             {"english", "Safe drinking water."},
             {"hindi", "पानी"},
             {"english", "Also used for washing."}
           ]
  end

  test "validates another meaning's source and explanation language and rechecks at approval", %{
    water: water,
    scope: scope
  } do
    attrs = %{
      client_submission_id: Ecto.UUID.generate(),
      language_slug: "english",
      primary_form: "Water",
      source_entry_public_id: water.public_id,
      definition_language: "hindi",
      definition: "जलाशय"
    }

    assert {:error, invalid} =
             Contributions.submit_new_entry(Map.put(attrs, :definition_language, "unknown"))

    assert "is invalid" in errors_on(invalid).definition_language

    assert {:error, changed_word} =
             Contributions.submit_new_entry(Map.put(attrs, :primary_form, "Another word"))

    assert "must match the existing word" in errors_on(changed_word).primary_form

    assert {:error, missing} =
             Contributions.submit_new_entry(
               Map.put(attrs, :source_entry_public_id, Ecto.UUID.generate())
             )

    assert "is unavailable" in errors_on(missing).source_entry_public_id

    assert {:error, missing_language} =
             Contributions.submit_new_entry(Map.delete(attrs, :definition_language))

    assert "can't be blank" in errors_on(missing_language).definition_language

    assert {:ok, receipt} = Contributions.submit_new_entry(attrs)
    assert {:ok, repeated} = Contributions.submit_new_entry(attrs)
    assert receipt.public_id == repeated.public_id
    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    water |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()
    assert {:error, unavailable} = Contributions.approve_submission(scope, submission)
    assert "is unavailable" in errors_on(unavailable).source_entry_public_id
    assert Repo.get!(Submission, submission.id).status == :pending
  end

  test "legacy proposals without explanation language can still be approved", %{
    scope: scope,
    water: water
  } do
    assert {:ok, receipt} =
             Contributions.submit_new_entry(%{
               client_submission_id: Ecto.UUID.generate(),
               language_slug: water.language.slug,
               primary_form: "Old proposal",
               definition: "A legacy meaning."
             })

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    refute Map.has_key?(submission.payload, "definition_language")
    assert {:ok, %{entry: entry}} = Contributions.approve_submission(scope, submission)
    assert hd(entry.definitions).language == "english"
    assert Archive.get_public_word(entry.public_id)
  end

  test "retrying a legacy correction returns the original receipt", %{water: water} do
    attrs = %{
      client_submission_id: Ecto.UUID.generate(),
      definition: "Safe drinking water."
    }

    assert {:ok, receipt} = Contributions.submit_entry_change(:correction, water, attrs)
    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    submission
    |> Ecto.Changeset.change(payload: Map.delete(submission.payload, "definition_language"))
    |> Repo.update!()

    assert {:ok, ^receipt} = Contributions.submit_entry_change(:correction, water, attrs)

    assert {:error, :idempotency_conflict} =
             Contributions.submit_entry_change(
               :correction,
               water,
               Map.put(attrs, :definition_language, "hindi")
             )
  end

  test "reviewing a legacy correction preserves its implicit explanation language", %{
    scope: scope
  } do
    {:ok, language} =
      Archive.create_language(%{slug: "hamskad", name: "Hamskad", direction: :ltr})

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "Legacy meaning"},
        entry: %{definitions: [%{language: "english", text: "Existing English explanation"}]},
        forms: [%{text: "Legacy word", kind: :spelling, is_primary: true}]
      })

    {:ok, receipt} =
      Contributions.submit_entry_change(:correction, entry, %{
        client_submission_id: Ecto.UUID.generate(),
        definition: "Legacy proposed explanation"
      })

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    submission =
      submission
      |> Ecto.Changeset.change(payload: Map.delete(submission.payload, "definition_language"))
      |> Repo.update!()

    changeset = Contributions.change_submission_for_review(scope, submission)
    assert Ecto.Changeset.get_field(changeset, :definition_language) == language.slug
  end
end
