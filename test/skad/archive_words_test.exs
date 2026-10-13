defmodule Skad.ArchiveWordsTest do
  use Skad.DataCase

  alias Skad.Archive
  alias Skad.Archive.Entry
  alias Skad.Archive.Words

  setup do
    {:ok, language} =
      Archive.create_language(%{slug: "english", name: "English", code: "en", direction: :ltr})

    %{language: language}
  end

  test "groups primary spellings while retaining translated definitions and language boundaries",
       %{language: language} do
    first = publish(language, "Bank", "River edge", [%{language: "hindi", text: "नदी का किनारा"}])
    second = publish(language, "bank", "Financial institution")

    {:ok, hindi} =
      Archive.create_language(%{slug: "hindi", name: "Hindi", code: "hi", direction: :ltr})

    other = publish(hindi, "Bank", "Another language")

    assert %{meanings: meanings} = Archive.get_public_word(second.public_id)
    assert Enum.map(meanings, & &1.id) == [first.id, second.id]
    assert length(hd(meanings).definitions) == 2
    assert Archive.count_public_words() == 2
    assert Archive.count_public_entries() == 3
    assert [english_word, hindi_word] = Archive.search_words("bank")
    assert length(english_word.meanings) == 2
    assert Enum.map(hindi_word.meanings, & &1.id) == [other.id]
  end

  test "groups before search limits, pagination and recent-word selection", %{language: language} do
    meanings = for number <- 1..25, do: publish(language, "Bank", "Shared meaning #{number}")

    for number <- 1..21,
        do:
          publish(
            language,
            "Bank #{String.pad_leading(to_string(number), 2, "0")}",
            "Shared definition"
          )

    for query <- ["bank", "shared"] do
      words = Archive.search_words(query)
      assert length(words) == 20
      assert Enum.uniq_by(words, & &1.entry.id) == words
      bank = Enum.find(words, &(length(&1.meanings) == 25))
      assert bank
      assert Enum.map(bank.meanings, & &1.id) == Enum.map(meanings, & &1.id)
    end

    first_page = Archive.list_public_words(language, 1)
    second_page = Archive.list_public_words(language, 2)
    assert first_page.total_count == 22
    assert first_page.page_count == 2
    assert length(first_page.entries) == 20
    assert length(hd(first_page.entries).meanings) == 25
    assert length(second_page.entries) == 2

    publish(language, "Bank", "Newest meaning")
    assert [bank, _, _] = Archive.list_recent_public_words()
    assert length(bank.meanings) == 26
  end

  test "aliases remain search matches and archived meanings disappear", %{language: language} do
    bank = publish(language, "Bank", "River edge")

    {:ok, multi} =
      Archive.add_to_entry_multi(Ecto.Multi.new(), bank, %{
        text: "shore",
        kind: :alias,
        is_primary: false
      })

    {:ok, _} = Repo.transaction(multi)
    shore = publish(language, "Shore", "Coast")
    archived = publish(language, "Bank", "Hidden meaning")
    archived |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()
    hidden = publish(language, "Bank", "Hidden concept")

    hidden.concept
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert Archive.get_public_word(archived.public_id) == nil
    assert %{meanings: [%{id: id}]} = Archive.get_public_word(bank.public_id)
    assert id == bank.id
    assert Enum.map(Archive.search_words("shore"), & &1.entry.id) == [shore.id, bank.id]
    assert Archive.count_public_words() == 2
  end

  test "a word archived after the initial lookup is no longer public", %{language: language} do
    entry = publish(language, "Bank", "River edge")
    publish(language, "Bank", "Financial institution")
    entry |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert Words.get(entry) == nil
  end

  test "grouped readers tolerate archiving between their queries", %{language: language} do
    for reader <- [:search, :browse, :recent] do
      entry = publish(language, "Race #{reader}", "Original meaning")
      publish(language, "Race #{reader}", "Surviving meaning")

      archive_after_query(entry, fn query ->
        if reader == :search,
          do: String.contains?(query, "WITH full_text"),
          else: String.starts_with?(query, "SELECT min(")
      end)

      words =
        case reader do
          :search -> Archive.search_words("Race #{reader}", language)
          :browse -> Archive.list_public_words(language).entries
          :recent -> Archive.list_recent_public_words()
        end

      assert Repo.get!(Entry, entry.id).archived_at
      refute Enum.any?(words, &(&1.entry.id == entry.id))
    end
  end

  defp archive_after_query(entry, matches?) do
    handler_id = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:skad, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and matches?.(metadata.query) do
            :telemetry.detach(handler_id)

            entry
            |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
            |> Repo.update!()
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp publish(language, form, definition, translations \\ []) do
    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: definition},
        entry: %{definitions: [%{language: "english", text: definition} | translations]},
        forms: [%{text: form, kind: :spelling, is_primary: true}]
      })

    entry
  end
end
