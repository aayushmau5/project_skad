defmodule Skad.Accounts.ModeratorAccount do
  use Ecto.Schema

  import Ecto.Changeset

  schema "moderator_accounts" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :display_name, :string
    field :active, :boolean, default: true
    field :last_login_at, :utc_datetime

    has_many :session_tokens, Skad.Accounts.ModeratorSessionToken
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:email, :display_name])
    |> update_change(:email, &normalize_email/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:email, :password_hash, :display_name, :active])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> validate_length(:display_name, max: 160)
    |> unique_constraint(:email)
  end

  def normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  def password_changeset(account, attrs) do
    account
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_length(:password, min: 12, max: 72)
    |> validate_length(:password, max: 72, count: :bytes)
    |> hash_password()
  end

  def valid_password?(%__MODULE__{password_hash: password_hash}, password)
      when is_binary(password_hash) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, password_hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
