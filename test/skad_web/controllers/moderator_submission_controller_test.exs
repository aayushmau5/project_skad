defmodule SkadWeb.ModeratorSubmissionControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Accounts
  alias Skad.Archive
  alias Skad.Contributions
  alias Skad.Contributions.Revision
  alias Skad.Contributions.Submission
  alias Skad.Repo

  @password "correct horse battery staple"

  test "requires moderator authentication", %{conn: conn} do
    conn = get(conn, ~p"/moderator/submissions")

    assert redirected_to(conn) == ~p"/moderator/log-in"
    assert get_session(conn, :moderator_return_to) == ~p"/moderator/submissions"
  end

  test "lists open submissions and renders private proposal details", %{conn: conn} do
    submission = create_submission()
    conn = log_in(conn)

    conn = get(conn, ~p"/moderator/submissions")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "moderator-submission-queue")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "submission-#{submission.public_id}")) == 1

    document =
      conn
      |> recycle()
      |> get(~p"/moderator/submissions/#{submission.public_id}")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "moderator-submission-detail")) == 1

    assert LazyHTML.text(LazyHTML.query_by_id(document, "submission-definition")) ==
             "Private proposed meaning"

    assert Enum.count(LazyHTML.query_by_id(document, "moderation-form")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "approve-submission")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "proposal-edit-form")) == 1
    assert Enum.empty?(LazyHTML.query_by_id(document, "request-clarification"))

    missing_conn =
      conn
      |> recycle()
      |> get(~p"/moderator/submissions/#{Ecto.UUID.generate()}")

    assert response(missing_conn, 404) == "Submission not found"
  end

  test "handles review and rejection decisions", %{conn: conn} do
    submission = create_submission()
    conn = log_in(conn)
    path = ~p"/moderator/submissions/#{submission.public_id}"

    conn =
      patch(conn, path, %{
        "moderation" => %{"decision" => "reviewing", "note" => "Checking"}
      })

    assert redirected_to(conn) == path
    assert Repo.get!(Submission, submission.id).status == :reviewing

    invalid_conn =
      conn
      |> recycle()
      |> patch(path, %{
        "moderation" => %{"decision" => "rejected", "note" => " "}
      })

    document = invalid_conn |> html_response(422) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query_by_id(document, "moderation-form")) == 1
    assert Repo.get!(Submission, submission.id).status == :reviewing

    conn =
      invalid_conn
      |> recycle()
      |> patch(path, %{
        "moderation" => %{"decision" => "rejected", "note" => "Could not verify"}
      })

    assert redirected_to(conn) == path
    rejected = Repo.get!(Submission, submission.id)
    assert rejected.status == :rejected

    assert Enum.map(rejected.review_history, & &1["status"]) == [
             "reviewing",
             "rejected"
           ]

    document =
      conn
      |> recycle()
      |> get(path)
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.empty?(LazyHTML.query_by_id(document, "moderation-form"))
  end

  test "edits a working proposal while preserving the contributor's original", %{conn: conn} do
    submission = create_submission()
    conn = log_in(conn)
    detail_path = ~p"/moderator/submissions/#{submission.public_id}"

    conn =
      patch(conn, ~p"/moderator/submissions/#{submission.public_id}/proposal", %{
        "proposal" => %{
          "language_slug" => "english",
          "primary_form" => "Drinking water",
          "definition" => "Water that is safe to drink.",
          "part_of_speech" => "noun",
          "usage_note" => "For people and animals.",
          "cultural_note" => ""
        }
      })

    assert redirected_to(conn) == detail_path

    edited = Repo.get!(Submission, submission.id)
    assert edited.status == :reviewing
    assert edited.payload["primary_form"] == "Water"
    assert edited.reviewed_payload["primary_form"] == "Drinking water"
    assert List.last(edited.review_history)["action"] == "edited"

    document =
      conn
      |> recycle()
      |> get(detail_path)
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.text(LazyHTML.query_by_id(document, "submission-payload")) =~
             "Water that is safe to drink."

    assert LazyHTML.text(LazyHTML.query_by_id(document, "original-submission-payload")) =~
             "Private proposed meaning"

    assert Enum.count(LazyHTML.query_by_id(document, "review-event-0")) == 1
  end

  test "approves and publishes a pending submission", %{conn: conn} do
    submission = create_submission()
    conn = log_in(conn)

    conn =
      patch(conn, ~p"/moderator/submissions/#{submission.public_id}", %{
        "moderation" => %{"decision" => "approve", "note" => "Verified"}
      })

    entry_path = redirected_to(conn)
    assert String.starts_with?(entry_path, "/entries/")
    assert Repo.get!(Submission, submission.id).status == :approved
    assert Repo.aggregate(Revision, :count) == 1

    document =
      conn
      |> recycle()
      |> get(entry_path)
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "entry-page")) == 1
  end

  defp create_submission do
    {:ok, language} =
      Archive.create_language(%{
        slug: "english",
        code: "en",
        name: "English",
        direction: :ltr
      })

    {:ok, receipt} =
      Contributions.submit_new_entry(%{
        client_submission_id: Ecto.UUID.generate(),
        language_slug: language.slug,
        primary_form: "Water",
        definition: "Private proposed meaning"
      })

    Repo.get_by!(Submission, public_id: receipt.public_id)
  end

  defp log_in(conn) do
    {:ok, account} =
      Accounts.create_moderator_account(%{
        email: "editor@example.com",
        display_name: "Archive Editor",
        password: @password,
        password_confirmation: @password
      })

    {:ok, token} = Accounts.create_moderator_session(account)

    conn
    |> init_test_session(%{})
    |> put_session(:moderator_session_token, token)
  end
end
