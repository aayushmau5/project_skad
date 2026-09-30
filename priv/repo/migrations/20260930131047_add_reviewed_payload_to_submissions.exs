defmodule Skad.Repo.Migrations.AddReviewedPayloadToSubmissions do
  use Ecto.Migration

  def change do
    alter table(:submissions) do
      add :reviewed_payload, :map,
        check: %{
          name: "submissions_reviewed_payload_must_be_json",
          expr: "reviewed_payload IS NULL OR json_valid(reviewed_payload)"
        }
    end
  end
end
