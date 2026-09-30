defmodule Skad.AccountsSchemasTest do
  use Skad.DataCase

  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.ModeratorSessionToken

  test "persists a moderator account and its session token" do
    {:ok, account} =
      %ModeratorAccount{password_hash: "stored-password-verifier"}
      |> ModeratorAccount.changeset(%{
        email: "  Editor@Example.COM ",
        display_name: " Archive Editor "
      })
      |> Repo.insert()

    {:ok, session_token} =
      %ModeratorSessionToken{
        moderator_account_id: account.id,
        token: :crypto.strong_rand_bytes(32)
      }
      |> ModeratorSessionToken.changeset()
      |> Repo.insert()

    account = Repo.preload(account, :session_tokens)

    assert account.email == "editor@example.com"
    assert account.display_name == "Archive Editor"
    assert account.active
    assert account.session_tokens == [session_token]
  end

  test "validates moderator email and maps its unique constraint" do
    changeset =
      %ModeratorAccount{password_hash: "stored-password-verifier"}
      |> ModeratorAccount.changeset(%{email: "not an email", display_name: "Editor"})

    refute changeset.valid?
    assert "must have the @ sign and no spaces" in errors_on(changeset).email

    insert_account("editor@example.com")
    assert {:error, duplicate} = insert_account("EDITOR@EXAMPLE.COM")
    assert "has already been taken" in errors_on(duplicate).email
  end

  defp insert_account(email) do
    %ModeratorAccount{password_hash: "stored-password-verifier"}
    |> ModeratorAccount.changeset(%{email: email, display_name: "Archive Editor"})
    |> Repo.insert()
  end
end
