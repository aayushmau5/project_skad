defmodule Skad.ContributionsStorageTest do
  use Skad.DataCase

  test "enforces receipt and client idempotency identifiers" do
    public_id = Ecto.UUID.generate()
    client_submission_id = Ecto.UUID.generate()
    insert_submission(public_id: public_id, client_submission_id: client_submission_id)

    assert_raise Exqlite.Error, fn ->
      insert_submission(public_id: public_id)
    end

    assert_raise Exqlite.Error, fn ->
      insert_submission(client_submission_id: client_submission_id)
    end
  end

  test "rejects invalid kinds, statuses, and incomplete targets" do
    assert_raise Exqlite.Error, fn ->
      insert_submission(kind: "unknown")
    end

    assert_raise Exqlite.Error, fn ->
      insert_submission(status: "unknown")
    end

    assert_raise Exqlite.Error, fn ->
      insert_submission(target_type: "entry")
    end

    assert_raise Exqlite.Error, fn ->
      insert_submission(payload: "not json")
    end
  end

  test "stores constrained review metadata on submissions" do
    submission_id = insert_submission([])
    moderator_id = insert_account()
    reviewed_at = DateTime.utc_now(:second)

    assert [["[]"]] =
             Repo.query!("SELECT review_history FROM submissions WHERE id = ?", [submission_id]).rows

    Repo.query!(
      """
      UPDATE submissions
      SET review_history = ?, reviewed_by_account_id = ?, reviewed_at = ?, review_note = ?
      WHERE id = ?
      """,
      [
        Jason.encode!([%{"decision" => "reviewing"}]),
        moderator_id,
        reviewed_at,
        "Review started",
        submission_id
      ]
    )

    assert_raise Exqlite.Error, fn ->
      Repo.query!("UPDATE submissions SET review_history = ? WHERE id = ?", ["{}", submission_id])
    end

    assert_raise Exqlite.Error, fn ->
      Repo.query!("UPDATE submissions SET reviewed_by_account_id = ? WHERE id = ?", [
        -1,
        submission_id
      ])
    end
  end

  test "stores constrained canonical revisions" do
    submission_id = insert_submission([])
    moderator_id = insert_account()

    insert_revision(
      submission_id: submission_id,
      moderator_account_id: moderator_id,
      after_state: Jason.encode!(%{"public_id" => Ecto.UUID.generate()})
    )

    assert_raise Exqlite.Error, fn ->
      insert_revision(action: "unknown")
    end

    assert_raise Exqlite.Error, fn ->
      insert_revision(actor_type: "unknown")
    end

    assert_raise Exqlite.Error, fn ->
      insert_revision(before_state: "not json")
    end
  end

  defp insert_submission(overrides) do
    values =
      Map.merge(
        %{
          public_id: Ecto.UUID.generate(),
          client_submission_id: Ecto.UUID.generate(),
          kind: "new_entry",
          target_type: nil,
          target_public_id: nil,
          payload: Jason.encode!(%{"version" => 1}),
          status: "pending",
          received_at: DateTime.utc_now(:second)
        },
        Map.new(overrides)
      )

    result =
      Repo.query!(
        """
        INSERT INTO submissions(
          public_id,
          client_submission_id,
          kind,
          target_type,
          target_public_id,
          payload,
          status,
          received_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING id
        """,
        [
          values.public_id,
          values.client_submission_id,
          values.kind,
          values.target_type,
          values.target_public_id,
          values.payload,
          values.status,
          values.received_at
        ]
      )

    [[id]] = result.rows
    id
  end

  defp insert_account do
    result =
      Repo.query!(
        """
        INSERT INTO moderator_accounts(email, password_hash, display_name)
        VALUES (?, ?, ?)
        RETURNING id
        """,
        [
          "editor-#{System.unique_integer([:positive])}@example.com",
          "password-verifier",
          "Editor"
        ]
      )

    [[id]] = result.rows
    id
  end

  defp insert_revision(overrides) do
    values =
      Map.merge(
        %{
          target_type: "entry",
          target_public_id: Ecto.UUID.generate(),
          action: "create",
          before_state: nil,
          after_state: nil,
          actor_type: "system",
          moderator_account_id: nil,
          submission_id: nil,
          source: nil,
          reason: nil,
          inserted_at: DateTime.utc_now(:second)
        },
        Map.new(overrides)
      )

    Repo.query!(
      """
      INSERT INTO revisions(
        target_type,
        target_public_id,
        action,
        before_state,
        after_state,
        actor_type,
        moderator_account_id,
        submission_id,
        source,
        reason,
        inserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        values.target_type,
        values.target_public_id,
        values.action,
        values.before_state,
        values.after_state,
        values.actor_type,
        values.moderator_account_id,
        values.submission_id,
        values.source,
        values.reason,
        values.inserted_at
      ]
    )
  end
end
