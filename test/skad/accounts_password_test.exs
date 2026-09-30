defmodule Skad.AccountsPasswordTest do
  use Skad.DataCase

  alias Skad.Accounts
  alias Skad.Accounts.ModeratorAccount

  @password "correct horse battery staple"

  test "creates a moderator with a hashed password" do
    assert {:ok, account} = create_account()

    assert account.email == "editor@example.com"
    assert account.password_hash != @password
    assert ModeratorAccount.valid_password?(account, @password)
    refute inspect(account) =~ account.password_hash
  end

  test "validates password length and confirmation" do
    assert {:error, short_password} = create_account(%{password: "too short"})
    assert "should be at least 12 character(s)" in errors_on(short_password).password

    assert {:error, confirmation} =
             create_account(%{password_confirmation: "a different password"})

    assert "does not match password" in errors_on(confirmation).password_confirmation
  end

  test "authenticates active moderators and records their last login" do
    assert {:ok, account} = create_account()
    assert account.last_login_at == nil

    assert {:ok, authenticated} =
             Accounts.authenticate_moderator(" EDITOR@EXAMPLE.COM ", @password)

    assert authenticated.id == account.id
    assert authenticated.last_login_at
  end

  test "rejects incorrect, unknown, and inactive credentials identically" do
    assert {:ok, account} = create_account()
    assert :error = Accounts.authenticate_moderator(account.email, "wrong password")
    assert :error = Accounts.authenticate_moderator("missing@example.com", @password)

    assert {:ok, inactive_account} = Accounts.set_moderator_active(account, false)
    assert :error = Accounts.authenticate_moderator(inactive_account.email, @password)
  end

  defp create_account(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          email: "Editor@Example.COM",
          display_name: "Archive Editor",
          password: @password,
          password_confirmation: @password
        },
        overrides
      )

    Accounts.create_moderator_account(attrs)
  end
end
