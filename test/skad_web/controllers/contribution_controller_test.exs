defmodule SkadWeb.ContributionControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Archive
  alias Skad.Contributions.Submission
  alias Skad.Repo

  test "renders a new-entry form with a stable client submission id", %{conn: conn} do
    create_language()

    document = conn |> get(~p"/contribute") |> html_response(200) |> LazyHTML.from_document()
    form = LazyHTML.query_by_id(document, "new-entry-contribution-form")

    assert Enum.count(form) == 1
    assert Enum.count(LazyHTML.query(form, "option[value=english]")) == 1

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
      "definition" => "Private proposed meaning"
    }

    conn = post(conn, ~p"/contributions", %{"contribution" => params})
    receipt_path = redirected_to(conn)
    assert String.starts_with?(receipt_path, "/contributions/")
    assert Repo.aggregate(Submission, :count) == 1

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

  test "returns not found for an unknown receipt", %{conn: conn} do
    conn = get(conn, ~p"/contributions/#{Ecto.UUID.generate()}")
    assert response(conn, 404) == "Contribution receipt not found"
  end

  defp create_language do
    Archive.create_language(%{
      slug: "english",
      code: "en",
      name: "English",
      direction: :ltr
    })
  end
end
