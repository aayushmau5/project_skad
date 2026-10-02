defmodule SkadWeb.HealthControllerTest do
  use SkadWeb.ConnCase

  test "reports that the web process is alive", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "reports readiness when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/ready")

    assert json_response(conn, 200) == %{"status" => "ok", "database" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
