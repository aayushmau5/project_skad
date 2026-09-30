defmodule SkadWeb.PageControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Archive

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

    conn = get(conn, ~p"/?q=clear+liquid&language=english")
    document = conn |> html_response(200) |> LazyHTML.from_document()
    result = LazyHTML.query_by_id(document, "search-result-#{water.public_id}")

    assert Enum.count(result) == 1
    assert LazyHTML.text(result) =~ "Water"

    assert LazyHTML.attribute(LazyHTML.query(result, "a"), "href") == [
             ~p"/entries/#{water.public_id}"
           ]

    assert Enum.empty?(LazyHTML.query_by_id(document, "search-result-#{hindi_water.public_id}"))

    conn = get(recycle(conn), ~p"/entries/#{water.public_id}")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-title")) == "Water"

    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-definitions")) =~
             "A clear liquid used for drinking."

    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-forms")) =~ "H₂O"
    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-equivalents")) =~ "पानी — Hindi"

    assert LazyHTML.text(LazyHTML.query_by_id(document, "example-#{example.public_id}")) =~
             "Drink water."
  end

  test "returns not found for an unknown public entry", %{conn: conn} do
    conn = get(conn, ~p"/entries/00000000-0000-4000-8000-000000000000")
    assert response(conn, 404) == "Entry not found"
  end

  defp create_language(slug, code, name) do
    Archive.create_language(%{slug: slug, code: code, name: name, direction: :ltr})
  end
end
