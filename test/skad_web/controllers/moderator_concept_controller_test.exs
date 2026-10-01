defmodule SkadWeb.ModeratorConceptControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Accounts
  alias Skad.Archive.Concept
  alias Skad.Contributions.Revision
  alias Skad.Repo

  @password "correct horse battery staple"

  test "requires moderator authentication", %{conn: conn} do
    conn = get(conn, ~p"/moderator/concepts")

    assert redirected_to(conn) == ~p"/moderator/log-in"
    assert get_session(conn, :moderator_return_to) == ~p"/moderator/concepts"
  end

  test "creates, finds, and edits a concept", %{conn: conn} do
    conn = log_in(conn)

    conn =
      post(conn, ~p"/moderator/concepts", %{
        "concept" => %{
          "editorial_label" => "WATER",
          "editorial_note" => "Shared by water entries."
        }
      })

    concept = Repo.one!(Concept)
    detail_path = ~p"/moderator/concepts/#{concept.public_id}"
    assert redirected_to(conn) == detail_path

    document =
      conn
      |> recycle()
      |> get(detail_path)
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.text(LazyHTML.query_by_id(document, "concept-label")) == "WATER"

    assert LazyHTML.text(LazyHTML.query_by_id(document, "concept-note")) ==
             "Shared by water entries."

    conn =
      conn
      |> recycle()
      |> patch(detail_path, %{
        "concept" => %{
          "editorial_label" => "WATER / पानी",
          "editorial_note" => "Cross-language water concept."
        }
      })

    assert redirected_to(conn) == detail_path
    assert Repo.get!(Concept, concept.id).editorial_label == "WATER / पानी"
    assert Repo.aggregate(Revision, :count) == 2

    document =
      conn
      |> recycle()
      |> get(~p"/moderator/concepts", %{
        "search" => %{"query" => "cross-language"}
      })
      |> html_response(200)
      |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "concept-#{concept.public_id}")) == 1
  end

  test "rerenders an invalid concept", %{conn: conn} do
    conn =
      conn
      |> log_in()
      |> post(~p"/moderator/concepts", %{
        "concept" => %{"editorial_label" => " ", "editorial_note" => "Private"}
      })

    document = conn |> html_response(422) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query_by_id(document, "new-concept-form")) == 1
    assert Repo.aggregate(Concept, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
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
