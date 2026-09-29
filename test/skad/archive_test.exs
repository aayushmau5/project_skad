defmodule Skad.ArchiveTest do
  use Skad.DataCase

  alias Ecto.Changeset
  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink

  test "configures and lists active languages" do
    assert Archive.list_active_languages() == []

    assert {:ok, english} =
             Archive.create_language(%{
               slug: "english",
               code: "en",
               name: "English",
               direction: :ltr
             })

    assert {:ok, _inactive} =
             Archive.create_language(%{
               slug: "hindi",
               code: "hi",
               name: "Hindi",
               direction: :ltr,
               active: false
             })

    assert Archive.list_active_languages() == [english]
    assert Archive.get_language_by_slug("english").id == english.id
  end

  test "publishes the first entry for a meaning as one complete record" do
    {:ok, language} = create_language()

    assert {:ok, entry} =
             Archive.publish_new_meaning(language, %{
               "concept" => %{"editorial_label" => "WATER"},
               "entry" => %{
                 "part_of_speech" => "noun",
                 "definitions" => [
                   %{
                     "language" => "english",
                     "text" => "A clear liquid used for drinking."
                   }
                 ]
               },
               "forms" => [
                 %{"text" => "Water", "kind" => "spelling", "is_primary" => "true"},
                 %{"text" => "H₂O", "kind" => "alias", "is_primary" => "false"}
               ]
             })

    assert entry.language.id == language.id
    assert entry.concept.editorial_label == "WATER"
    assert Enum.map(entry.forms, & &1.normalized_text) == ["water", "h₂o"]
    assert Enum.count(entry.concept.entries) == 1
    assert entry.example_links == []

    assert Archive.get_public_entry(entry.public_id).id == entry.id
  end

  test "looks up exact forms without losing homographs or duplicating entries" do
    {:ok, english} = create_language()

    {:ok, water} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: "english", text: "A clear liquid."}]},
        forms: [
          %{text: "Water", kind: :spelling, is_primary: true},
          %{text: "H₂O", kind: :alias, is_primary: false},
          %{text: "H₂O", kind: :historical, is_primary: false}
        ]
      })

    {:ok, formula} = publish_meaning(english, "CHEMICAL FORMULA", "H₂O")

    {:ok, hindi} =
      Archive.create_language(%{
        slug: "hindi",
        code: "hi",
        name: "Hindi",
        direction: :ltr
      })

    {:ok, hindi_entry} = publish_meaning(hindi, "CHEMICAL FORMULA", "H₂O")
    {:ok, archived} = publish_meaning(english, "ARCHIVED", "H₂O")

    archived
    |> Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert [formula_match, hindi_match, water_match] = Archive.exact_lookup("  H₂O  ")
    assert formula_match.entry.id == formula.id
    assert hindi_match.entry.id == hindi_entry.id
    assert water_match.entry.id == water.id
    assert Enum.all?([formula_match, hindi_match, water_match], &(&1.matched_form.text == "H₂O"))

    assert [english_formula, english_water] = Archive.exact_lookup("H₂O", english)
    assert english_formula.entry.id == formula.id
    assert english_water.entry.id == water.id
    assert english_formula.entry.language.id == english.id
    assert english_formula.entry.concept.editorial_label == "CHEMICAL FORMULA"
    assert length(english_water.entry.forms) == 3

    assert Archive.exact_lookup("   ") == []
  end

  test "looks up form prefixes with deterministic ranking" do
    {:ok, english} = create_language()

    {:ok, alias_match} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "CHANNEL"},
        entry: %{definitions: [%{language: "english", text: "A channel."}]},
        forms: [
          %{text: "Channel", kind: :spelling, is_primary: true},
          %{text: "Waterway", kind: :alias, is_primary: false}
        ]
      })

    {:ok, waterfall} = publish_meaning(english, "WATERFALL", "Waterfall")

    {:ok, water} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: "english", text: "A clear liquid."}]},
        forms: [
          %{text: "Water", kind: :spelling, is_primary: true},
          %{text: "Waterline", kind: :alias, is_primary: false}
        ]
      })

    assert Archive.exact_lookup("wat", english) == []

    assert [waterfall_result, water_result, alias_result] = Archive.prefix_lookup("  WAT  ")

    assert waterfall_result.entry.id == waterfall.id
    assert water_result.entry.id == water.id
    assert alias_result.entry.id == alias_match.id
    assert alias_result.matched_form.text == "Waterway"

    assert [exact_result, prefix_result, alternate_result] =
             Archive.prefix_lookup("water", english)

    assert exact_result.entry.id == water.id
    assert exact_result.matched_form.text == "Water"
    assert prefix_result.entry.id == waterfall.id
    assert alternate_result.entry.id == alias_match.id

    assert Enum.count([exact_result, prefix_result, alternate_result], &(&1.entry.id == water.id)) ==
             1

    {:ok, literal_glob} = publish_meaning(english, "LITERAL GLOB", "Star*word")
    {:ok, _ordinary_prefix} = publish_meaning(english, "ORDINARY PREFIX", "Starship")

    assert [%{entry: entry}] = Archive.prefix_lookup("star*", english)
    assert entry.id == literal_glob.id

    assert Archive.prefix_lookup("   ") == []
  end

  test "rejects an incomplete form set before writing anything" do
    {:ok, language} = create_language()

    attrs = %{
      concept: %{editorial_label: "WATER"},
      entry: %{
        definitions: [%{language: "english", text: "A clear liquid."}]
      },
      forms: [
        %{text: "water", kind: :spelling, is_primary: true},
        %{text: "H₂O", kind: :alias, is_primary: true}
      ]
    }

    assert {:error, :exactly_one_primary_form_required} =
             Archive.publish_new_meaning(language, attrs)

    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "publishes an equivalent expression into the existing meaning" do
    {:ok, english} = create_language()

    {:ok, english_entry} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          definitions: [%{language: "english", text: "A clear liquid."}]
        },
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    {:ok, hindi} =
      Archive.create_language(%{
        slug: "hindi",
        code: "hi",
        name: "Hindi",
        direction: :ltr
      })

    assert {:ok, hindi_entry} =
             Archive.publish_equivalent(english_entry, hindi, %{
               entry: %{
                 definitions: [%{language: "hindi", text: "पीने के लिए उपयोग किया जाने वाला तरल।"}]
               },
               forms: [
                 %{text: "पानी", kind: :spelling, is_primary: true},
                 %{text: "Paani", kind: :transliteration, is_primary: false}
               ]
             })

    assert hindi_entry.concept_id == english_entry.concept_id
    assert hindi_entry.language.id == hindi.id
    assert Enum.map(hindi_entry.forms, & &1.normalized_text) == ["पानी", "paani"]

    equivalent_ids =
      english_entry.public_id
      |> Archive.get_public_entry()
      |> then(&Enum.map(&1.concept.entries, fn entry -> entry.id end))

    assert equivalent_ids == [english_entry.id, hindi_entry.id]
    assert Repo.aggregate(Concept, :count) == 1
  end

  test "rejects unavailable languages and meanings without adding an entry" do
    {:ok, english} = create_language()

    {:ok, english_entry} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          definitions: [%{language: "english", text: "A clear liquid."}]
        },
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    {:ok, inactive_language} =
      Archive.create_language(%{
        slug: "inactive",
        name: "Inactive",
        direction: :ltr,
        active: false
      })

    equivalent_attrs = %{
      entry: %{
        definitions: [%{language: "hindi", text: "पीने के लिए उपयोग किया जाने वाला तरल।"}]
      },
      forms: [%{text: "पानी", kind: :spelling, is_primary: true}]
    }

    assert {:error, :language_inactive} =
             Archive.publish_equivalent(english_entry, inactive_language, equivalent_attrs)

    english_entry.concept
    |> Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert {:error, :meaning_unavailable} =
             Archive.publish_equivalent(english_entry, english, equivalent_attrs)

    assert Repo.aggregate(Entry, :count) == 1
  end

  test "rolls back the meaning when a form is invalid" do
    {:ok, language} = create_language()

    attrs = %{
      concept: %{editorial_label: "WATER"},
      entry: %{
        definitions: [%{language: "english", text: "A clear liquid."}]
      },
      forms: [%{text: "water", kind: :unknown, is_primary: true}]
    }

    assert {:error, %Changeset{valid?: false}} = Archive.publish_new_meaning(language, attrs)
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "publishes a Unicode usage example with confirmed byte spans" do
    {:ok, hindi} =
      Archive.create_language(%{
        slug: "hindi",
        code: "hi",
        name: "Hindi",
        direction: :ltr
      })

    {:ok, water_entry} = publish_meaning(hindi, "WATER", "पानी")
    {:ok, drink_entry} = publish_meaning(hindi, "DRINK", "पियो")

    text = "पानी पियो।"
    water_end = byte_size("पानी")
    drink_start = water_end + byte_size(" ")
    drink_end = drink_start + byte_size("पियो")

    assert {:ok, example} =
             Archive.publish_usage_example(hindi, %{
               example: %{
                 text: text,
                 translations: [
                   %{language: "english", text: "Drink water."}
                 ]
               },
               links: [
                 %{
                   entry_public_id: water_entry.public_id,
                   start_offset: "0",
                   end_offset: to_string(water_end),
                   role: "focus"
                 },
                 %{
                   entry_public_id: drink_entry.public_id,
                   start_offset: to_string(drink_start),
                   end_offset: to_string(drink_end),
                   role: "reference"
                 }
               ]
             })

    assert example.text == text
    assert Enum.map(example.links, & &1.surface_text) == ["पानी", "पियो"]
    assert Enum.map(example.links, & &1.role) == [:focus, :reference]

    public_entry = Archive.get_public_entry(water_entry.public_id)
    assert [focus_link] = public_entry.example_links
    assert focus_link.example.public_id == example.public_id
    assert Enum.map(focus_link.example.links, & &1.surface_text) == ["पानी", "पियो"]
  end

  test "rolls back an example when confirmed byte spans are invalid" do
    {:ok, hindi} =
      Archive.create_language(%{
        slug: "hindi",
        code: "hi",
        name: "Hindi",
        direction: :ltr
      })

    {:ok, water_entry} = publish_meaning(hindi, "WATER", "पानी")
    text = "पानी पियो।"

    attrs = %{
      example: %{text: text, translations: []},
      links: [
        %{
          entry_public_id: water_entry.public_id,
          start_offset: 1,
          end_offset: byte_size("पानी"),
          role: :focus
        }
      ]
    }

    assert {:error, :invalid_link_span} = Archive.publish_usage_example(hindi, attrs)

    overlapping_attrs = %{
      attrs
      | links: [
          %{
            entry_public_id: water_entry.public_id,
            start_offset: 0,
            end_offset: byte_size("पानी"),
            role: :focus
          },
          %{
            entry_public_id: water_entry.public_id,
            start_offset: 0,
            end_offset: byte_size("पानी"),
            role: :reference
          }
        ]
    }

    assert {:error, :overlapping_links} =
             Archive.publish_usage_example(hindi, overlapping_attrs)

    assert Repo.aggregate(Example, :count) == 0
    assert Repo.aggregate(ExampleLink, :count) == 0
  end

  test "does not return archived public entries" do
    {:ok, language} = create_language()

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          definitions: [%{language: "english", text: "A clear liquid."}]
        },
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    entry
    |> Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert Archive.get_public_entry(entry.public_id) == nil
  end

  defp create_language do
    Archive.create_language(%{
      slug: "english",
      code: "en",
      name: "English",
      direction: :ltr
    })
  end

  defp publish_meaning(language, label, form) do
    Archive.publish_new_meaning(language, %{
      concept: %{editorial_label: label},
      entry: %{
        definitions: [%{language: language.slug, text: label}]
      },
      forms: [%{text: form, kind: :spelling, is_primary: true}]
    })
  end
end
