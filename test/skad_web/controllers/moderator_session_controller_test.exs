defmodule SkadWeb.ModeratorSessionControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Accounts

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
