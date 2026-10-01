defmodule Skad.Media.Storage do
  @upload_expires_in 300

  def presign_put(object_key, mime_type) do
    config = config()
    headers = [{"content-type", mime_type}]

    url =
      Req.Utils.aws_sigv4_url(
        credentials(config) ++
          [
            datetime: DateTime.utc_now(),
            method: :put,
            url: object_url(config, object_key),
            expires: @upload_expires_in,
            headers: headers
          ]
      )

    {:ok,
     %{
       url: URI.to_string(url),
       headers: Map.new(headers),
       expires_in: @upload_expires_in
     }}
  end

  def presign_get(object_key) do
    config = config()

    url =
      Req.Utils.aws_sigv4_url(
        credentials(config) ++
          [
            datetime: DateTime.utc_now(),
            method: :get,
            url: object_url(config, object_key),
            expires: @upload_expires_in
          ]
      )

    {:ok, %{url: URI.to_string(url), expires_in: @upload_expires_in}}
  end

  def head_object(object_key) do
    config = config()

    options =
      Keyword.merge(
        [aws_sigv4: credentials(config), retry: false],
        Keyword.get(config, :req_options, [])
      )

    case Req.head(object_url(config, object_key), options) do
      {:ok, %Req.Response{status: 200} = response} -> object_metadata(response)
      {:ok, %Req.Response{status: 404}} -> {:error, :object_not_found}
      {:ok, %Req.Response{}} -> {:error, :storage_unavailable}
      {:error, _exception} -> {:error, :storage_unavailable}
    end
  end

  defp object_metadata(response) do
    with [content_length] <- Req.Response.get_header(response, "content-length"),
         {byte_size, ""} <- Integer.parse(content_length),
         [mime_type] <- Req.Response.get_header(response, "content-type") do
      {:ok, %{byte_size: byte_size, mime_type: mime_type}}
    else
      _invalid_headers -> {:error, :invalid_object_metadata}
    end
  end

  defp object_url(config, object_key) do
    endpoint = config |> Keyword.fetch!(:endpoint) |> URI.parse()
    bucket = Keyword.fetch!(config, :bucket)

    if Keyword.fetch!(config, :path_style) do
      endpoint
      |> Map.put(:path, "/#{bucket}/#{object_key}")
      |> URI.to_string()
    else
      endpoint
      |> Map.update!(:host, &"#{bucket}.#{&1}")
      |> Map.put(:path, "/#{object_key}")
      |> URI.to_string()
    end
  end

  defp credentials(config) do
    [
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key),
      region: Keyword.fetch!(config, :region),
      service: :s3
    ]
  end

  defp config, do: Application.fetch_env!(:skad, :object_storage)
end
