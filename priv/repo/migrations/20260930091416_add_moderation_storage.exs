defmodule Skad.Repo.Migrations.AddModerationStorage do
  use Ecto.Migration

  def change do
    alter table(:submissions) do
      add :review_history, :map,
        null: false,
        default: fragment("'[]'"),
        check: %{
          name: "submissions_review_history_must_be_array",
          expr: "json_valid(review_history) AND json_type(review_history) = 'array'"
        }

      add :reviewed_by_account_id, references(:moderator_accounts)
      add :reviewed_at, :utc_datetime
      add :review_note, :text
    end

    create table(:revisions) do
      add :target_type, :string,
        null: false,
        check: %{
          name: "revisions_target_type_must_not_be_empty",
          expr: "length(trim(target_type)) > 0"
        }

      add :target_public_id, :binary_id, null: false

      add :action, :string,
        null: false,
        check: %{
          name: "revisions_action_must_be_valid",
          expr: "action IN ('create', 'update', 'archive', 'restore', 'merge', 'withdraw')"
        }

      add :before_state, :map,
        check: %{
          name: "revisions_before_state_must_be_json",
          expr: "before_state IS NULL OR json_valid(before_state)"
        }

      add :after_state, :map,
        check: %{
          name: "revisions_after_state_must_be_json",
          expr: "after_state IS NULL OR json_valid(after_state)"
        }

      add :actor_type, :string,
        null: false,
        check: %{
          name: "revisions_actor_type_must_be_valid",
          expr: "actor_type IN ('moderator', 'system', 'importer')"
        }

      add :moderator_account_id, references(:moderator_accounts)
      add :submission_id, references(:submissions)

      add :source, :map,
        check: %{
          name: "revisions_source_must_be_json",
          expr: "source IS NULL OR json_valid(source)"
        }

      add :reason, :text
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:revisions, [:target_type, :target_public_id, :inserted_at])
    create index(:revisions, [:submission_id])
  end
end
