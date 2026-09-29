defmodule Skad.Repo.Migrations.CreateArchiveCore do
  use Ecto.Migration

  def change do
    create table(:languages) do
      add :public_id, :binary_id, null: false
      add :slug, :string, null: false
      add :code, :string
      add :name, :string, null: false

      add :direction, :string,
        null: false,
        check: %{
          name: "languages_direction_must_be_valid",
          expr: "direction IN ('ltr', 'rtl')"
        }

      add :active, :boolean, null: false, default: true
    end

    create unique_index(:languages, [:public_id])
    create unique_index(:languages, [:slug])
    create unique_index(:languages, [:code])

    create table(:concepts) do
      add :public_id, :binary_id, null: false
      add :editorial_label, :string, null: false
      add :editorial_note, :text
      add :archived_at, :utc_datetime
    end

    create unique_index(:concepts, [:public_id])

    create table(:entries) do
      add :public_id, :binary_id, null: false
      add :language_id, references(:languages), null: false
      add :concept_id, references(:concepts), null: false
      add :definitions, :map, null: false
      add :part_of_speech, :string
      add :variety_label, :string
      add :place_label, :string
      add :usage_note, :text
      add :cultural_note, :text
      add :archived_at, :utc_datetime
    end

    create unique_index(:entries, [:public_id])
    create unique_index(:entries, [:id, :language_id])
    create index(:entries, [:concept_id])

    create table(:entry_forms) do
      add :language_id, :integer, null: false

      add :entry_id,
          references(:entries, with: [language_id: :language_id]),
          null: false

      add :text, :string,
        null: false,
        check: %{name: "entry_forms_text_must_not_be_empty", expr: "length(text) > 0"}

      add :normalized_text, :string,
        null: false,
        check: %{
          name: "entry_forms_normalized_text_must_not_be_empty",
          expr: "length(normalized_text) > 0"
        }

      add :kind, :string,
        null: false,
        check: %{
          name: "entry_forms_kind_must_be_valid",
          expr: "kind IN ('spelling', 'transliteration', 'historical', 'alias')"
        }

      add :is_primary, :boolean, null: false, default: false
    end

    create index(:entry_forms, [:normalized_text, :language_id, :entry_id])
    create index(:entry_forms, [:language_id, :normalized_text, :entry_id])
    create unique_index(:entry_forms, [:entry_id, :normalized_text, :kind])

    create unique_index(:entry_forms, [:entry_id],
             name: :entry_forms_one_primary_per_entry_index,
             where: "is_primary = 1"
           )

    create table(:examples) do
      add :public_id, :binary_id, null: false
      add :language_id, references(:languages), null: false
      add :text, :text, null: false
      add :normalized_text, :text, null: false
      add :translations, :map, null: false, default: []
      add :archived_at, :utc_datetime
    end

    create unique_index(:examples, [:public_id])
    create index(:examples, [:language_id])

    create table(:example_links) do
      add :example_id, references(:examples), null: false
      add :entry_id, references(:entries), null: false
      add :start_offset, :integer, null: false

      add :end_offset, :integer,
        null: false,
        check: %{
          name: "example_links_end_offset_must_follow_start_offset",
          expr: "end_offset > start_offset"
        }

      add :surface_text, :string, null: false

      add :role, :string,
        null: false,
        check: %{
          name: "example_links_role_must_be_valid",
          expr: "role IN ('focus', 'reference')"
        }
    end

    create index(:example_links, [:example_id])
    create index(:example_links, [:entry_id])
  end
end
