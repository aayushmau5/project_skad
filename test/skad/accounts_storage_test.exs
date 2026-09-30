defmodule Skad.AccountsStorageTest do
  use Skad.DataCase

  test "stores moderator accounts with unique emails" do
    insert_account("editor@example.com")

    assert_raise Exqlite.Error, fn ->
      insert_account("editor@example.com")
    end
  end

  test "removes a moderator's sessions when the account is deleted" do
    account_id = insert_account("editor@example.com")

    Repo.query!(
      """
      INSERT INTO moderator_session_tokens(moderator_account_id, token, inserted_at)
      VALUES (?, ?, ?)
      """,
      [account_id, :crypto.strong_rand_bytes(32), DateTime.utc_now(:second)]
    )

    Repo.query!("DELETE FROM moderator_accounts WHERE id = ?", [account_id])

    assert [[0]] = Repo.query!("SELECT count(*) FROM moderator_session_tokens").rows
  end

  defp insert_account(email) do
    result =
      Repo.query!(
        """
        INSERT INTO moderator_accounts(email, password_hash, display_name)
        VALUES (?, ?, ?)
        RETURNING id
        """,
        [email, "stored-password-verifier", "Archive Editor"]
      )

    [[id]] = result.rows
    id
  end
end
