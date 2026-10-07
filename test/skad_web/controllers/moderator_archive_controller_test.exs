defmodule SkadWeb.ModeratorArchiveControllerTest do
  use SkadWeb.ConnCase
  import Skad.ModerationFixtures

  alias Skad.Archive
  alias Skad.Archive.{Entry, Example}
  alias Skad.Contributions.Revision
  alias Skad.Media.Item
  alias Skad.Repo

  setup do
    records()
  end

  test "requires authentication for viewing, editing and deleting", %{
    conn: conn,
    water: water,
    example: example
  } do
    assert redirected_to(get(conn, ~p"/moderator/words")) == ~p"/moderator/log-in"

    for path <- [
          ~p"/moderator/entries/#{water.public_id}",
          ~p"/moderator/examples/#{example.public_id}"
        ] do
      assert redirected_to(get(conn, path)) == ~p"/moderator/log-in"
      assert redirected_to(patch(conn, path, %{})) == ~p"/moderator/log-in"
      assert redirected_to(delete(conn, path, %{})) == ~p"/moderator/log-in"
    end

    assert Repo.aggregate(Revision, :count) == 0
  end

  test "opens word editing from its concept and preserves all meanings", %{
    conn: conn,
    moderator: moderator,
    water: water,
    example: example
  } do
    conn = log_in(conn, moderator)
    concept = conn |> get(~p"/moderator/concepts/#{water.concept.public_id}") |> document(200)

    assert LazyHTML.query(concept, ~s(a[href="/moderator/entries/#{water.public_id}"]))
           |> Enum.count() == 1

    word = conn |> get(~p"/moderator/entries/#{water.public_id}") |> document(200)
    assert Enum.count(LazyHTML.query_by_id(word, "edit-word-form")) == 1
    assert Enum.count(LazyHTML.query_by_id(word, "meaning-1")) == 1
    assert value(word, "entry_primary_form") == "Water"

    assert value(word, "edit-example-#{example.public_id}", "href") ==
             ~p"/moderator/examples/#{example.public_id}"

    attrs = %{
      "primary_form" => "Fresh water",
      "usage_note" => "For guests.",
      "definitions" => %{
        "0" => %{"language" => "english", "text" => "Edited meaning."},
        "1" => %{"language" => "hindi", "text" => "पानी"}
      }
    }

    preview =
      conn
      |> patch(~p"/moderator/entries/#{water.public_id}", %{
        "entry" => attrs,
        "intent" => "add_meaning"
      })
      |> document(200)

    assert Enum.count(LazyHTML.query_by_id(preview, "meaning-2")) == 1
    assert value(preview, "entry_primary_form") == "Fresh water"
    assert Repo.get!(Entry, water.id).usage_note == "For drinking."

    saved = patch(conn, ~p"/moderator/entries/#{water.public_id}", %{"entry" => attrs})
    assert redirected_to(saved) == ~p"/moderator/entries/#{water.public_id}"
    updated = Archive.get_public_entry(water.public_id)
    assert updated.definitions |> Enum.map(& &1.text) == ["Edited meaning.", "पानी"]
    assert updated.usage_note == "For guests."

    invalid =
      conn
      |> patch(~p"/moderator/entries/#{water.public_id}", %{
        "entry" => Map.put(attrs, "primary_form", "")
      })
      |> document(422)

    assert Enum.count(LazyHTML.query_by_id(invalid, "entry_primary_form-errors")) == 1
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "makes words directly accessible from the workspace and navigation", %{
    conn: conn,
    moderator: moderator,
    water: water
  } do
    conn = log_in(conn, moderator)
    home = conn |> get(~p"/moderator") |> document(200)
    assert value(home, "moderator-manage-words-link", "href") == ~p"/moderator/words"
    assert value(home, "moderator-words-link", "href") == ~p"/moderator/words"
    assert value(home, "moderator-concepts-nav-link", "href") == ~p"/moderator/concepts"

    words = conn |> get(~p"/moderator/words") |> document(200)
    assert Enum.count(LazyHTML.query_by_id(words, "word-search-form")) == 1

    assert value(words, "open-word-#{water.public_id}", "href") ==
             ~p"/moderator/entries/#{water.public_id}"

    editor = conn |> get(~p"/moderator/entries/#{water.public_id}") |> document(200)
    assert value(editor, "word-back-to-list", "href") == ~p"/moderator/words"

    assert value(editor, "word-concept-link", "href") ==
             ~p"/moderator/concepts/#{water.concept.public_id}"

    {:ok, hindi} =
      Archive.create_language(%{slug: "hindi", name: "Hindi", code: "hi", direction: :ltr})

    {:ok, equivalent} =
      Archive.publish_equivalent(water, hindi, %{
        entry: %{definitions: [%{language: "english", text: "A clear liquid."}]},
        forms: [%{text: "पानी", kind: :spelling, is_primary: true}]
      })

    filtered =
      conn
      |> get(
        ~p"/moderator/words?#{%{search: %{query: "clear"}, language: "hindi", ui_language: "hi"}}"
      )
      |> document(200)

    assert Enum.count(LazyHTML.query_by_id(filtered, "moderator-word-#{equivalent.public_id}")) ==
             1

    assert Enum.count(LazyHTML.query_by_id(filtered, "moderator-word-#{water.public_id}")) == 0
    assert value(filtered, "word-filter-hindi", "aria-current") == "true"
    assert value(filtered, "word-search-language") == "hindi"
    assert value(filtered, "word-search-locale") == "hi"
    assert LazyHTML.text(LazyHTML.query_by_id(filtered, "moderator-words-link")) == "शब्द"

    assert value(filtered, "word-filter-all", "href")
           |> URI.parse()
           |> Map.fetch!(:query)
           |> URI.decode_query()
           |> Map.get("search[query]") == "clear"
  end

  test "paginates every matching word and excludes deleted records", %{
    conn: conn,
    moderator: moderator,
    water: water,
    scope: scope
  } do
    entries =
      for number <- 1..22 do
        {:ok, entry} =
          Archive.publish_new_meaning(water.language, %{
            concept: %{editorial_label: "WORD #{number}"},
            entry: %{definitions: [%{language: "english", text: "Sharedneedle meaning."}]},
            forms: [%{text: "Word #{number}", kind: :spelling, is_primary: true}]
          })

        entry
      end

    conn = log_in(conn, moderator)
    params = %{search: %{query: "sharedneedle"}, language: "english", ui_language: "en"}
    first = conn |> get(~p"/moderator/words?#{params}") |> document(200)
    assert Enum.count(LazyHTML.query(first, "#word-search-results > li")) == 20
    next_path = value(first, "word-next", "href")

    assert next_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() == %{
             "search[query]" => "sharedneedle",
             "language" => "english",
             "ui_language" => "en",
             "page" => "2"
           }

    second = conn |> get(next_path) |> document(200)
    assert Enum.count(LazyHTML.query(second, "#word-search-results > li")) == 2
    assert value(second, "word-next", "aria-disabled") == "true"
    assert {:ok, _} = Skad.Moderation.delete_entry(scope, hd(entries), deletion())
    words = conn |> get(~p"/moderator/words?#{params}") |> document(200)
    assert Enum.count(LazyHTML.query_by_id(words, "moderator-word-#{hd(entries).public_id}")) == 0
    second = conn |> get(next_path) |> document(200)
    assert Enum.count(LazyHTML.query(second, "#word-search-results > li")) == 1

    empty =
      conn |> get(~p"/moderator/words?#{%{search: %{query: "missingword"}}}") |> document(200)

    assert Enum.count(LazyHTML.query_by_id(empty, "empty-word-search")) == 1
    assert Enum.count(LazyHTML.query_by_id(empty, "clear-word-search")) == 1
  end

  test "Remove updates the meaning form and preserves edits until Save word", %{
    conn: conn,
    moderator: moderator,
    water: water
  } do
    attrs = %{
      "primary_form" => "Fresh water",
      "usage_note" => "For guests.",
      "definitions" => %{
        "0" => %{"language" => "english", "text" => "A clear liquid."},
        "1" => %{"language" => "hindi", "text" => "पीने का पानी"}
      }
    }

    conn = log_in(conn, moderator)

    preview =
      conn
      |> patch(~p"/moderator/entries/#{water.public_id}", %{
        "entry" => attrs,
        "remove_meaning" => "0"
      })
      |> document(200)

    assert Enum.count(LazyHTML.query_by_id(preview, "meaning-1")) == 0
    assert value(preview, "entry_definitions_0_language") == "hindi"
    assert LazyHTML.text(LazyHTML.query_by_id(preview, "entry_definitions_0_text")) == "पीने का पानी"
    assert value(preview, "entry_primary_form") == "Fresh water"
    assert LazyHTML.text(LazyHTML.query_by_id(preview, "entry_usage_note")) == "For guests."
    assert value(preview, "remove-meaning-0", "type") == "submit"
    assert value(preview, "remove-meaning-0", "disabled") != nil
    assert length(Archive.get_public_entry(water.public_id).definitions) == 2
    assert Repo.get!(Entry, water.id).usage_note == "For drinking."
    assert Repo.aggregate(Revision, :count) == 0

    attrs = Map.put(attrs, "definitions", %{"0" => attrs["definitions"]["1"]})

    assert redirected_to(
             conn
             |> patch(~p"/moderator/entries/#{water.public_id}", %{"entry" => attrs})
           ) == ~p"/moderator/entries/#{water.public_id}"

    assert Archive.get_public_entry(water.public_id).definitions |> Enum.map(& &1.language) == [
             "hindi"
           ]

    assert Repo.get!(Entry, water.id).usage_note == "For guests."
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "Remove updates translations without losing reviewed word links", %{
    conn: conn,
    moderator: moderator,
    water: water,
    drink: drink,
    example: example
  } do
    conn = log_in(conn, moderator)
    editor = conn |> get(~p"/moderator/examples/#{example.public_id}") |> document(200)

    attrs = %{
      "text" => example.text,
      "translations" => %{"0" => %{"language" => "hindi", "text" => "पानी पिएँ।"}}
    }

    links = %{
      "0" => %{
        "entry_public_id" => drink.public_id,
        "start_offset" => "0",
        "end_offset" => "5",
        "role" => "reference"
      },
      "1" => %{
        "entry_public_id" => water.public_id,
        "start_offset" => "6",
        "end_offset" => "11",
        "role" => "focus"
      }
    }

    params = %{
      "example" => attrs,
      "links_version" => value(editor, "example-links-version"),
      "links" => links,
      "remove_translation" => "0"
    }

    preview = conn |> patch(~p"/moderator/examples/#{example.public_id}", params) |> document(200)
    assert Enum.count(LazyHTML.query_by_id(preview, "translation-0")) == 0
    assert value(preview, "empty-example-translations", "name") == "example[translations]"

    assert LazyHTML.attribute(LazyHTML.query(preview, "#link-0-role option[selected]"), "value") ==
             ["reference"]

    assert length(Archive.get_example(example.public_id).translations) == 1
    assert Repo.aggregate(Revision, :count) == 0

    params =
      params
      |> Map.delete("remove_translation")
      |> Map.put("example", Map.put(attrs, "translations", ""))

    assert redirected_to(patch(conn, ~p"/moderator/examples/#{example.public_id}", params)) ==
             ~p"/moderator/examples/#{example.public_id}"

    assert Archive.get_example(example.public_id).translations == []
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "translation selectors name existing language codes and distinguish the sentence language",
       %{
         conn: conn,
         moderator: moderator,
         example: example
       } do
    {:ok, _} = Archive.create_language(%{slug: "hamskad", name: "Hamskad", direction: :ltr})

    example
    |> Skad.Moderation.change_example(%{
      "translations" => [
        %{"language" => "en", "text" => "Drink water."},
        %{"language" => "hi", "text" => "पानी पिएँ।"}
      ]
    })
    |> Repo.update!()

    editor =
      conn
      |> log_in(moderator)
      |> get(~p"/moderator/examples/#{example.public_id}?ui_language=hi")
      |> document(200)

    assert LazyHTML.text(LazyHTML.query(editor, "label[for=example_text] .label")) ==
             "उदाहरण वाक्य (अंग्रेज़ी)"

    assert value(editor, "example_text", "lang") == "en"

    assert LazyHTML.text(
             LazyHTML.query(editor, "#example_translations_0_language option[selected]")
           ) ==
             "अंग्रेज़ी"

    assert LazyHTML.attribute(
             LazyHTML.query(editor, "#example_translations_0_language option[selected]"),
             "value"
           ) == ["en"]

    assert LazyHTML.text(
             LazyHTML.query(editor, "#example_translations_1_language option[selected]")
           ) ==
             "हिंदी"

    assert LazyHTML.text(
             LazyHTML.query(editor, "#example_translations_0_language option[value=hamskad]")
           ) == "हमस्कद"

    assert Repo.aggregate(Revision, :count) == 0
  end

  test "adding a translation requires a language choice independent of the interface language", %{
    conn: conn,
    moderator: moderator,
    water: water,
    drink: drink,
    example: example
  } do
    {:ok, _} = Archive.create_language(%{slug: "hamskad", name: "Hamskad", direction: :ltr})
    conn = log_in(conn, moderator)
    path = ~p"/moderator/examples/#{example.public_id}"
    editor = conn |> get(path) |> document(200)

    attrs = %{
      "text" => example.text,
      "translations" => %{"0" => %{"language" => "hindi", "text" => "पानी पिएँ।"}}
    }

    links = %{
      "0" => %{
        "entry_public_id" => drink.public_id,
        "start_offset" => "0",
        "end_offset" => "5",
        "role" => "focus"
      },
      "1" => %{
        "entry_public_id" => water.public_id,
        "start_offset" => "6",
        "end_offset" => "11",
        "role" => "focus"
      }
    }

    params = %{
      "example" => attrs,
      "links_version" => value(editor, "example-links-version"),
      "links" => links
    }

    preview =
      conn
      |> patch(path <> "?ui_language=hi", Map.put(params, "intent", "add_translation"))
      |> document(200)

    assert LazyHTML.query(preview, "#example_translations_1_language option[selected]")
           |> Enum.count() == 0

    assert LazyHTML.text(
             LazyHTML.query(preview, "#example_translations_1_language option[value='']")
           ) == "भाषा चुनें"

    assert Enum.count(
             LazyHTML.query(preview, "#example_translations_1_language option[value=hamskad]")
           ) == 1

    translations =
      Map.put(attrs["translations"], "1", %{"language" => "", "text" => "Translation draft"})

    params = Map.put(params, "example", Map.put(attrs, "translations", translations))
    invalid = conn |> patch(path, params) |> document(422)

    assert Enum.count(LazyHTML.query_by_id(invalid, "example_translations_1_language-errors")) ==
             1

    assert length(Archive.get_example(example.public_id).translations) == 1
    assert Repo.aggregate(Revision, :count) == 0

    translations = put_in(translations, ["1", "language"], "hamskad")
    params = Map.put(params, "example", Map.put(attrs, "translations", translations))
    assert redirected_to(patch(conn, path, params)) == path

    updated = Archive.get_example(example.public_id)
    assert Enum.map(updated.translations, & &1.language) == ["hindi", "hamskad"]
    assert updated.language_id == example.language_id
    assert updated.text == example.text

    assert Enum.map(updated.links, & &1.entry_id) |> Enum.sort() ==
             Enum.sort([water.id, drink.id])

    assert Repo.aggregate(Revision, :count) == 1
  end

  test "requires sentence links to be reviewed and saves shared examples", %{
    conn: conn,
    moderator: moderator,
    water: water,
    drink: drink,
    example: example
  } do
    conn = log_in(conn, moderator)
    editor = conn |> get(~p"/moderator/examples/#{example.public_id}") |> document(200)
    assert Enum.count(LazyHTML.query_by_id(editor, "edit-example-form")) == 1

    attrs = %{
      "text" => "Please drink water.",
      "translations" => %{"0" => %{"language" => "hindi", "text" => "कृपया पानी पिएँ।"}}
    }

    preview =
      conn
      |> patch(~p"/moderator/examples/#{example.public_id}", %{
        "example" => attrs,
        "links_version" => value(editor, "example-links-version")
      })
      |> document(200)

    assert Repo.get!(Example, example.id).text == "Drink water."
    assert Enum.count(LazyHTML.query_by_id(preview, "example-word-link-0")) == 1
    assert Enum.count(LazyHTML.query_by_id(preview, "example-word-link-1")) == 1

    links = %{
      "0" => %{
        "entry_public_id" => drink.public_id,
        "start_offset" => "7",
        "end_offset" => "12",
        "role" => "focus"
      },
      "1" => %{
        "entry_public_id" => water.public_id,
        "start_offset" => "13",
        "end_offset" => "18",
        "role" => "focus"
      }
    }

    saved =
      patch(conn, ~p"/moderator/examples/#{example.public_id}", %{
        "example" => attrs,
        "links_version" => value(preview, "example-links-version"),
        "links" => links
      })

    assert redirected_to(saved) == ~p"/moderator/examples/#{example.public_id}"

    assert Archive.get_example(example.public_id).translations |> hd() |> Map.fetch!(:text) ==
             "कृपया पानी पिएँ।"

    assert Enum.sort(Enum.map(Archive.search("please"), & &1.entry.id)) ==
             Enum.sort([water.id, drink.id])

    invalid =
      patch(conn, ~p"/moderator/examples/#{example.public_id}", %{
        "example" => attrs,
        "links_version" => value(preview, "example-links-version"),
        "links" => %{}
      })

    assert Enum.count(LazyHTML.query_by_id(document(invalid, 422), "edit-example-form")) == 1
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "requires confirmation for deletion and keeps surviving word pages readable", %{
    conn: conn,
    moderator: moderator,
    water: water,
    drink: drink,
    example: example
  } do
    conn = log_in(conn, moderator)

    invalid =
      conn
      |> delete(~p"/moderator/entries/#{water.public_id}", %{
        "deletion" => %{"reason" => "", "confirmed" => "false"}
      })
      |> document(422)

    assert value(invalid, "delete-word-confirmation", "open") != nil
    assert Enum.count(LazyHTML.query_by_id(invalid, "delete-word_reason-errors")) == 1
    assert Archive.get_public_entry(water.public_id)
    deleted = delete(conn, ~p"/moderator/entries/#{water.public_id}", %{"deletion" => deletion()})
    assert redirected_to(deleted) == ~p"/moderator/words"
    assert conn |> get(~p"/entries/#{water.public_id}") |> response(404)

    assert conn
           |> get(~p"/entries/#{drink.public_id}")
           |> document(200)
           |> LazyHTML.query_by_id("entry-examples")
           |> Enum.count() == 1

    deleted =
      delete(conn, ~p"/moderator/examples/#{example.public_id}", %{"deletion" => deletion()})

    assert redirected_to(deleted) == ~p"/moderator/entries/#{drink.public_id}"
    assert Archive.get_example(example.public_id) == nil
    assert Archive.get_public_entry(drink.public_id).example_links == []
  end

  test "protects ownership of alternate forms and recordings", %{
    conn: conn,
    moderator: moderator,
    water: water,
    drink: drink
  } do
    conn = log_in(conn, moderator)
    alternate = Enum.find(water.forms, &(not &1.is_primary))

    audio =
      Repo.insert!(%Item{
        kind: :audio,
        original_object_key: "quarantine/editor.mp3",
        public_object_key: "public/editor.mp3",
        mime_type: "audio/mpeg",
        byte_size: 100,
        sha256: String.duplicate("b", 64),
        processing_state: :ready,
        visibility: :public,
        entry_id: water.id
      })

    path = ~p"/moderator/entries/#{drink.public_id}/media/#{audio.public_id}"

    assert response(
             patch(conn, path, %{
               "media" => %{"attribution_text" => "Wrong owner"},
               "owner" => "concept"
             }),
             404
           )

    assert response(delete(conn, path, %{"deletion" => deletion()}), 404)

    patch(conn, ~p"/moderator/entries/#{drink.public_id}/forms/#{alternate.id}", %{
      "word_form" => %{"text" => "Wrong owner"}
    })

    assert Repo.aggregate(Revision, :count) == 0

    assert Enum.count(
             LazyHTML.query_by_id(
               conn |> get(~p"/moderator/entries/#{water.public_id}") |> document(200),
               "media-#{audio.public_id}"
             )
           ) == 1
  end

  defp document(conn, status), do: conn |> html_response(status) |> LazyHTML.from_document()

  defp value(document, id, attribute \\ "value"),
    do: document |> LazyHTML.query_by_id(id) |> LazyHTML.attribute(attribute) |> List.first()
end
