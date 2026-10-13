defmodule SkadWeb.ReviewMediaController do
  use SkadWeb, :controller

  alias Skad.Media.ReviewStorage

  def upload(conn, %{"token" => token}) do
    with true <- Application.get_env(:skad, :review_instance, false),
         {:ok, %{key: key, mime_type: mime_type}} <- ReviewStorage.verify_upload(token),
         true <- get_req_header(conn, "content-type") == [mime_type] do
      limit = if String.starts_with?(mime_type, "image/"), do: 10, else: 25

      case read_body(conn, length: limit * 1024 * 1024) do
        {:ok, body, conn} ->
          case ReviewStorage.put_object(key, mime_type, body) do
            :ok -> send_resp(conn, :no_content, "")
            {:error, _reason} -> send_resp(conn, :service_unavailable, "Upload unavailable")
          end

        {:more, _body, conn} ->
          send_resp(conn, :request_entity_too_large, "Upload too large")

        {:error, _reason} ->
          send_resp(conn, :bad_request, "Upload interrupted")
      end
    else
      false -> send_resp(conn, :not_found, "Media not found")
      {:error, _reason} -> send_resp(conn, :forbidden, "Invalid or expired upload")
    end
  end

  def download(conn, %{"token" => token}) do
    with true <- Application.get_env(:skad, :review_instance, false),
         {:ok, key} <- ReviewStorage.verify_download(token),
         {:ok, %{mime_type: mime_type}} <- ReviewStorage.head_object(key),
         {:ok, path} <- ReviewStorage.object_path(key) do
      conn
      |> put_resp_header("content-type", mime_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_file(:ok, path)
    else
      false -> send_resp(conn, :not_found, "Media not found")
      {:error, _reason} -> send_resp(conn, :not_found, "Media not found")
    end
  end
end
