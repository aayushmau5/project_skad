defmodule SkadWeb.InterfaceDesignTest do
  use SkadWeb.ConnCase

  alias Skad.Archive

  test "starts public pages in Hindi and remembers a device's English choice", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.attribute(LazyHTML.query(document, "html"), "lang") == ["hi"]
    assert LazyHTML.text(LazyHTML.query_by_id(document, "search-submit")) == "खोजें"

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "language-hi"), "aria-current") == [
             "true"
           ]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "skip-to-content"), "href") == [
             "#main-content"
           ]

    conn = get(recycle(conn), ~p"/?ui_language=en")
    assert conn.resp_cookies["skad_interface_language"].max_age == 31_536_000

    document =
      conn |> recycle() |> get(~p"/contribute") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.query(document, "html"), "lang") == ["en"]

    assert String.trim(
             LazyHTML.text(LazyHTML.query_by_id(document, "new-entry-contribution-submit"))
           ) == "Send for review"
  end

  test "language switches preserve search and refinement; empty results invite contribution", %{
    conn: conn
  } do
    {:ok, _language} =
      Archive.create_language(%{slug: "hindi", code: "hi", name: "Hindi", direction: :ltr})

    document =
      conn
      |> get(~p"/?q=missing&language=hindi")
      |> html_response(200)
      |> LazyHTML.from_document()

    [switch] = LazyHTML.attribute(LazyHTML.query_by_id(document, "language-en"), "href")

    assert URI.decode_query(URI.parse(switch).query) == %{
             "q" => "missing",
             "language" => "hindi",
             "ui_language" => "en"
           }

    assert Enum.count(LazyHTML.query_by_id(document, "contribute-missing-word")) == 1

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "q"), "aria-describedby") == [
             "search-help"
           ]

    assert Enum.empty?(LazyHTML.query(document, "#site-header #moderator-login-link"))
  end

  test "validation preserves content and links Hindi errors to their inputs", %{conn: conn} do
    {:ok, _language} =
      Archive.create_language(%{slug: "hindi", code: "hi", name: "Hindi", direction: :ltr})

    document =
      conn
      |> post(~p"/contributions", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "language_slug" => "hindi",
          "primary_form" => "पानी",
          "definition" => String.duplicate("a", 2_001)
        },
        "media_context" => %{"place_label" => "Kalpa"}
      })
      |> html_response(422)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_primary_form"),
             "value"
           ) == ["पानी"]

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_definition"),
             "aria-invalid"
           ) == ["true"]

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_definition"),
             "aria-describedby"
           ) == ["contribution_definition-errors"]

    assert LazyHTML.text(LazyHTML.query_by_id(document, "contribution_definition-errors")) =~
             "2000"

    refute LazyHTML.text(LazyHTML.query_by_id(document, "contribution_definition-errors")) =~
             "should be"

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "media_context_place_label"),
             "value"
           ) == ["Kalpa"]
  end

  test "Hindi interface preserves archive language and direction on entry content", %{conn: conn} do
    {:ok, language} =
      Archive.create_language(%{slug: "arabic", code: "ar", name: "Arabic", direction: :rtl})

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: "en", text: "Water"}]},
        forms: [%{text: "ماء", kind: :spelling, is_primary: true}]
      })

    document =
      conn
      |> get(~p"/entries/#{entry.public_id}")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "entry-title"), "lang") == ["ar"]
    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "entry-title"), "dir") == ["rtl"]
    assert String.trim(LazyHTML.text(LazyHTML.query_by_id(document, "entry-title"))) == "ماء"
    assert LazyHTML.attribute(LazyHTML.query(document, "#entry-definitions p"), "lang") == ["en"]
    assert Enum.count(LazyHTML.query_by_id(document, "record-missing-pronunciation")) == 1
  end

  test "media enhancements have consent, visible labels, and a no-JavaScript explanation", %{
    conn: conn
  } do
    document = conn |> get(~p"/contribute") |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(
             LazyHTML.query(
               document,
               "#new-word-media-context label[for=media_context_permission]"
             )
           ) == 1

    assert Enum.count(LazyHTML.query(document, "#new-word-media-context noscript")) == 1
    assert Enum.count(LazyHTML.query(document, "#record-contribution-audio[hidden]")) == 1
    assert Enum.count(LazyHTML.query(document, "#contribution-audio-upload[disabled]")) == 1

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "contribution-media-status"), "role") ==
             ["status"]

    assert Enum.count(LazyHTML.query(document, "#contribution-confirm legend")) == 1
  end
end
