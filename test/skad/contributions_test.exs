defmodule Skad.ContributionsTest do
  use Skad.DataCase

  alias Ecto.Changeset
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.Scope
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Contributions
  alias Skad.Contributions.Revision
  alias Skad.Contributions.Submission
  alias Skad.Media
  alias Skad.Media.Item

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
               cultural_note: " Used in ceremonies. ",
               example: " Use water daily. "
             })

    assert Map.keys(receipt) |> Enum.sort() == [:public_id, :received_at, :status]
    assert receipt.status == :pending

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert submission.client_submission_id == client_submission_id

    assert submission.payload == %{
             "language_slug" => "english",
             "primary_form" => "Water",
             "definition" => "A clear liquid.",
             "part_of_speech" => "noun",
             "usage_note" => nil,
             "cultural_note" => "Used in ceremonies.",
             "example" => "Use water daily."
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

  test "claims completed anonymous media with the submission and preserves idempotency" do
    create_language()
    attrs = valid_attrs()
    audio = insert_media(:audio)
    image = insert_media(:image)
    media_public_ids = [audio.public_id, image.public_id]

    assert {:ok, first_receipt} =
             Contributions.submit_new_entry(attrs, media_public_ids)

    submission = Repo.get_by!(Submission, public_id: first_receipt.public_id)

    assert Enum.map(Media.list_submission_items(submission), & &1.id) == [audio.id, image.id]
    assert Repo.get!(Item, audio.id).submission_id == submission.id
    assert Repo.get!(Item, image.id).submission_id == submission.id

    scope = Scope.for_moderator(insert_moderator())
    assert {:ok, unchanged} = Contributions.update_submission_for_review(scope, submission, %{})
    assert unchanged.status == :pending
    assert unchanged.review_history == []
    assert unchanged.reviewed_payload == nil

    assert {:ok, second_receipt} =
             Contributions.submit_new_entry(attrs, Enum.reverse(media_public_ids))

    assert second_receipt == first_receipt

    assert {:error, :idempotency_conflict} =
             Contributions.submit_new_entry(attrs, [audio.public_id])

    assert Repo.aggregate(Submission, :count) == 1
  end

  test "rejects an invalid media batch without storing or claiming anything" do
    create_language()
    first_audio = insert_media(:audio)
    second_audio = insert_media(:audio)

    assert {:error, :invalid_media} =
             Contributions.submit_new_entry(valid_attrs(), [
               first_audio.public_id,
               second_audio.public_id
             ])

    assert Repo.aggregate(Submission, :count) == 0
    assert Repo.get!(Item, first_audio.id).submission_id == nil
    assert Repo.get!(Item, second_audio.id).submission_id == nil
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

    page = Contributions.page_submissions_for_review(scope)
    assert Enum.map(page.submissions, & &1.id) == [first.id]
    assert page.next_cursor == nil

    assert Contributions.get_submission_for_review(scope, first.public_id).payload ==
             first.payload

    inactive_scope = Scope.for_moderator(%{moderator | active: false})

    assert Contributions.page_submissions_for_review(inactive_scope) == %{
             submissions: [],
             next_cursor: nil
           }

    assert Contributions.get_submission_for_review(inactive_scope, first.public_id) == nil
    assert Contributions.get_submission_for_review(scope, "not-a-uuid") == nil
  end

  test "pages the review queue with a stable keyset cursor" do
    scope = Scope.for_moderator(insert_moderator())

    submissions =
      for offset <- 0..20 do
        insert_submission(DateTime.add(~U[2026-01-01 00:00:00Z], offset, :second))
      end

    first_page = Contributions.page_submissions_for_review(scope)

    assert Enum.map(first_page.submissions, & &1.id) ==
             Enum.map(Enum.take(submissions, 20), & &1.id)

    assert first_page.next_cursor == Enum.at(submissions, 19).public_id

    second_page = Contributions.page_submissions_for_review(scope, first_page.next_cursor)
    assert Enum.map(second_page.submissions, & &1.id) == [List.last(submissions).id]
    assert second_page.next_cursor == nil
  end

  test "authorizes moderator management and private previews of submission media" do
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    inactive_scope = Scope.for_moderator(%{moderator | active: false})
    submission = insert_submission()
    image = insert_media(:image)

    assert {:error, :unauthorized} =
             Contributions.attach_submission_media(inactive_scope, submission, image)

    assert {:ok, attached} = Contributions.attach_submission_media(scope, submission, image)
    assert Enum.map(Contributions.list_submission_media(scope, submission), & &1.id) == [image.id]
    assert Contributions.list_submission_media(inactive_scope, submission) == []

    assert {:ok, preview} = Contributions.preview_submission_media(scope, submission, attached)
    uri = URI.parse(preview.url)
    assert uri.path == "/skad-test/#{image.original_object_key}"
    assert uri.query =~ "X-Amz-Expires=300"

    assert {:error, :unauthorized} =
             Contributions.preview_submission_media(inactive_scope, submission, attached)

    assert {:ok, removed} = Contributions.remove_submission_media(scope, submission, attached)
    assert removed.visibility == :pending_deletion
    assert Contributions.list_submission_media(scope, submission) == []
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

  test "keeps the original proposal when a moderator edits the reviewed payload" do
    create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    assert {:ok, receipt} = Contributions.submit_new_entry(valid_attrs())
    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    changeset = Contributions.change_submission_for_review(scope, submission)
    assert Changeset.get_field(changeset, :primary_form) == "Water"

    assert {:error, invalid} =
             Contributions.update_submission_for_review(scope, submission, %{definition: ""})

    assert "can't be blank" in errors_on(invalid).definition

    assert {:ok, edited} =
             Contributions.update_submission_for_review(scope, submission, %{
               primary_form: "Drinking water",
               definition: "Water that is safe to drink.",
               usage_note: "For people and animals."
             })

    assert edited.status == :reviewing
    assert edited.payload["primary_form"] == "Water"
    assert edited.payload["definition"] == "A clear liquid."
    assert edited.reviewed_payload["primary_form"] == "Drinking water"
    assert edited.reviewed_payload["definition"] == "Water that is safe to drink."
    assert edited.reviewed_by_account.id == moderator.id

    assert List.last(edited.review_history) == %{
             "action" => "edited",
             "moderator_account_id" => moderator.id,
             "reviewed_at" => DateTime.to_iso8601(edited.reviewed_at),
             "changed_fields" => ["definition", "primary_form", "usage_note"]
           }

    assert {:ok, %{entry: entry, submission: approved}} =
             Contributions.approve_submission(scope, edited)

    assert hd(entry.forms).text == "Drinking water"
    assert hd(entry.definitions).text == "Water that is safe to drink."

    assert {:error, :invalid_transition} =
             Contributions.update_submission_for_review(scope, approved, %{definition: "Too late"})
  end

  test "lets moderators create and edit concepts with revision history" do
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    assert {:ok, concept} =
             Contributions.create_concept(scope, %{
               editorial_label: "  WATER  ",
               editorial_note: "  Shared by water entries.  "
             })

    assert concept.editorial_label == "WATER"
    assert concept.editorial_note == "Shared by water entries."

    assert {:ok, updated} =
             Contributions.update_concept(scope, concept, %{
               editorial_label: "WATER / पानी",
               editorial_note: " "
             })

    assert updated.editorial_label == "WATER / पानी"
    assert updated.editorial_note == nil

    assert [created, edited] = Repo.all(from revision in Revision, order_by: revision.id)
    assert created.target_type == "concept"
    assert created.target_public_id == concept.public_id
    assert created.action == :create
    assert created.before_state == nil
    assert created.after_state["editorial_label"] == "WATER"
    assert edited.action == :update
    assert edited.before_state["editorial_note"] == "Shared by water entries."
    assert edited.after_state["editorial_label"] == "WATER / पानी"

    inactive_scope = Scope.for_moderator(%{moderator | active: false})

    assert {:error, :unauthorized} =
             Contributions.create_concept(inactive_scope, %{editorial_label: "RAIN"})

    assert {:error, :unauthorized} =
             Contributions.update_concept(inactive_scope, updated, %{editorial_label: "RAIN"})

    updated
    |> Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, :concept_not_found} =
             Contributions.update_concept(scope, updated, %{editorial_label: "RAIN"})

    assert Repo.aggregate(Concept, :count) == 1
    assert Repo.aggregate(Revision, :count) == 2
  end

  test "approves a submitted expression into an existing concept" do
    english = create_language()

    {:ok, water} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: "english", text: "A clear liquid."}]},
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    {:ok, hindi} =
      Archive.create_language(%{
        slug: "hindi",
        code: "hi",
        name: "Hindi",
        direction: :ltr
      })

    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    audio = insert_media(:audio)
    image = insert_media(:image)

    {:ok, receipt} =
      Contributions.submit_new_entry(
        %{
          client_submission_id: Ecto.UUID.generate(),
          language_slug: hindi.slug,
          primary_form: "पानी",
          definition: "पीने के लिए उपयोग किया जाने वाला तरल।"
        },
        [audio.public_id, image.public_id]
      )

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    audio = make_ready(audio)
    image = make_ready(image)

    assert {:ok, %{entry: hindi_entry}} =
             Contributions.approve_submission(
               scope,
               submission,
               nil,
               %{},
               %{public_id: water.concept.public_id}
             )

    assert hindi_entry.concept_id == water.concept_id
    assert Repo.aggregate(Concept, :count) == 1

    assert Repo.get!(Item, audio.id).entry_id == hindi_entry.id
    assert Repo.get!(Item, image.id).concept_id == water.concept_id
    assert Enum.map(Media.list_public_concept_images(water.concept), & &1.id) == [image.id]

    revision = Repo.get_by!(Revision, target_public_id: hindi_entry.public_id)
    assert revision.after_state["concept_public_id"] == water.concept.public_id
  end

  test "rejects an unavailable concept without partially approving the submission" do
    create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    {:ok, receipt} = Contributions.submit_new_entry(valid_attrs())
    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert {:error, :concept_not_found} =
             Contributions.approve_submission(
               scope,
               submission,
               nil,
               %{},
               %{public_id: "not-a-uuid"}
             )

    assert Repo.get!(Submission, submission.id).status == :pending
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
  end

  test "approves a new entry with its revision and search index in one transaction" do
    language = create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    assert {:ok, receipt} =
             Contributions.submit_new_entry(%{
               client_submission_id: Ecto.UUID.generate(),
               language_slug: language.slug,
               primary_form: "Water",
               definition: "A clear liquid.",
               part_of_speech: "noun",
               usage_note: "Used every day.",
               cultural_note: "Used in ceremonies."
             })

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert {:ok, %{entry: entry, submission: approved}} =
             Contributions.approve_submission(scope, submission, "Verified")

    assert approved.status == :approved
    assert approved.review_note == "Verified"
    assert approved.reviewed_by_account.id == moderator.id
    assert List.last(approved.review_history)["status"] == "approved"

    assert entry.language.id == language.id
    assert entry.concept.editorial_label == "Water"
    assert entry.part_of_speech == "noun"
    assert entry.usage_note == "Used every day."
    assert entry.cultural_note == "Used in ceremonies."

    assert Enum.map(entry.definitions, &{&1.language, &1.text}) == [
             {"english", "A clear liquid."}
           ]

    assert Enum.map(entry.forms, &{&1.text, &1.kind, &1.is_primary}) == [
             {"Water", :spelling, true}
           ]

    revision = Repo.one!(Revision)
    assert revision.target_type == "entry"
    assert revision.target_public_id == entry.public_id
    assert revision.action == :create
    assert revision.actor_type == :moderator
    assert revision.moderator_account_id == moderator.id
    assert revision.submission_id == approved.id
    assert revision.reason == "Verified"
    assert revision.after_state["public_id"] == entry.public_id
    refute Map.has_key?(revision.after_state, "id")

    assert [%{entry: found}] = Archive.search("clear", language)
    assert found.id == entry.id
    assert Contributions.get_receipt(receipt.public_id).status == :approved

    assert {:error, :invalid_transition} =
             Contributions.approve_submission(scope, submission)

    assert Repo.aggregate(Entry, :count) == 1
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "publishes ready submission audio to the entry and images to the concept" do
    create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    audio = insert_media(:audio)
    image = insert_media(:image)
    attrs = valid_attrs()

    assert {:ok, receipt} =
             Contributions.submit_new_entry(attrs, [audio.public_id, image.public_id])

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    audio = make_ready(audio)
    image = make_ready(image)

    assert {:ok, %{entry: entry}} = Contributions.approve_submission(scope, submission)

    published_audio = Repo.get!(Item, audio.id)
    assert published_audio.visibility == :public
    assert published_audio.entry_id == entry.id
    assert published_audio.concept_id == nil
    assert published_audio.submission_id == nil

    published_image = Repo.get!(Item, image.id)
    assert published_image.visibility == :public
    assert published_image.entry_id == nil
    assert published_image.concept_id == entry.concept_id
    assert published_image.submission_id == nil
    assert Media.get_public_entry_audio(entry).id == audio.id
    assert Enum.map(Media.list_public_concept_images(entry.concept), & &1.id) == [image.id]

    assert {:ok, repeated_receipt} =
             Contributions.submit_new_entry(attrs, [
               audio.public_id,
               image.public_id
             ])

    assert repeated_receipt == Contributions.get_receipt(receipt.public_id)
  end

  test "rolls back approval when attached media is not ready for publication" do
    create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)
    audio = insert_media(:audio)

    assert {:ok, receipt} =
             Contributions.submit_new_entry(valid_attrs(), [audio.public_id])

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert {:error, %Changeset{valid?: false} = changeset} =
             Contributions.approve_submission(scope, submission)

    assert "must be ready when media is public" in errors_on(changeset).processing_state
    assert Repo.get!(Submission, submission.id).status == :pending
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0

    stored_audio = Repo.get!(Item, audio.id)
    assert stored_audio.submission_id == submission.id
    assert stored_audio.entry_id == nil
    assert stored_audio.visibility == :quarantine
  end

  test "publishes a submitted example with confirmed focus and reference links" do
    language = create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    {:ok, water} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    assert {:ok, receipt} =
             Contributions.submit_new_entry(%{
               client_submission_id: Ecto.UUID.generate(),
               language_slug: language.slug,
               primary_form: "Drink",
               definition: "To swallow a liquid.",
               example: "Water is clear."
             })

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert {:error, :example_focus_missing} =
             Contributions.approve_submission(scope, submission)

    assert Repo.get!(Submission, submission.id).status == :pending

    assert {:ok, submission} =
             Contributions.update_submission_for_review(scope, submission, %{
               example: "Drink water."
             })

    assert {:ok, [focus, reference]} = Contributions.suggest_example_links(submission)
    assert focus.role == :focus
    assert reference.role == :reference

    assert {:ok, %{entry: entry}} =
             Contributions.approve_submission(scope, submission, nil, %{
               "1" => water.public_id
             })

    assert [focus_link] = entry.example_links
    assert focus_link.role == :focus
    assert focus_link.surface_text == "Drink"
    assert focus_link.example.text == "Drink water."

    assert Enum.map(focus_link.example.links, &{&1.role, &1.entry.public_id}) == [
             {:focus, entry.public_id},
             {:reference, water.public_id}
           ]

    revision = Repo.get_by!(Revision, target_public_id: entry.public_id)
    assert revision.after_state["example"]["text"] == "Drink water."

    assert Enum.map(revision.after_state["example"]["links"], & &1["role"]) == [
             "focus",
             "reference"
           ]
  end

  test "rolls back the approval claim when canonical validation fails" do
    language = create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    assert {:ok, receipt} = Contributions.submit_new_entry(valid_attrs())
    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert {:ok, reviewing} = Contributions.moderate_submission(scope, submission, :reviewing)

    invalid_payload = Map.put(reviewing.payload, "definition", "")
    reviewing = reviewing |> Ecto.Changeset.change(payload: invalid_payload) |> Repo.update!()

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Contributions.approve_submission(scope, reviewing)

    assert Repo.get!(Submission, reviewing.id).status == :reviewing
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
    assert Archive.search("water", language) == []
  end

  test "submits and atomically approves a correction to an existing entry" do
    language = create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          part_of_speech: "noun",
          definitions: [%{language: language.slug, text: "An unclear liquid."}]
        },
        forms: [%{text: "Watre", kind: :spelling, is_primary: true}]
      })

    attrs = %{
      client_submission_id: Ecto.UUID.generate(),
      primary_form: "Water",
      definition: "A clear liquid.",
      part_of_speech: "noun",
      usage_note: "Used for drinking."
    }

    assert {:ok, receipt} = Contributions.submit_entry_change(:correction, entry, attrs)
    assert {:ok, ^receipt} = Contributions.submit_entry_change(:correction, entry, attrs)

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert submission.kind == :correction
    assert submission.target_public_id == entry.public_id
    assert Archive.get_public_entry(entry.public_id).forms |> hd() |> Map.fetch!(:text) == "Watre"

    assert {:ok, %{entry: corrected, submission: approved}} =
             Contributions.approve_submission(scope, submission, "Spelling verified")

    assert approved.status == :approved
    assert hd(corrected.forms).text == "Water"
    assert hd(corrected.definitions).text == "A clear liquid."
    assert corrected.usage_note == "Used for drinking."
    assert [%{entry: found}] = Archive.exact_lookup("water", language)
    assert found.id == entry.id
    assert Archive.exact_lookup("watre", language) == []

    revision = Repo.get_by!(Revision, submission_id: submission.id)
    assert revision.action == :update
    assert hd(revision.before_state["forms"])["text"] == "Watre"
    assert hd(revision.after_state["forms"])["text"] == "Water"
  end

  test "submits and approves an alternate form and example addition" do
    language = create_language()
    moderator = insert_moderator()
    scope = Scope.for_moderator(moderator)

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    assert {:error, invalid} =
             Contributions.submit_entry_change(:addition, entry, %{
               client_submission_id: Ecto.UUID.generate()
             })

    assert "or an example is required" in errors_on(invalid).alternate_form

    assert {:ok, receipt} =
             Contributions.submit_entry_change(:addition, entry, %{
               client_submission_id: Ecto.UUID.generate(),
               alternate_form: "H₂O",
               form_kind: :alias,
               example: "Water is clear."
             })

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert {:ok, %{entry: updated}} = Contributions.approve_submission(scope, submission)

    assert Enum.map(updated.forms, & &1.text) == ["Water", "H₂O"]
    assert [focus_link] = updated.example_links
    assert focus_link.example.text == "Water is clear."
    assert [%{entry: found}] = Archive.exact_lookup("h₂o", language)
    assert found.id == entry.id

    revision = Repo.get_by!(Revision, submission_id: submission.id)
    assert length(revision.before_state["forms"]) == 1
    assert length(revision.after_state["forms"]) == 2
    assert [%{"text" => "Water is clear."}] = revision.after_state["examples"]
  end

  test "submits and approves a standalone example and rejects a published duplicate" do
    language = create_language()
    scope = Scope.for_moderator(insert_moderator())

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    attrs = %{
      client_submission_id: Ecto.UUID.generate(),
      example: "Drink water every day."
    }

    assert {:ok, receipt} = Contributions.submit_entry_change(:example, entry, attrs)
    submission = Repo.get_by!(Submission, public_id: receipt.public_id)

    assert submission.kind == :example
    assert {:ok, %{entry: updated}} = Contributions.approve_submission(scope, submission)
    assert Enum.any?(updated.example_links, &(&1.example.text == "Drink water every day."))

    assert {:error, :already_exists} =
             Contributions.submit_entry_change(:example, updated, %{
               client_submission_id: Ecto.UUID.generate(),
               example: "  Drink water every day.  "
             })
  end

  test "publishes audio-only submissions as atomic replacements" do
    language = create_language()
    scope = Scope.for_moderator(insert_moderator())

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    {:ok, old_audio} = Media.create_item(entry, media_attrs(:audio, "a"))
    old_audio = publish_media(old_audio)
    new_audio = :audio |> insert_media("c") |> make_ready()

    assert {:ok, receipt} =
             Contributions.submit_entry_change(
               :audio,
               entry,
               %{client_submission_id: Ecto.UUID.generate()},
               [new_audio.public_id]
             )

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert Repo.get!(Item, new_audio.id).submission_id == submission.id
    assert {:ok, %{entry: updated}} = Contributions.approve_submission(scope, submission)

    assert Media.get_public_entry_audio(updated).id == new_audio.id
    assert Repo.get!(Item, old_audio.id).visibility == :pending_deletion
    assert Repo.get!(Item, old_audio.id).archived_at

    duplicate = :audio |> insert_media("c") |> make_ready()

    assert {:error, :already_exists} =
             Contributions.submit_entry_change(
               :audio,
               updated,
               %{client_submission_id: Ecto.UUID.generate()},
               [duplicate.public_id]
             )
  end

  test "publishes image-only submissions and rejects an existing image" do
    language = create_language()
    scope = Scope.for_moderator(insert_moderator())

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    image = :image |> insert_media("d") |> make_ready()

    assert {:ok, receipt} =
             Contributions.submit_entry_change(
               :image,
               entry,
               %{client_submission_id: Ecto.UUID.generate()},
               [image.public_id]
             )

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert {:ok, %{entry: updated}} = Contributions.approve_submission(scope, submission)
    assert Enum.map(Media.list_public_concept_images(updated.concept), & &1.id) == [image.id]

    duplicate = :image |> insert_media("d") |> make_ready()

    assert {:error, :already_exists} =
             Contributions.submit_entry_change(
               :image,
               updated,
               %{client_submission_id: Ecto.UUID.generate()},
               [duplicate.public_id]
             )
  end

  test "rechecks media duplicates atomically during approval" do
    language = create_language()
    scope = Scope.for_moderator(insert_moderator())

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    submitted_image = :image |> insert_media("e") |> make_ready()

    assert {:ok, receipt} =
             Contributions.submit_entry_change(
               :image,
               entry,
               %{client_submission_id: Ecto.UUID.generate()},
               [submitted_image.public_id]
             )

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    {:ok, published_image} = Media.create_item(entry.concept, media_attrs(:image, "e"))
    publish_media(published_image)

    assert {:error, :already_exists} = Contributions.approve_submission(scope, submission)
    assert Repo.get!(Submission, submission.id).status == :pending
    assert Repo.get!(Item, submitted_image.id).submission_id == submission.id
  end

  test "rejects corrections and additions that are already canonical" do
    language = create_language()

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          part_of_speech: "noun",
          definitions: [%{language: language.slug, text: "A clear liquid."}]
        },
        forms: [
          %{text: "Water", kind: :spelling, is_primary: true},
          %{text: "H₂O", kind: :alias, is_primary: false}
        ]
      })

    assert {:error, :already_exists} =
             Contributions.submit_entry_change(:correction, entry, %{
               client_submission_id: Ecto.UUID.generate(),
               primary_form: "Water",
               definition: "A clear liquid.",
               part_of_speech: "noun"
             })

    assert {:error, :already_exists} =
             Contributions.submit_entry_change(:addition, entry, %{
               client_submission_id: Ecto.UUID.generate(),
               alternate_form: " h₂o ",
               form_kind: :alias
             })
  end

  defp valid_attrs(client_submission_id \\ Ecto.UUID.generate()) do
    %{
      client_submission_id: client_submission_id,
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
      payload: %{"definition" => "private text"}
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

  defp insert_media(kind, sha_character \\ nil)

  defp insert_media(:audio, sha_character) do
    {:ok, item} =
      Media.create_item(%{
        kind: :audio,
        original_object_key: "private/audio/#{Ecto.UUID.generate()}.webm",
        mime_type: "audio/webm",
        byte_size: 8_192,
        sha256: String.duplicate(sha_character || "a", 64)
      })

    item
  end

  defp insert_media(:image, sha_character) do
    {:ok, item} =
      Media.create_item(%{
        kind: :image,
        original_object_key: "private/images/#{Ecto.UUID.generate()}.jpg",
        mime_type: "image/jpeg",
        byte_size: 16_384,
        sha256: String.duplicate(sha_character || "b", 64)
      })

    item
  end

  defp make_ready(item) do
    {:ok, item} =
      Media.update_item(item, %{
        processing_state: :ready,
        public_object_key: "public/#{item.kind}/#{item.public_id}"
      })

    item
  end

  defp media_attrs(:audio, sha_character) do
    %{
      kind: :audio,
      original_object_key: "private/audio/#{Ecto.UUID.generate()}.webm",
      mime_type: "audio/webm",
      byte_size: 8_192,
      sha256: String.duplicate(sha_character, 64)
    }
  end

  defp media_attrs(:image, sha_character) do
    %{
      kind: :image,
      original_object_key: "private/images/#{Ecto.UUID.generate()}.jpg",
      mime_type: "image/jpeg",
      byte_size: 16_384,
      sha256: String.duplicate(sha_character, 64)
    }
  end

  defp publish_media(item) do
    {:ok, item} =
      Media.update_item(item, %{
        processing_state: :ready,
        visibility: :public,
        public_object_key: "public/#{item.kind}/#{item.public_id}"
      })

    item
  end
end
