defmodule Skad.Accounts.ModeratorSessionToken do
  use Ecto.Schema

  import Ecto.Changeset

  schema "moderator_session_tokens" do
    field :token, :binary, redact: true
    belongs_to :moderator_account, Skad.Accounts.ModeratorAccount

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(session_token) do
    session_token
    |> change()
    |> validate_required([:moderator_account_id, :token])
    |> foreign_key_constraint(:moderator_account_id)
    |> unique_constraint(:token)
  end
end
