defmodule SkadWeb.ModeratorSessionControllerTest do
  use SkadWeb.ConnCase

  alias Skad.{Accounts, Repo}
  alias Skad.Contributions.Submission

  @password "correct horse battery staple"

  test "renders the login form", %{conn: conn} do
    conn = get(conn, ~p"/moderator/log-in")

    assert conn
           |> html_response(200)
           |> LazyHTML.from_document()
           |> LazyHTML.query_by_id("moderator-login-form")
           |> Enum.count() == 1
  end

  test "rejects invalid credentials without creating a session", %{conn: conn} do
    conn =
      post(conn, ~p"/moderator/log-in", %{
        "moderator" => %{"email" => "missing@example.com", "password" => "wrong password"}
      })

    assert conn
           |> html_response(200)
           |> LazyHTML.from_document()
           |> LazyHTML.query_by_id("moderator-login-form")
           |> Enum.count() == 1

    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
    refute get_session(conn, :moderator_session_token)
  end

  test "returns a moderator to the protected page after login", %{conn: conn} do
    account = create_account()

    conn = conn |> init_test_session(%{stale_session_value: true}) |> get(~p"/moderator")
    assert redirected_to(conn) == ~p"/moderator/log-in"
    assert get_session(conn, :moderator_return_to) == ~p"/moderator"

    conn =
      conn
      |> recycle()
      |> post(~p"/moderator/log-in", %{
        "moderator" => %{"email" => account.email, "password" => @password}
      })

    assert redirected_to(conn) == ~p"/moderator"
    token = get_session(conn, :moderator_session_token)
    assert Accounts.get_moderator_account_by_session_token(token).id == account.id
    refute get_session(conn, :stale_session_value)

    conn = conn |> recycle() |> get(~p"/moderator")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "moderator-display-name")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "moderator-log-out")) == 1
    assert Enum.count(LazyHTML.query_by_id(document, "moderator-dashboard-link")) == 1

    assert document
           |> LazyHTML.query_by_id("moderator-pending-review-count")
           |> LazyHTML.text()
           |> String.trim() == "0"
  end

  test "workspace count includes the whole open queue and updates after a decision", %{conn: conn} do
    account = create_account()

    submissions =
      for status <-
            List.duplicate(:pending, 21) ++
              [:reviewing, :clarification_needed, :approved, :rejected, :withdrawn] do
        %Submission{kind: :new_entry, status: status}
        |> Submission.changeset(%{
          client_submission_id: Ecto.UUID.generate(),
          payload: %{"definition" => "Review count sample"}
        })
        |> Repo.insert!()
      end

    conn =
      post(conn, ~p"/moderator/log-in", %{
        "moderator" => %{"email" => account.email, "password" => @password}
      })

    home = conn |> recycle() |> get(~p"/moderator?ui_language=hi")
    document = home |> html_response(200) |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query_by_id("moderator-pending-review-count")
           |> LazyHTML.text()
           |> String.trim() == "23"

    assert document
           |> LazyHTML.query_by_id("moderator-submissions-link")
           |> LazyHTML.attribute("aria-label") == ["सुझावों की समीक्षा करें: 23 पर निर्णय बाकी है"]

    List.first(submissions)
    |> Ecto.Changeset.change(status: :approved)
    |> Repo.update!()

    updated = home |> recycle() |> get(~p"/moderator?ui_language=en")
    document = updated |> html_response(200) |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query_by_id("moderator-pending-review-count")
           |> LazyHTML.text()
           |> String.trim() == "22"
  end

  test "protects the system dashboard with the moderator session", %{conn: conn} do
    conn = get(conn, ~p"/moderator/dashboard")

    assert redirected_to(conn) == ~p"/moderator/log-in"
    assert get_session(conn, :moderator_return_to) == ~p"/moderator/dashboard"

    account = create_account()

    conn =
      conn
      |> recycle()
      |> post(~p"/moderator/log-in", %{
        "moderator" => %{"email" => account.email, "password" => @password}
      })

    assert redirected_to(conn) == ~p"/moderator/dashboard"

    dashboard_conn = conn |> recycle() |> get(~p"/moderator/dashboard")
    dashboard_home = redirected_to(dashboard_conn)
    assert dashboard_home == ~p"/moderator/dashboard/home"

    dashboard_conn = dashboard_conn |> recycle() |> get(dashboard_home)
    assert html_response(dashboard_conn, 200)
  end

  test "logout revokes the database session", %{conn: conn} do
    account = create_account()

    conn =
      post(conn, ~p"/moderator/log-in", %{
        "moderator" => %{"email" => account.email, "password" => @password}
      })

    token = get_session(conn, :moderator_session_token)
    conn = conn |> recycle() |> delete(~p"/moderator/log-out")

    assert redirected_to(conn) == ~p"/"
    refute get_session(conn, :moderator_session_token)
    assert Accounts.get_moderator_account_by_session_token(token) == nil

    conn = conn |> recycle() |> get(~p"/moderator")
    assert redirected_to(conn) == ~p"/moderator/log-in"
  end

  defp create_account do
    {:ok, account} =
      Accounts.create_moderator_account(%{
        email: "editor@example.com",
        display_name: "Archive Editor",
        password: @password,
        password_confirmation: @password
      })

    account
  end
end
