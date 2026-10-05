defmodule SkadWeb.ContributionControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Archive
  alias Skad.Contributions.Submission
  alias Skad.Media
  alias Skad.Repo

  test "renders a new-entry form with a stable client submission id", %{conn: conn} do
    create_language()

    document = conn |> get(~p"/contribute") |> html_response(200) |> LazyHTML.from_document()
    form = LazyHTML.query_by_id(document, "new-entry-contribution-form")

    assert Enum.count(form) == 1

    assert Enum.count(
             LazyHTML.query(form, "#contribution_language_slug input[type=radio][value=english]")
           ) == 1

    assert Enum.empty?(LazyHTML.query(form, "#contribution_language_slug input[value='']"))
    assert Enum.count(LazyHTML.query(form, "#contribution_example")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-media")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-audio-upload")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-image-uploads")) == 1

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution-image-uploads"),
             "multiple"
           ) == [""]

    [client_submission_id] =
      form
      |> LazyHTML.query("#contribution_client_submission_id")
      |> LazyHTML.attribute("value")

    assert {:ok, _client_submission_id} = Ecto.UUID.cast(client_submission_id)
  end

  test "language choices show an empty state and required errors", %{conn: conn} do
    document = conn |> get(~p"/contribute") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.text(LazyHTML.query_by_id(document, "contribution_language_slug")) =~
             "अभी चुनने के लिए कोई भाषा उपलब्ध नहीं है"

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "new-entry-contribution-submit"),
             "disabled"
           ) == [""]

    create_language()

    document =
      conn
      |> recycle()
      |> post(~p"/contributions", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "language_slug" => "",
          "primary_form" => "Water",
          "definition" => "A clear liquid."
        }
      })
      |> html_response(422)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_language_slug"),
             "aria-invalid"
           ) == ["true"]

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_language_slug_english"),
             "aria-describedby"
           ) == ["contribution_language_slug-errors"]

    assert Enum.count(LazyHTML.query_by_id(document, "contribution_language_slug-errors")) == 1
  end

  test "submits a proposal and renders its safe receipt", %{conn: conn} do
    create_language()
    client_submission_id = Ecto.UUID.generate()

    params = %{
      "client_submission_id" => client_submission_id,
      "language_slug" => "english",
      "primary_form" => "Water",
      "definition" => "Private proposed meaning",
      "example" => "Drink water."
    }

    conn = post(conn, ~p"/contributions", %{"contribution" => params})
    receipt_path = redirected_to(conn)
    assert String.starts_with?(receipt_path, "/contributions/")
    assert Repo.aggregate(Submission, :count) == 1
    assert Repo.one!(Submission).payload["example"] == "Drink water."

    conn = get(recycle(conn), receipt_path)
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "contribution-receipt")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-status")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-receipt-id")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(document, "contribution-definition"))

    retry_conn = post(recycle(conn), ~p"/contributions", %{"contribution" => params})
    assert redirected_to(retry_conn) == receipt_path
    assert Repo.aggregate(Submission, :count) == 1

    conflict_conn =
      post(recycle(retry_conn), ~p"/contributions", %{
        "contribution" => Map.put(params, "definition", "Different content")
      })

    conflict_document = conflict_conn |> html_response(409) |> LazyHTML.from_document()
    conflict_form = LazyHTML.query_by_id(conflict_document, "new-entry-contribution-form")

    refute LazyHTML.attribute(
             LazyHTML.query(conflict_form, "#contribution_client_submission_id"),
             "value"
           ) == [client_submission_id]

    assert Repo.aggregate(Submission, :count) == 1
  end

  test "preserves the idempotency key when validation fails", %{conn: conn} do
    client_submission_id = Ecto.UUID.generate()

    conn =
      post(conn, ~p"/contributions", %{
        "contribution" => %{
          "client_submission_id" => client_submission_id,
          "language_slug" => "missing",
          "primary_form" => "",
          "definition" => ""
        }
      })

    document = conn |> html_response(422) |> LazyHTML.from_document()
    form = LazyHTML.query_by_id(document, "new-entry-contribution-form")

    assert LazyHTML.attribute(
             LazyHTML.query(form, "#contribution_client_submission_id"),
             "value"
           ) == [client_submission_id]

    assert Repo.aggregate(Submission, :count) == 0
  end

  test "claims uploaded media when the contribution form is submitted", %{conn: conn} do
    create_language()
    {:ok, media} = Media.create_item(image_attrs())

    conn =
      post(conn, ~p"/contributions", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "language_slug" => "english",
          "primary_form" => "Water",
          "definition" => "A clear liquid.",
          "media_public_ids" => [media.public_id]
        }
      })

    assert String.starts_with?(redirected_to(conn), "/contributions/")
    submission = Repo.one!(Submission)
    assert Repo.get!(Skad.Media.Item, media.id).submission_id == submission.id
  end

  test "returns not found for an unknown receipt", %{conn: conn} do
    conn = get(conn, ~p"/contributions/#{Ecto.UUID.generate()}")
    document = conn |> html_response(404) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query_by_id(document, "archive-not-found")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "not-found-search")) == 1
  end

  test "submits a correction for an existing entry", %{conn: conn} do
    entry = create_entry()
    path = ~p"/entries/#{entry.public_id}/correct"

    document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
    form = LazyHTML.query_by_id(document, "entry-change-contribution-form")

    assert Enum.count(form) == 1

    assert LazyHTML.attribute(LazyHTML.query(form, "#contribution_primary_form"), "value") == [
             "Water"
           ]

    assert LazyHTML.text(LazyHTML.query(form, "label[for=contribution_part_of_speech] .label")) ==
             "शब्द का प्रकार"

    assert form
           |> LazyHTML.query_by_id("contribution_part_of_speech-description")
           |> LazyHTML.text()
           |> String.trim() ==
             "उदाहरण: संज्ञा (व्यक्ति या चीज़ का नाम), क्रिया (कोई काम), या विशेषण (कोई गुण)।"

    conn =
      post(recycle(conn), ~p"/entries/#{entry.public_id}/corrections", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "primary_form" => "Water",
          "definition" => "A transparent liquid.",
          "part_of_speech" => "noun"
        }
      })

    assert String.starts_with?(redirected_to(conn), "/contributions/")
    submission = Repo.one!(Submission)
    assert submission.kind == :correction
    assert submission.target_public_id == entry.public_id
    assert submission.payload["definition"] == "A transparent liquid."
  end

  test "does not create a moderation item for canonical duplicate content", %{conn: conn} do
    entry = create_entry()

    conn =
      post(conn, ~p"/entries/#{entry.public_id}/corrections", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "primary_form" => "Water",
          "definition" => "A clear liquid."
        }
      })

    document = conn |> html_response(409) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query_by_id(document, "flash-error")) == 1
    assert Repo.aggregate(Submission, :count) == 0
  end

  test "requires content when adding information to an entry", %{conn: conn} do
    entry = create_entry()
    path = ~p"/entries/#{entry.public_id}/add"

    document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query_by_id(document, "entry-change-contribution-form")) == 1
    assert Enum.count(LazyHTML.query(document, "#contribution_alternate_form")) == 1
    assert Enum.count(LazyHTML.query(document, "#contribution_example")) == 1

    conn =
      post(recycle(conn), ~p"/entries/#{entry.public_id}/additions", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "alternate_form" => "",
          "example" => ""
        }
      })

    document = conn |> html_response(422) |> LazyHTML.from_document()

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(document, "contribution_alternate_form"),
             "aria-invalid"
           ) == ["true"]

    assert Enum.count(LazyHTML.query_by_id(document, "contribution_alternate_form-errors")) == 1

    assert Repo.aggregate(Submission, :count) == 0
  end

  test "renders and submits a standalone example", %{conn: conn} do
    entry = create_entry()
    path = ~p"/entries/#{entry.public_id}/examples/new"

    document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
    form = LazyHTML.query_by_id(document, "entry-change-contribution-form")

    assert Enum.count(LazyHTML.query(form, "#contribution_example[required]")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(document, "entry-media-contribution"))

    conn =
      post(recycle(conn), ~p"/entries/#{entry.public_id}/examples", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "example" => "Drink water."
        }
      })

    assert String.starts_with?(redirected_to(conn), "/contributions/")
    assert Repo.one!(Submission).kind == :example
  end

  test "renders media-only forms and claims exactly the requested kind", %{conn: conn} do
    entry = create_entry()

    audio_document =
      conn
      |> get(~p"/entries/#{entry.public_id}/audio/new")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(audio_document, "entry-audio-upload")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(audio_document, "media_context_variety_label"))
    assert Enum.empty?(LazyHTML.query_by_id(audio_document, "entry-image-uploads"))

    image_document =
      conn
      |> recycle()
      |> get(~p"/entries/#{entry.public_id}/images/new")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(image_document, "entry-image-uploads")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(image_document, "media_context_variety_label"))

    assert LazyHTML.attribute(
             LazyHTML.query_by_id(image_document, "entry-image-uploads"),
             "multiple"
           ) == [""]

    assert Enum.empty?(LazyHTML.query_by_id(image_document, "entry-audio-upload"))

    {:ok, audio} = Media.create_item(audio_attrs())
    audio = make_ready(audio)

    conn =
      post(recycle(conn), ~p"/entries/#{entry.public_id}/audio", %{
        "contribution" => %{
          "client_submission_id" => Ecto.UUID.generate(),
          "media_public_ids" => [audio.public_id]
        }
      })

    assert String.starts_with?(redirected_to(conn), "/contributions/")
    submission = Repo.one!(Submission)
    assert submission.kind == :audio
    assert Repo.get!(Skad.Media.Item, audio.id).submission_id == submission.id
  end

  defp create_language do
    Archive.create_language(%{
      slug: "english",
      code: "en",
      name: "English",
      direction: :ltr
    })
  end

  defp create_entry do
    {:ok, language} = create_language()

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: language.slug, text: "A clear liquid."}]},
        forms: [%{text: "Water", kind: :spelling, is_primary: true}]
      })

    entry
  end

  defp image_attrs do
    %{
      kind: :image,
      original_object_key: "private/images/#{Ecto.UUID.generate()}",
      mime_type: "image/jpeg",
      byte_size: 2_048,
      sha256: String.duplicate("b", 64)
    }
  end

  defp audio_attrs do
    %{
      kind: :audio,
      original_object_key: "private/audio/#{Ecto.UUID.generate()}",
      mime_type: "audio/webm",
      byte_size: 8_192,
      sha256: String.duplicate("a", 64)
    }
  end

  defp make_ready(item) do
    {:ok, item} =
      Media.update_item(item, %{
        processing_state: :ready,
        public_object_key: "public/#{item.kind}/#{item.public_id}"
      })

    item
  end
end
