defmodule Skad.Repo.Migrations.CreateSubmissions do
  use Ecto.Migration

  def change do
    create table(:submissions) do
      add :public_id, :binary_id, null: false
      add :client_submission_id, :binary_id, null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "submissions_kind_must_be_valid",
          expr: "kind IN ('new_entry', 'correction', 'example', 'audio', 'image', 'addition')"
        }

      add :target_type, :string

      add :target_public_id, :binary_id,
        check: %{
          name: "submissions_target_must_be_complete",
          expr:
            "(target_type IS NULL) = (target_public_id IS NULL) AND (target_type IS NULL OR length(trim(target_type)) > 0)"
        }

      add :payload, :map,
        null: false,
        check: %{name: "submissions_payload_must_be_json", expr: "json_valid(payload)"}

      add :status, :string,
        null: false,
        default: "pending",
        check: %{
          name: "submissions_status_must_be_valid",
          expr:
            "status IN ('pending', 'reviewing', 'clarification_needed', 'approved', 'rejected', 'withdrawn')"
        }

      add :received_at, :utc_datetime, null: false
    end

    create unique_index(:submissions, [:public_id])
    create unique_index(:submissions, [:client_submission_id])
    create index(:submissions, [:status, :received_at])
  end
end
