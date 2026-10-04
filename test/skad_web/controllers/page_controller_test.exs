defmodule SkadWeb.PageControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Archive
  alias Skad.Media

  test "searches the archive and opens an entry from the real database", %{conn: conn} do
    {:ok, english} = create_language("english", "en", "English")
    {:ok, hindi} = create_language("hindi", "hi", "Hindi")

    {:ok, water} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          part_of_speech: "noun",
          definitions: [%{language: "english", text: "A clear liquid used for drinking."}]
        },
        forms: [
          %{text: "Water", kind: :spelling, is_primary: true},
          %{text: "H₂O", kind: :alias, is_primary: false}
        ]
      })

    {:ok, hindi_water} =
      Archive.publish_equivalent(water, hindi, %{
        entry: %{definitions: [%{language: "hindi", text: "पीने के लिए तरल।"}]},
        forms: [%{text: "पानी", kind: :spelling, is_primary: true}]
      })

    {:ok, example} =
      Archive.publish_usage_example(english, %{
        example: %{
          text: "Drink water.",
          translations: [%{language: "hindi", text: "पानी पियो।"}]
        },
        links: [
          %{
            entry_public_id: water.public_id,
            start_offset: 6,
            end_offset: 11,
            role: :focus
          }
        ]
      })

    {:ok, audio} = Media.create_item(water, media_attrs(:audio))
    {:ok, image} = Media.create_item(water.concept, media_attrs(:image))
    publish_media(audio)
    publish_media(image)

    conn = get(conn, ~p"/?q=clear+liquid&language=english")
    document = conn |> html_response(200) |> LazyHTML.from_document()
    result = LazyHTML.query_by_id(document, "search-result-#{water.public_id}")

    assert LazyHTML.text(LazyHTML.query_by_id(document, "archive-entry-count")) =~ "2"
    assert Enum.count(result) == 1
    assert LazyHTML.text(result) =~ "Water"

    assert LazyHTML.attribute(LazyHTML.query(result, "a"), "href") == [
             ~p"/entries/#{water.public_id}"
           ]

    assert Enum.empty?(LazyHTML.query_by_id(document, "search-result-#{hindi_water.public_id}"))

    fragment_conn =
      conn
      |> recycle()
      |> get(~p"/search/results?q=drink+water&language=english")

    fragment = fragment_conn |> html_response(200) |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query_by_id(fragment, "search-result-#{water.public_id}")) == 1
    assert Enum.empty?(LazyHTML.query(fragment, "html"))

    example_match = LazyHTML.query(fragment, "#search-result-#{water.public_id} .result-match")
    assert LazyHTML.text(example_match) =~ "उदाहरण में मिला:"
    assert LazyHTML.text(example_match) =~ "Drink water."
    assert LazyHTML.attribute(LazyHTML.query(example_match, "span"), "lang") == ["en"]

    filtered_fragment =
      conn
      |> recycle()
      |> get(~p"/search/results?q=drink+water&language=hindi")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert Enum.count(
             LazyHTML.query_by_id(filtered_fragment, "search-result-#{hindi_water.public_id}")
           ) == 1

    assert Enum.empty?(
             LazyHTML.query_by_id(filtered_fragment, "search-result-#{water.public_id}")
           )

    conn = get(recycle(conn), ~p"/entries/#{water.public_id}")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert String.trim(LazyHTML.text(LazyHTML.query_by_id(document, "entry-title"))) == "Water"

    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-definitions")) =~
             "A clear liquid used for drinking."

    assert LazyHTML.attribute(LazyHTML.query(document, "#entry-definitions p"), "lang") == ["en"]

    assert LazyHTML.attribute(LazyHTML.query(document, "#entry-definitions p"), "data-language") ==
             ["english"]

    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-forms")) =~ "H₂O"

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#equivalent-entry-#{hindi_water.public_id} a"),
             "href"
           ) == [~p"/entries/#{hindi_water.public_id}"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#equivalent-entry-#{hindi_water.public_id} span"),
             "lang"
           ) == ["hi"]

    assert LazyHTML.text(
             LazyHTML.query_by_id(document, "equivalent-entry-#{hindi_water.public_id}")
           ) =~
             "हिंदी"

    assert LazyHTML.text(LazyHTML.query_by_id(document, "example-#{example.public_id}")) =~
             "Drink water."

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(
               document,
               "example-link-#{example.public_id}-#{hd(example.links).id}"
             ),
             "href"
           ) == [~p"/entries/#{water.public_id}"]

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "entry-audio-#{audio.public_id}"),
             "src"
           ) == [~p"/media/#{audio.public_id}"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#entry-image-#{image.public_id} img"),
             "src"
           ) == [~p"/media/#{image.public_id}"]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "suggest-entry-correction"), "href") ==
             [
               ~p"/entries/#{water.public_id}/correct"
             ]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "suggest-entry-addition"), "href") ==
             [
               ~p"/entries/#{water.public_id}/add"
             ]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "suggest-entry-example"), "href") ==
             [~p"/entries/#{water.public_id}/examples/new"]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "suggest-entry-audio"), "href") ==
             [~p"/entries/#{water.public_id}/audio/new"]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "suggest-entry-images"), "href") ==
             [~p"/entries/#{water.public_id}/images/new"]
  end

  test "returns not found for an unknown public entry", %{conn: conn} do
    conn = get(conn, ~p"/entries/00000000-0000-4000-8000-000000000000")
    document = conn |> html_response(404) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query_by_id(document, "archive-not-found")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "not-found-search")) == 1
  end

  test "live results keep the selected archive language and offer a full-page fallback", %{
    conn: conn
  } do
    {:ok, english} = create_language("english", "en", "English")
    {:ok, hindi} = create_language("hindi", "hi", "Hindi")

    {:ok, english_entry} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "HYDRATION"},
        entry: %{definitions: [%{language: "en", text: "Water"}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    {:ok, hindi_entry} =
      Archive.publish_equivalent(english_entry, hindi, %{
        entry: %{definitions: [%{language: "hi", text: "पानी"}]},
        forms: [%{text: "पानी", kind: :spelling, is_primary: true}]
      })

    path = ~p"/search/results?q=water&language=hindi&ui_language=en"
    fragment = conn |> get(path) |> html_response(200) |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(fragment, "search-results"),
             "data-result-count"
           ) ==
             ["1"]

    assert Enum.count(LazyHTML.query_by_id(fragment, "search-result-#{hindi_entry.public_id}")) ==
             1

    assert Enum.empty?(LazyHTML.query_by_id(fragment, "search-result-#{english_entry.public_id}"))

    assert LazyHTML.text(LazyHTML.query_by_id(fragment, "search-result-#{hindi_entry.public_id}")) =~
             "Related meaning"

    assert LazyHTML.attribute(
             LazyHTML.query(fragment, "#search-result-#{hindi_entry.public_id} .result-link"),
             "lang"
           ) == ["hi"]

    hindi_fragment =
      conn
      |> recycle()
      |> get(~p"/search/results?q=water&language=hindi")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert LazyHTML.text(
             LazyHTML.query_by_id(hindi_fragment, "search-result-#{hindi_entry.public_id}")
           ) =~
             "संबंधित अर्थ"

    assert LazyHTML.text(
             LazyHTML.query(
               hindi_fragment,
               "#search-result-#{hindi_entry.public_id} .result-meta"
             )
           ) =~ "हिंदी"

    full_page =
      conn
      |> recycle()
      |> get(~p"/?q=water&language=hindi&ui_language=en")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(full_page, "search-result-#{hindi_entry.public_id}")) ==
             1

    assert conn |> recycle() |> get(~p"/search/results") |> response(204) == ""
  end

  test "home total excludes archived entries and archived concepts", %{conn: conn} do
    {:ok, english} = create_language("english", "en", "English")

    {:ok, entry} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: "en", text: "Water"}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.text(LazyHTML.query_by_id(document, "archive-entry-count")) =~
             "सभी भाषाओं में:"

    assert LazyHTML.text(LazyHTML.query(document, "#archive-entry-count strong")) ==
             "1 प्रविष्टि"

    entry
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Skad.Repo.update!()

    document = conn |> recycle() |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.text(LazyHTML.query_by_id(document, "archive-entry-count")) =~ "0"

    {:ok, second_entry} =
      Archive.publish_new_meaning(english, %{
        concept: %{editorial_label: "RIVER"},
        entry: %{definitions: [%{language: "en", text: "River"}]},
        forms: [%{text: "River", kind: :spelling, is_primary: true}]
      })

    second_entry.concept
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Skad.Repo.update!()

    document = conn |> recycle() |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.text(LazyHTML.query_by_id(document, "archive-entry-count")) =~ "0"
  end

  defp create_language(slug, code, name) do
    Archive.create_language(%{slug: slug, code: code, name: name, direction: :ltr})
  end

  defp media_attrs(:audio) do
    %{
      kind: :audio,
      original_object_key: "private/audio/#{Ecto.UUID.generate()}",
      mime_type: "audio/webm",
      byte_size: 8_192,
      sha256: String.duplicate("a", 64)
    }
  end

  defp media_attrs(:image) do
    %{
      kind: :image,
      original_object_key: "private/images/#{Ecto.UUID.generate()}",
      mime_type: "image/jpeg",
      byte_size: 16_384,
      sha256: String.duplicate("b", 64)
    }
  end

  defp publish_media(item) do
    Media.update_item(item, %{
      processing_state: :ready,
      visibility: :public,
      public_object_key: "public/#{item.kind}/#{item.public_id}"
    })
  end
end
