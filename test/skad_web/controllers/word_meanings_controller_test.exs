defmodule SkadWeb.WordMeaningsControllerTest do
  use SkadWeb.ConnCase
  import Skad.ModerationFixtures

  alias Skad.Archive
  alias Skad.Contributions
  alias Skad.Contributions.Submission
  alias Skad.Repo

  setup do
    records()
  end

  test "keeps numbered meanings, examples, and supporting details visible", %{
    conn: conn,
    water: water,
    example: example
  } do
    second = second_meaning(water)
    page = document(conn, ~p"/entries/#{second.public_id}?ui_language=en")
    first_block = LazyHTML.query_by_id(page, "meaning-#{water.public_id}")
    second_block = LazyHTML.query_by_id(page, "meaning-#{second.public_id}")

    assert Enum.count(LazyHTML.query(page, "#entry-meanings > section")) == 2
    assert Enum.empty?(LazyHTML.query_by_id(page, "word-meaning-index"))
    assert Enum.empty?(LazyHTML.query(page, "#entry-meanings details"))

    assert Enum.count(LazyHTML.query(first_block, "#entry-pronunciation-#{water.public_id}")) == 1

    assert Enum.count(LazyHTML.query(first_block, "#suggest-entry-correction-#{water.public_id}")) ==
             1

    assert Enum.count(
             LazyHTML.query(
               first_block,
               "#entry-pronunciation-#{water.public_id} #record-missing-pronunciation-#{water.public_id}"
             )
           ) == 1

    assert Enum.empty?(LazyHTML.query(page, "[id^='entry-contributions'] a[href$='/audio/new']"))

    assert LazyHTML.attribute(
             LazyHTML.query(first_block, "#meaning-heading-#{water.public_id} a"),
             "href"
           ) == ["#meaning-#{water.public_id}"]

    assert LazyHTML.text(first_block) =~ "A clear liquid."
    assert LazyHTML.text(first_block) =~ "पानी"
    assert LazyHTML.text(second_block) =~ "A body of water."

    assert Enum.count(
             LazyHTML.query(first_block, "#example-#{example.public_id}-#{water.public_id}")
           ) == 1

    assert Enum.empty?(LazyHTML.query(second_block, "article"))
    assert LazyHTML.attribute(second_block, "data-selected") == ["true"]

    assert LazyHTML.attribute(LazyHTML.query_by_id(page, "suggest-another-meaning"), "href") == [
             ~p"/entries/#{second.public_id}/meanings/new"
           ]

    ids = page |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
    assert Enum.uniq(ids) == ids

    fragment =
      conn
      |> recycle()
      |> get(~p"/search/results?q=water&ui_language=en")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query_by_id(fragment, "search-result-#{water.public_id}")) == 1
    assert LazyHTML.text(LazyHTML.query(fragment, ".word-preview")) =~ "A body of water."

    assert LazyHTML.attribute(
             LazyHTML.query(fragment, "#search-result-#{water.public_id} .result-link"),
             "href"
           ) == [
             SkadWeb.PageHTML.meaning_path(water)
           ]

    archive = document(conn, ~p"/archive?ui_language=en")
    assert Enum.count(LazyHTML.query(archive, "#archive-words > li")) == 2
    assert LazyHTML.text(LazyHTML.query_by_id(archive, "archive-word-count")) =~ "2 words"
  end

  test "another meaning prefills the word and keeps the proposal private until approval", %{
    conn: conn,
    water: water,
    scope: scope,
    moderator: moderator
  } do
    form_page = document(conn, ~p"/entries/#{water.public_id}/meanings/new?ui_language=en")
    assert value(form_page, "contribution_primary_form") == "Water"
    assert value(form_page, "contribution_language_slug") == "english"
    assert value(form_page, "contribution_source_entry_public_id") == water.public_id
    assert Enum.count(LazyHTML.query_by_id(form_page, "new-meaning-context")) == 1
    assert Enum.count(LazyHTML.query_by_id(form_page, "contribution_definition_language")) == 1

    assert Enum.count(
             LazyHTML.query(form_page, "#contribution_definition_language option[value='']")
           ) == 1

    params = %{
      "client_submission_id" => value(form_page, "contribution_client_submission_id"),
      "source_entry_public_id" => water.public_id,
      "primary_form" => "Water",
      "language_slug" => "english",
      "definition_language" => "hindi",
      "definition" => "जलाशय"
    }

    submitted = conn |> recycle() |> post(~p"/contributions", %{"contribution" => params})
    assert redirected_to(submitted) =~ "/contributions/"
    assert length(Archive.get_public_word(water.public_id).meanings) == 1
    submission = Repo.one!(Submission)

    review =
      conn
      |> recycle()
      |> log_in(moderator)
      |> document(~p"/moderator/submissions/#{submission.public_id}")

    assert Enum.count(LazyHTML.query_by_id(review, "existing-meaning-#{water.public_id}")) == 1
    assert {:ok, %{entry: new_meaning}} = Contributions.approve_submission(scope, submission)
    assert new_meaning.concept_id != water.concept_id
    assert [%{language: "hindi", text: "जलाशय"}] = new_meaning.definitions
    assert length(Archive.get_public_word(water.public_id).meanings) == 2
  end

  test "Hindi labels distinguish a translated explanation from a new meaning", %{
    conn: conn,
    water: water,
    moderator: moderator
  } do
    page =
      conn
      |> log_in(moderator)
      |> document(~p"/moderator/entries/#{water.public_id}?ui_language=hi")

    assert LazyHTML.text(LazyHTML.query_by_id(page, "add-meaning")) == "अनुवाद जोड़ें"
    assert LazyHTML.text(LazyHTML.query_by_id(page, "moderator-add-new-meaning")) == "एक और अर्थ जोड़ें"
  end

  defp second_meaning(entry) do
    {:ok, second} =
      Archive.publish_new_meaning(entry.language, %{
        concept: %{editorial_label: "BODY OF WATER"},
        entry: %{
          definitions: [%{language: "english", text: "A body of water."}],
          place_label: "Village"
        },
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    second
  end

  defp document(conn, path),
    do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp value(document, id),
    do: document |> LazyHTML.query_by_id(id) |> LazyHTML.attribute("value") |> List.first()
end
