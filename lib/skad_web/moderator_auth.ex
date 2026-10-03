defmodule SkadWeb.ModeratorAuth do
  use SkadWeb, :verified_routes

  use Gettext, backend: SkadWeb.Gettext

  import Phoenix.Controller
  import Plug.Conn

  alias Skad.Accounts
  alias Skad.Accounts.Scope

  def fetch_current_scope(conn, _opts) do
    account =
      if token = get_session(conn, :moderator_session_token) do
        Accounts.get_moderator_account_by_session_token(token)
      end

    assign(conn, :current_scope, Scope.for_moderator(account))
  end

  def log_in_moderator(conn, account) do
    return_to = get_session(conn, :moderator_return_to)
    {:ok, token} = Accounts.create_moderator_session(account)

    conn
    |> renew_session()
    |> put_session(:moderator_session_token, token)
    |> redirect(to: return_to || ~p"/moderator")
  end

  def log_out_moderator(conn) do
    if token = get_session(conn, :moderator_session_token) do
      Accounts.delete_moderator_session(token)
    end

    conn
    |> renew_session()
    |> put_flash(:info, gettext("Logged out."))
    |> redirect(to: ~p"/")
  end

  def redirect_if_moderator_is_authenticated(conn, _opts) do
    if conn.assigns.current_scope do
      conn
      |> redirect(to: ~p"/moderator")
      |> halt()
    else
      conn
    end
  end

  def require_authenticated_moderator(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn
      |> put_flash(:error, gettext("You must log in to access this page."))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/moderator/log-in")
      |> halt()
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    if Accounts.get_moderator_account_by_session_token(session["moderator_session_token"]) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/moderator/log-in")}
    end
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :moderator_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
