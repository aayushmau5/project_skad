defmodule Skad.Repo.Migrations.CreateModeratorAuth do
  use Ecto.Migration

  def change do
    create table(:moderator_accounts) do
      add :email, :string,
        null: false,
        check: %{
          name: "moderator_accounts_email_must_not_be_empty",
          expr: "length(trim(email)) > 0"
        }

      add :password_hash, :string,
        null: false,
        check: %{
          name: "moderator_accounts_password_hash_must_not_be_empty",
          expr: "length(password_hash) > 0"
        }

      add :display_name, :string,
        null: false,
        check: %{
          name: "moderator_accounts_display_name_must_not_be_empty",
          expr: "length(trim(display_name)) > 0"
        }

      add :active, :boolean, null: false, default: true
      add :last_login_at, :utc_datetime
    end

    create unique_index(:moderator_accounts, [:email])

    create table(:moderator_session_tokens) do
      add :moderator_account_id,
          references(:moderator_accounts, on_delete: :delete_all),
          null: false

      add :token, :binary, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:moderator_session_tokens, [:moderator_account_id])
    create unique_index(:moderator_session_tokens, [:token])
  end
end
