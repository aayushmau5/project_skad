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
  end
end
