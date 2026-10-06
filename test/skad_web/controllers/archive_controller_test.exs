defmodule SkadWeb.ArchiveControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Archive
  alias Skad.Repo

  setup do
    {:ok, hamskad} =
      Archive.create_language(%{slug: "hamskad", name: "Hamskad", direction: :ltr})

    {:ok, skad} = Archive.create_language(%{slug: "skad", name: "Skad", direction: :ltr})
    %{hamskad: hamskad, skad: skad}
  end

  test "lists words with language pills and filters using the available languages", %{
    conn: conn,
    hamskad: hamskad,
    skad: skad
  } do
    apple = publish(hamskad, "Apple")
    zebra = publish(skad, "Zebra")

    {:ok, _inactive} =
      Archive.create_language(%{
        slug: "inactive",
        name: "Inactive",
        direction: :ltr,
        active: false
      })

    document = document(conn, ~p"/archive?ui_language=en")

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "header-archive-link"), "href") == [
             ~p"/archive"
           ]

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "archive-filter-all"),
             "aria-current"
           ) ==
             ["true"]

    assert Enum.count(LazyHTML.query(document, "#archive-words > li")) == 2
    assert Enum.count(LazyHTML.query(document, "#archive-words .archive-language-pill")) == 2
    assert LazyHTML.text(LazyHTML.query_by_id(document, "archive-word-count")) =~ "2 words"
    assert Enum.count(LazyHTML.query_by_id(document, "archive-filter-hamskad")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "archive-filter-skad")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(document, "archive-filter-inactive"))

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#archive-word-#{apple.public_id} .result-link"),
             "href"
           ) == [~p"/entries/#{apple.public_id}"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#archive-word-#{apple.public_id} p[lang]"),
             "lang"
           ) == ["en"]

    [filter_path] =
      LazyHTML.attribute(LazyHTML.query_by_id(document, "archive-filter-hamskad"), "href")

    filtered = document(conn, filter_path)
    assert Enum.count(LazyHTML.query_by_id(filtered, "archive-word-#{apple.public_id}")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(filtered, "archive-word-#{zebra.public_id}"))
    assert Enum.empty?(LazyHTML.query(filtered, "#archive-words .archive-language-pill"))

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(filtered, "archive-filter-hamskad"),
             "aria-current"
           ) == ["true"]
  end

  test "paginates alphabetically, preserves the filter, and resets it when switching languages",
       %{
         conn: conn,
         hamskad: hamskad,
         skad: skad
       } do
    for number <- 21..1//-1 do
      publish(hamskad, "Word #{String.pad_leading(to_string(number), 2, "0")}")
    end

    publish(skad, "Zulu")
    first = document(conn, ~p"/archive?language=hamskad&ui_language=en")
    assert Enum.count(LazyHTML.query(first, "#archive-words > li")) == 20

    assert LazyHTML.query(first, "#archive-words .result-link")
           |> Enum.map(&LazyHTML.text/1) ==
             Enum.map(1..20, &"Word #{String.pad_leading(to_string(&1), 2, "0")}")

    assert LazyHTML.attribute(LazyHTML.query_by_id(first, "archive-previous"), "aria-disabled") ==
             ["true"]

    [next_path] = LazyHTML.attribute(LazyHTML.query_by_id(first, "archive-next"), "href")

    assert URI.decode_query(URI.parse(next_path).query) == %{
             "language" => "hamskad",
             "page" => "2",
             "ui_language" => "en"
           }

    second = document(conn, next_path)
    assert LazyHTML.text(LazyHTML.query(second, "#archive-words .result-link")) == "Word 21"
    assert LazyHTML.text(LazyHTML.query_by_id(second, "archive-page-number")) =~ "Page 2 of 2"

    assert LazyHTML.attribute(LazyHTML.query_by_id(second, "archive-next"), "aria-disabled") == [
             "true"
           ]

    [previous_path] = LazyHTML.attribute(LazyHTML.query_by_id(second, "archive-previous"), "href")
    assert previous_path == ~p"/archive?language=hamskad&page=1&ui_language=en"

    [all_path] = LazyHTML.attribute(LazyHTML.query_by_id(second, "archive-filter-all"), "href")
    all = document(conn, all_path)
    assert LazyHTML.text(LazyHTML.query_by_id(all, "archive-page-number")) =~ "Page 1 of 2"
    assert LazyHTML.text(LazyHTML.query_by_id(all, "archive-word-count")) =~ "22 words"

    [switch] = LazyHTML.attribute(LazyHTML.query_by_id(second, "language-hi"), "href")
    hindi = document(conn, switch)
    assert LazyHTML.text(LazyHTML.query_by_id(hindi, "archive-page-number")) =~ "पृष्ठ 2 / 2"
    assert LazyHTML.text(LazyHTML.query_by_id(hindi, "archive-next")) =~ "अगला"

    for page <- ["0", "-1", "invalid", "2oops"] do
      invalid = document(conn, ~p"/archive?language=hamskad&page=#{page}&ui_language=en")
      assert LazyHTML.text(LazyHTML.query_by_id(invalid, "archive-page-number")) =~ "Page 1 of 2"
    end

    beyond_last = document(conn, ~p"/archive?language=hamskad&page=999999999999999999999")
    assert Enum.count(LazyHTML.query(beyond_last, "#archive-words > li")) == 1
  end

  test "excludes archived entries and concepts and keeps archive script and direction", %{
    conn: conn,
    hamskad: hamskad
  } do
    archived_entry = publish(hamskad, "Archived word")
    archived_concept = publish(hamskad, "Archived meaning")

    archived_entry
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    archived_concept.concept
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    {:ok, arabic} =
      Archive.create_language(%{slug: "arabic", code: "ar", name: "Arabic", direction: :rtl})

    word = publish(arabic, "ماء")
    document = document(conn, ~p"/archive")
    assert Enum.count(LazyHTML.query(document, "#archive-words > li")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(document, "archive-word-#{archived_entry.public_id}"))

    assert Enum.empty?(
             LazyHTML.query_by_id(document, "archive-word-#{archived_concept.public_id}")
           )

    link = LazyHTML.query(document, "#archive-word-#{word.public_id} .result-link")
    assert LazyHTML.text(link) == "ماء"
    assert LazyHTML.attribute(link, "lang") == ["ar"]
    assert LazyHTML.attribute(link, "dir") == ["rtl"]
  end

  test "empty states work in Hindi and English and an unknown language falls back to All", %{
    conn: conn,
    hamskad: hamskad
  } do
    hindi = document(conn, ~p"/archive")
    assert LazyHTML.text(LazyHTML.query_by_id(hindi, "archive-heading")) == "संग्रह"
    assert LazyHTML.text(LazyHTML.query_by_id(hindi, "archive-filter-all")) == "सभी"
    assert LazyHTML.text(LazyHTML.query_by_id(hindi, "archive-filter-hamskad")) == "हमस्कद"
    assert Enum.count(LazyHTML.query_by_id(hindi, "archive-empty")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(hindi, "archive-pagination"))

    assert LazyHTML.attribute(LazyHTML.query_by_id(hindi, "archive-suggest-word"), "href") == [
             ~p"/contribute"
           ]

    english = document(conn, ~p"/archive?language=hamskad&ui_language=en")
    assert LazyHTML.text(LazyHTML.query_by_id(english, "archive-heading")) == "Archive"
    assert Enum.count(LazyHTML.query_by_id(english, "archive-empty")) == 1

    word = publish(hamskad, "Word")
    unknown = document(conn, ~p"/archive?language=unknown&ui_language=en")
    assert Enum.count(LazyHTML.query_by_id(unknown, "archive-word-#{word.public_id}")) == 1

    assert LazyHTML.attribute(LazyHTML.query_by_id(unknown, "archive-filter-all"), "aria-current") ==
             ["true"]
  end

  defp document(conn, path) do
    conn |> recycle() |> get(path) |> html_response(200) |> LazyHTML.from_document()
  end

  defp publish(language, text) do
    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: text},
        entry: %{definitions: [%{language: "en", text: "Meaning of #{text}"}]},
        forms: [
          %{text: text, kind: :spelling, is_primary: true},
          %{text: "Alias for #{text}", kind: :alias, is_primary: false}
        ]
      })

    entry
  end
end
