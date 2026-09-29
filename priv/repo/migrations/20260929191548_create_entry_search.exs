defmodule Skad.Repo.Migrations.CreateEntrySearch do
  use Ecto.Migration

  def up do
    execute("""
    CREATE VIRTUAL TABLE entry_search USING fts5(
      entry_id UNINDEXED,
      language_id UNINDEXED,
      forms,
      definitions,
      notes,
      examples,
      tokenize = "unicode61 remove_diacritics 2 categories 'L* N* Co M*'"
    )
    """)
  end

  def down, do: execute("DROP TABLE entry_search")
end
