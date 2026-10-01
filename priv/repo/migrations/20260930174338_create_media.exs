defmodule Skad.Repo.Migrations.CreateMedia do
  use Ecto.Migration

  def change do
    create table(:media) do
      add :public_id, :binary_id, null: false

      add :kind, :string,
        null: false,
        check: %{name: "media_kind_must_be_valid", expr: "kind IN ('audio', 'image')"}

      add :entry_id, references(:entries)
      add :concept_id, references(:concepts)

      add :original_object_key, :string,
        null: false,
        check: %{
          name: "media_original_object_key_must_not_be_empty",
          expr: "length(trim(original_object_key)) > 0"
        }

      add :public_object_key, :string,
        check: %{
          name: "media_public_object_key_must_not_be_empty",
          expr: "public_object_key IS NULL OR length(trim(public_object_key)) > 0"
        }

      add :mime_type, :string,
        null: false,
        check: %{
          name: "media_mime_type_must_not_be_empty",
          expr: "length(trim(mime_type)) > 0"
        }

      add :byte_size, :integer,
        null: false,
        check: %{name: "media_byte_size_must_be_positive", expr: "byte_size > 0"}

      add :sha256, :string,
        null: false,
        check: %{name: "media_sha256_must_not_be_empty", expr: "length(trim(sha256)) > 0"}

      add :duration_ms, :integer,
        check: %{
          name: "media_dimensions_must_match_kind",
          expr:
            "(duration_ms IS NULL OR duration_ms > 0) AND " <>
              "((kind = 'audio' AND width IS NULL AND height IS NULL) OR " <>
              "(kind = 'image' AND duration_ms IS NULL))"
        }

      add :width, :integer,
        check: %{name: "media_width_must_be_positive", expr: "width IS NULL OR width > 0"}

      add :height, :integer,
        check: %{name: "media_height_must_be_positive", expr: "height IS NULL OR height > 0"}

      add :variety_label, :string
      add :place_label, :string
      add :attribution_text, :string

      add :processing_state, :string,
        null: false,
        default: "uploaded",
        check: %{
          name: "media_processing_state_must_be_valid",
          expr: "processing_state IN ('uploaded', 'validated', 'processing', 'ready', 'failed')"
        }

      add :visibility, :string,
        null: false,
        default: "quarantine",
        check: %{
          name: "media_visibility_must_be_valid",
          expr:
            "visibility IN ('quarantine', 'private', 'public', 'withdrawn', 'pending_deletion') AND " <>
              "(visibility <> 'public' OR " <>
              "(processing_state = 'ready' AND public_object_key IS NOT NULL AND " <>
              "(entry_id IS NOT NULL OR concept_id IS NOT NULL)))"
        }

      add :archived_at, :utc_datetime
    end

    create unique_index(:media, [:public_id])
    create unique_index(:media, [:original_object_key])
    create unique_index(:media, [:public_object_key])
    create index(:media, [:entry_id])
    create index(:media, [:concept_id])
    create index(:media, [:sha256])
    create index(:media, [:processing_state])
    create index(:media, [:visibility])
  end
end
