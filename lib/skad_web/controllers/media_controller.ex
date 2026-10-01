defmodule SkadWeb.MediaController do
  use SkadWeb, :controller

  alias Ecto.Changeset
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Media.Storage

  def prepare_upload(conn, params) do
    case Media.prepare_upload(params) do
      {:ok, instructions} ->
        json(conn, instructions)

      {:error, %Changeset{}} ->
        upload_error(conn, :unprocessable_entity, "Invalid upload metadata.")

      {:error, _reason} ->
        upload_error(conn, :service_unavailable, "Object storage is unavailable.")
    end
  end

  def complete_upload(conn, params) do
    case Media.complete_upload(params) do
      {:ok, %Item{} = item} ->
        json(conn, %{public_id: item.public_id, kind: item.kind})

      {:error, :storage_unavailable} ->
        upload_error(conn, :service_unavailable, "Object storage is unavailable.")

      {:error, _reason} ->
        upload_error(conn, :unprocessable_entity, "The upload could not be verified.")
    end
  end

  def show(conn, %{"public_id" => public_id}) do
    with %Item{} = item <- Media.get_public_item(public_id),
         {:ok, preview} <- Storage.presign_get(item.public_object_key) do
      redirect(conn, external: preview.url)
    else
      nil -> send_resp(conn, :not_found, "Media not found")
      {:error, _reason} -> send_resp(conn, :service_unavailable, "Media unavailable")
    end
  end

  defp upload_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
