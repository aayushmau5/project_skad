defmodule SkadWeb.ModeratorSessionController do
  use SkadWeb, :controller

  alias Skad.Accounts
  alias SkadWeb.ModeratorAuth

  def new(conn, _params) do
    render(conn, :new,
      page_title: "Moderator log in",
      form: Phoenix.Component.to_form(%{}, as: :moderator)
    )
  end

  def create(conn, %{"moderator" => params}) do
    email = Map.get(params, "email", "")
    password = Map.get(params, "password", "")

    case Accounts.authenticate_moderator(email, password) do
      {:ok, account} ->
        conn
        |> put_flash(:info, "Welcome back.")
        |> ModeratorAuth.log_in_moderator(account)

      :error ->
        invalid_credentials(conn, email)
    end
  end

  def create(conn, _params), do: invalid_credentials(conn, "")

  def delete(conn, _params), do: ModeratorAuth.log_out_moderator(conn)

  defp invalid_credentials(conn, email) do
    conn
    |> put_flash(:error, "Invalid email or password.")
    |> render(:new,
      page_title: "Moderator log in",
      form: Phoenix.Component.to_form(%{"email" => String.slice(email, 0, 160)}, as: :moderator)
    )
  end
end
