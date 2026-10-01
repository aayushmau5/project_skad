defmodule Skad.Repo.Migrations.AddSubmissionMediaOwnership do
  use Ecto.Migration

  def change do
    alter table(:media) do
      add :submission_id, references(:submissions)
    end

    create index(:media, [:submission_id])

    create unique_index(:media, [:submission_id],
             name: :media_one_active_audio_per_submission,
             where:
               "kind = 'audio' AND submission_id IS NOT NULL AND archived_at IS NULL AND visibility NOT IN ('withdrawn', 'pending_deletion')"
           )

    create unique_index(:media, [:entry_id],
             name: :media_one_active_audio_per_entry,
             where:
               "kind = 'audio' AND entry_id IS NOT NULL AND archived_at IS NULL AND visibility NOT IN ('withdrawn', 'pending_deletion')"
           )
  end
end
