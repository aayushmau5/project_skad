defmodule SkadWeb.HealthController do
  use SkadWeb, :controller

  def health(conn, _params) do
    respond(conn, :ok, %{status: "ok"})
  end

  def ready(conn, _params) do
    case database_ready?() do
      true -> respond(conn, :ok, %{status: "ok", database: "ok"})
      false -> respond(conn, :service_unavailable, %{status: "unavailable", database: "error"})
    end
  end

  defp database_ready? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Skad.Repo, "SELECT 1", []))
  catch
    :exit, _reason -> false
  end

  defp respond(conn, status, body) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(body)
  end
end
