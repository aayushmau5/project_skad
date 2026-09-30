defmodule Skad.AccountsTest do
  use Skad.DataCase

  alias Skad.Accounts
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.ModeratorSessionToken

  test "finds a moderator by normalized email" do
    account = insert_account()

    assert Accounts.get_moderator_account_by_email(" EDITOR@EXAMPLE.COM ").id == account.id
    assert Accounts.get_moderator_account_by_email("missing@example.com") == nil
    assert Accounts.get_moderator_account_by_email(nil) == nil
  end

  test "creates, resolves, and deletes a moderator session" do
    account = insert_account()

    assert {:ok, token} = Accounts.create_moderator_session(account)
    assert Accounts.get_moderator_account_by_session_token(token).id == account.id

    assert :ok = Accounts.delete_moderator_session(token)
    assert Accounts.get_moderator_account_by_session_token(token) == nil
  end

  test "does not resolve expired sessions" do
    account = insert_account()
    token = :crypto.strong_rand_bytes(32)

    %ModeratorSessionToken{
      moderator_account_id: account.id,
      token: token,
      inserted_at: DateTime.add(DateTime.utc_now(:second), -15, :day)
    }
    |> ModeratorSessionToken.changeset()
    |> Repo.insert!()

    assert Accounts.get_moderator_account_by_session_token(token) == nil
  end

  test "deactivating a moderator revokes sessions and prevents new ones" do
    account = insert_account()
    assert {:ok, token} = Accounts.create_moderator_session(account)

    assert {:ok, inactive_account} = Accounts.set_moderator_active(account, false)
    refute inactive_account.active
    assert Accounts.get_moderator_account_by_session_token(token) == nil
    assert {:error, :inactive} = Accounts.create_moderator_session(inactive_account)
  end

  defp insert_account do
    %ModeratorAccount{password_hash: "stored-password-verifier"}
    |> ModeratorAccount.changeset(%{
      email: "editor@example.com",
      display_name: "Archive Editor"
    })
    |> Repo.insert!()
  end
end
