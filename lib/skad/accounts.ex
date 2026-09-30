defmodule Skad.Accounts do
  import Ecto.Query

  alias Ecto.Multi
  alias Skad.Accounts.ModeratorAccount
  alias Skad.Accounts.ModeratorSessionToken
  alias Skad.Repo

  @session_validity_in_days 14

  def create_moderator_account(attrs) when is_map(attrs) do
    %ModeratorAccount{}
    |> ModeratorAccount.password_changeset(attrs)
    |> ModeratorAccount.changeset(attrs)
    |> Repo.insert()
  end

  def authenticate_moderator(email, password)
      when is_binary(email) and is_binary(password) do
    account = get_moderator_account_by_email(email)

    if ModeratorAccount.valid_password?(account, password) && account.active do
      account
      |> Ecto.Changeset.change(last_login_at: DateTime.utc_now(:second))
      |> Repo.update()
    else
      :error
    end
  end

  def authenticate_moderator(_email, _password) do
    ModeratorAccount.valid_password?(nil, nil)
    :error
  end

  def get_moderator_account_by_email(email) when is_binary(email) do
    Repo.get_by(ModeratorAccount, email: ModeratorAccount.normalize_email(email))
  end

  def get_moderator_account_by_email(_email), do: nil

  def set_moderator_active(%ModeratorAccount{} = account, active) when is_boolean(active) do
    Multi.new()
    |> Multi.update(:account, Ecto.Changeset.change(account, active: active))
    |> maybe_revoke_sessions(account, active)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, :account, changeset, _changes} -> {:error, changeset}
    end
  end

  def create_moderator_session(%ModeratorAccount{active: true} = account) do
    token = :crypto.strong_rand_bytes(32)

    result =
      %ModeratorSessionToken{moderator_account_id: account.id, token: token}
      |> ModeratorSessionToken.changeset()
      |> Repo.insert()

    case result do
      {:ok, _session} -> {:ok, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_moderator_session(%ModeratorAccount{}), do: {:error, :inactive}

  def get_moderator_account_by_session_token(token) when is_binary(token) do
    ModeratorSessionToken
    |> join(:inner, [session], account in assoc(session, :moderator_account))
    |> where(
      [session, account],
      session.token == ^token and
        session.inserted_at > ago(@session_validity_in_days, "day") and account.active
    )
    |> select([_session, account], account)
    |> Repo.one()
  end

  def get_moderator_account_by_session_token(_token), do: nil

  def delete_moderator_session(token) when is_binary(token) do
    Repo.delete_all(from session in ModeratorSessionToken, where: session.token == ^token)
    :ok
  end

  def delete_moderator_session(_token), do: :ok

  defp maybe_revoke_sessions(multi, _account, true), do: multi

  defp maybe_revoke_sessions(multi, account, false) do
    Multi.delete_all(
      multi,
      :sessions,
      from(session in ModeratorSessionToken,
        where: session.moderator_account_id == ^account.id
      )
    )
  end
end
