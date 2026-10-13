defmodule Skad.Media.ReviewStorage do
  @moduledoc "Temporary signed media storage for disposable review instances."

  alias SkadWeb.Endpoint

  @expires_in 300

  def presign_put(key, mime_type) do
    token = Phoenix.Token.sign(Endpoint, "review-media-put", %{key: key, mime_type: mime_type})

    {:ok, %{url: url(token), headers: %{"content-type" => mime_type}, expires_in: @expires_in}}
  end

  def presign_get(key) do
    token = Phoenix.Token.sign(Endpoint, "review-media-get", key)
    {:ok, %{url: url(token), expires_in: @expires_in}}
  end

  def verify_upload(token) do
    Phoenix.Token.verify(Endpoint, "review-media-put", token, max_age: @expires_in)
  end

  def verify_download(token) do
    Phoenix.Token.verify(Endpoint, "review-media-get", token, max_age: @expires_in)
  end

  def put_object(key, mime_type, body) do
    with {:ok, path} <- object_path(key),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body),
         :ok <- File.write(path <> ".mime", mime_type) do
      :ok
    else
      _error -> {:error, :storage_unavailable}
    end
  end

  def head_object(key) do
    with {:ok, path} <- object_path(key),
         {:ok, %{size: size, type: :regular}} <- File.stat(path),
         {:ok, mime_type} <- File.read(path <> ".mime") do
      {:ok, %{byte_size: size, mime_type: mime_type}}
    else
      _error -> {:error, :object_not_found}
    end
  end

  def copy_object(source_key, destination_key) do
    with {:ok, source} <- object_path(source_key),
         {:ok, destination} <- object_path(destination_key),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source, destination),
         :ok <- File.cp(source <> ".mime", destination <> ".mime") do
      :ok
    else
      _error -> {:error, :storage_unavailable}
    end
  end

  def object_path(key) when is_binary(key) do
    with [visibility, kind, id] <- String.split(key, "/"),
         true <- visibility in ["private", "public"] and kind in ["audio", "images"],
         {:ok, _id} <- Ecto.UUID.cast(id) do
      {:ok, Path.join(Application.fetch_env!(:skad, :review_upload_path), key)}
    else
      _invalid_key -> {:error, :invalid_object_key}
    end
  end

  def object_path(_key), do: {:error, :invalid_object_key}

  defp url(token), do: Endpoint.url() <> "/review-media/" <> token
end
