defmodule Skad.ArchiveSearchTest do
  use Skad.DataCase

  alias Skad.Archive

  test "ranks exact, prefix, and full-text results without duplicates" do
    {:ok, english} = create_language("english", "en", "English")
    {:ok, full_text} = publish_meaning(english, "AQUA", "Aqua", "A water container")
    {:ok, prefix} = publish_meaning(english, "WATERFALL", "Waterfall", "A cascade")
    {:ok, exact} = publish_meaning(english, "WATER", "Water", "A clear liquid")

    assert [exact_result, prefix_result, full_text_result] = Archive.search("water")
    assert exact_result.entry.id == exact.id
    assert exact_result.matched_form.text == "Water"
    assert prefix_result.entry.id == prefix.id
    assert prefix_result.matched_form.text == "Waterfall"
    assert full_text_result.entry.id == full_text.id
    assert full_text_result.matched_form == nil
    assert exact_result.entry.language.id == english.id
    assert exact_result.entry.concept.editorial_label == "WATER"
  end

  test "searches definitions and notes with safe AND queries" do
    {:ok, english} = create_language("english", "en", "English")

    {:ok, entry} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          definitions: [%{language: "english", text: "A clear potable liquid"}],
          usage_note: "Supports daily hydration",
          cultural_note: "Used as a ritual offering"
        },
        forms: [%{text: "Pāni", kind: :spelling, is_primary: true}]
      })

    assert [%{entry: definition_match}] = Archive.search("clear liquid")
    assert definition_match.id == entry.id
    assert [%{entry: usage_match}] = Archive.search("hydration")
    assert usage_match.id == entry.id
    assert [%{entry: cultural_match}] = Archive.search("ritual")
    assert cultural_match.id == entry.id
    assert [%{entry: diacritic_match, matched_form: nil}] = Archive.search("pani")
    assert diacritic_match.id == entry.id

    assert Archive.search("clear missing") == []
    assert Archive.search(~s[") OR ("]) == []
  end

  test "indexes focus examples but not reference links or translations" do
    {:ok, english} = create_language("english", "en", "English")
    {:ok, water} = publish_meaning(english, "WATER", "Water", "A liquid")
    {:ok, vessel} = publish_meaning(english, "VESSEL", "Vessel", "A container")

    text = "Children fill the vessel."

    assert {:ok, _example} =
             Archive.publish_usage_example(english, %{
               example: %{
                 text: text,
                 translations: [%{language: "hindi", text: "hidden translation marker"}]
               },
               links: [
                 %{
                   entry_public_id: water.public_id,
                   start_offset: 0,
                   end_offset: byte_size("Children"),
                   role: :focus
                 },
                 %{
                   entry_public_id: vessel.public_id,
                   start_offset: byte_size("Children fill the "),
                   end_offset: byte_size("Children fill the vessel"),
                   role: :reference
                 }
               ]
             })

    assert [%{entry: result}] = Archive.search("children")
    assert result.id == water.id
    assert Archive.search("hidden translation marker") == []
  end

  test "rebuilds the index and applies language filters" do
    {:ok, english} = create_language("english", "en", "English")
    {:ok, hindi} = create_language("hindi", "hi", "Hindi")
    {:ok, english_entry} = publish_meaning(english, "RAIN", "Rain", "Weather marker")

    {:ok, hindi_entry} =
      Archive.publish_equivalent(english_entry, hindi, %{
        entry: %{definitions: [%{language: "hindi", text: "Weather marker"}]},
        forms: [%{text: "बारिश", kind: :spelling, is_primary: true}]
      })

    assert Archive.search("weather marker")
           |> Enum.map(& &1.entry.id)
           |> MapSet.new() == MapSet.new([english_entry.id, hindi_entry.id])

    Repo.query!("DELETE FROM entry_search")
    assert Archive.search("weather marker") == []

    assert {:ok, 2} = Archive.rebuild_search_index()

    assert [%{entry: result}] = Archive.search("weather marker", hindi)
    assert result.id == hindi_entry.id
  end

  defp create_language(slug, code, name) do
    Archive.create_language(%{slug: slug, code: code, name: name, direction: :ltr})
  end

  defp publish_meaning(language, label, form, definition) do
    Archive.publish_new_meaning(language, %{
      concept: %{editorial_label: label},
      entry: %{definitions: [%{language: language.slug, text: definition}]},
      forms: [%{text: form, kind: :spelling, is_primary: true}]
    })
  end
end
