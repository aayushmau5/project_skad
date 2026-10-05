defmodule SkadWeb.InterfaceDesignTest do
  use SkadWeb.ConnCase

  alias Skad.Archive

  test "optional contribution details explain the original labels in both interface languages", %{
    conn: conn
  } do
    for {locale, summary, fields} <- [
          {"en", "Add usage or cultural context (optional)",
           [
             {"part_of_speech", "Part of speech",
              "For example: noun (a person or thing), verb (an action), or adjective (a description)."},
             {"usage_note", "Usage note", "When, where, or how people use this word."},
             {"cultural_note", "Cultural context",
              "Any story, custom, or local tradition connected to this word."}
           ]},
          {"hi", "प्रयोग या सांस्कृतिक संदर्भ जोड़ें (वैकल्पिक)",
           [
             {"part_of_speech", "शब्द का प्रकार",
              "उदाहरण: संज्ञा (व्यक्ति या चीज़ का नाम), क्रिया (कोई काम), या विशेषण (कोई गुण)।"},
             {"usage_note", "यह शब्द कैसे इस्तेमाल होता है", "लोग इस शब्द का इस्तेमाल कब, कहाँ या कैसे करते हैं।"},
             {"cultural_note", "सांस्कृतिक संदर्भ", "इस शब्द से जुड़ी कोई कहानी, रिवाज़ या स्थानीय परंपरा।"}
           ]}
        ] do
      document =
        conn
        |> get(~p"/contribute?ui_language=#{locale}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "#contribution-optional-details summary")) ==
               summary

      for {field, label, description} <- fields do
        id = "contribution_#{field}"
        assert LazyHTML.text(LazyHTML.query(document, "label[for=#{id}] .label")) == label

        assert LazyHTML.attribute(LazyHTML.query_by_id(document, id), "aria-describedby") ==
                 ["#{id}-description"]

        assert document
               |> LazyHTML.query_by_id("#{id}-description")
               |> LazyHTML.text()
               |> String.trim() == description

        assert Enum.count(LazyHTML.query(document, "##{id}-description + ##{id}")) == 1
      end
    end
  end

  test "public language names follow the interface language in search and contribution", %{
    conn: conn
  } do
    names = [
      {"hindi", "Hindi", "हिंदी"},
      {"hamskad", "Hamskad", "हमस्कद"},
      {"navaskad", "Navaskad", "नवस्कद"},
      {"pahari-kinnauri", "Pahari Kinnauri", "पहाड़ी किन्नौरी"},
      {"other", "Other language", "Other language"}
    ]

    for {slug, name, _hindi_name} <- names do
      {:ok, _language} =
        Archive.create_language(%{slug: slug, name: name, direction: :ltr})
    end

    for path <- [~p"/", ~p"/contribute"] do
      document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
      prefix = if path == ~p"/", do: "language", else: "contribution_language_slug"

      for {slug, _name, hindi_name} <- names do
        assert LazyHTML.text(LazyHTML.query(document, "##{prefix}_#{slug} + span")) == hindi_name
      end
    end

    english =
      conn |> get(~p"/?ui_language=en") |> html_response(200) |> LazyHTML.from_document()

    for {slug, name, _hindi_name} <- names do
      assert LazyHTML.text(LazyHTML.query(english, "#language_#{slug} + span")) == name
    end
  end

  test "starts public pages in Hindi and remembers a device's English choice", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.attribute(LazyHTML.query(document, "html"), "lang") == ["hi"]
    assert LazyHTML.text(LazyHTML.query_by_id(document, "search-submit")) == "खोजें"
    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "home-link"), "href") == [~p"/"]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "header-contribute-link"), "href") ==
             [~p"/contribute"]

    assert Enum.count(LazyHTML.query(document, "#archive-search .search-fields #q")) == 1

    assert Enum.count(
             LazyHTML.query(document, "#archive-search .search-fields fieldset#language")
           ) == 1

    assert LazyHTML.attribute(LazyHTML.query(document, "#language_all"), "checked") == [""]
    assert Enum.count(LazyHTML.query(document, "#archive-search[data-live-search]")) == 1

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "archive-search"),
             "data-results-url"
           ) ==
             [~p"/search/results"]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "search-status"), "role") ==
             ["status"]

    assert Enum.count(LazyHTML.query(document, "#site-footer #search-contribution")) == 1

    assert Enum.count(
             LazyHTML.query(document, "#site-footer .footer-primary #search-contribution")
           ) == 1

    assert Enum.count(LazyHTML.query(document, "#site-footer .footer-meta #creator-credit")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#main-content #search-contribution"))
    assert Enum.count(LazyHTML.query(document, "#site-footer #suggest-new-word")) == 1

    assert LazyHTML.text(LazyHTML.query_by_id(document, "creator-credit")) ==
             "zed.tells ने बनाया"

    assert Enum.count(LazyHTML.query(document, "#site-footer #archive-entry-count")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#main-content #archive-entry-count"))

    assert LazyHTML.text(LazyHTML.query_by_id(document, "archive-entry-count")) =~
             "सभी भाषाओं में"

    assert LazyHTML.text(LazyHTML.query(document, "#archive-entry-count strong")) ==
             "0 प्रविष्टियाँ"

    assert LazyHTML.text(LazyHTML.query_by_id(document, "home-link")) == "मुख्य पृष्ठ"
    assert LazyHTML.text(LazyHTML.query_by_id(document, "header-contribute-link")) == "योगदान दें"

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "language-hi"), "aria-current") == [
             "true"
           ]

    assert LazyHTML.attribute(LazyHTML.query_by_id(document, "skip-to-content"), "href") == [
             "#main-content"
           ]

    conn = get(recycle(conn), ~p"/?ui_language=en")
    assert conn.resp_cookies["skad_interface_language"].max_age == 31_536_000

    english = conn |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.text(LazyHTML.query_by_id(english, "creator-credit")) == "Made by zed.tells"
    assert LazyHTML.text(LazyHTML.query(english, "#archive-entry-count strong")) == "0 entries"

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
    assert Enum.count(LazyHTML.query(document, "#site-footer #search-contribution")) == 1
    assert LazyHTML.attribute(LazyHTML.query(document, "#language_hindi"), "checked") == [""]

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
          "definition" => String.duplicate("a", 2_001),
          "part_of_speech" => String.duplicate("a", 101)
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
             LazyHTML.query_by_id(document, "contribution_language_slug_hindi"),
             "checked"
           ) == [""]

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
             LazyHTML.query_by_id(document, "contribution-optional-details"),
             "open"
           ) == [""]

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_part_of_speech"),
             "aria-describedby"
           ) == ["contribution_part_of_speech-description contribution_part_of_speech-errors"]

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

    assert Enum.count(LazyHTML.query_by_id(document, "media_context_place_label")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(document, "media_context_variety_label"))

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
