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
    assert Enum.count(LazyHTML.query(form, "option[value=english]")) == 1
    assert Enum.count(LazyHTML.query(form, "#contribution_example")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-media")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-audio-upload")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "contribution-image-uploads")) == 1

    [client_submission_id] =
      form
      |> LazyHTML.query("#contribution_client_submission_id")
      |> LazyHTML.attribute("value")

    assert {:ok, _client_submission_id} = Ecto.UUID.cast(client_submission_id)
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
    assert response(conn, 404) == "Contribution receipt not found"
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

    assert LazyHTML.text(LazyHTML.query_by_id(document, "entry-change-contribution-form")) =~
             "or an example is required"

    assert Repo.aggregate(Submission, :count) == 0
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
end
