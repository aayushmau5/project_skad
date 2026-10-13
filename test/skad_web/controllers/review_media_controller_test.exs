defmodule SkadWeb.ReviewMediaControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Media
  alias Skad.Media.ReviewStorage
  alias Skad.Media.Storage
  alias Skad.Contributions
  alias Skad.Contributions.Submission
  alias Skad.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: path} do
    previous =
      for key <- [:review_instance, :review_upload_path],
          do: {key, Application.fetch_env(:skad, key)}

    Application.put_env(:skad, :review_instance, true)
    Application.put_env(:skad, :review_upload_path, path)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:skad, key, value)
          :error -> Application.delete_env(:skad, key)
        end
      end
    end)

    :ok
  end

  test "audio uploads complete and serve the original bytes after publication", %{conn: conn} do
    wav =
      <<"RIFF", 1060::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        8000::little-32, 16000::little-32, 2::little-16, 16::little-16, "data", 1024::little-32,
        0::size(8192)>>

    upload_and_publish(conn, "audio", "audio/wav", wav)
  end

  test "image uploads complete and serve the original bytes after publication", %{conn: conn} do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
      )

    upload_and_publish(conn, "image", "image/png", png)
  end

  test "rejects tampered, expired, and wrong-purpose upload URLs", %{conn: conn} do
    key = "private/audio/#{Ecto.UUID.generate()}"
    {:ok, instructions} = Storage.presign_put(key, "audio/wav")
    {:ok, download} = Storage.presign_get(key)

    expired =
      Phoenix.Token.sign(
        SkadWeb.Endpoint,
        "review-media-put",
        %{key: key, mime_type: "audio/wav"}, signed_at: System.system_time(:second) - 301)

    for path <- [
          URI.parse(instructions.url).path <> "tampered",
          URI.parse(download.url).path,
          ~p"/review-media/#{expired}"
        ] do
      assert conn
             |> recycle()
             |> put_req_header("content-type", "audio/wav")
             |> put(path, "audio")
             |> response(403)
    end

    assert {:error, :object_not_found} = Storage.head_object(key)
  end

  test "rejects the wrong MIME type and oversized bodies without storing files", %{conn: conn} do
    key = "private/images/#{Ecto.UUID.generate()}"
    {:ok, instructions} = Storage.presign_put(key, "image/png")
    path = URI.parse(instructions.url).path

    assert conn
           |> put_req_header("content-type", "image/jpeg")
           |> put(path, "image")
           |> response(404)

    assert conn
           |> recycle()
           |> put_req_header("content-type", "image/png")
           |> put(path, String.duplicate(<<0>>, 10 * 1024 * 1024 + 1))
           |> response(413)

    assert {:error, :object_not_found} = Storage.head_object(key)
  end

  test "rejects paths outside the review upload directories" do
    for key <- [
          "../../secret",
          "public/images/../secret",
          "private/audio/not-a-uuid",
          "private/documents/#{Ecto.UUID.generate()}",
          nil
        ] do
      assert {:error, :invalid_object_key} = ReviewStorage.object_path(key)
    end
  end

  test "media routes are disabled outside review mode", %{conn: conn} do
    key = "private/audio/#{Ecto.UUID.generate()}"
    {:ok, upload} = Storage.presign_put(key, "audio/wav")
    {:ok, download} = Storage.presign_get(key)
    Application.put_env(:skad, :review_instance, false)

    assert conn
           |> put_req_header("content-type", "audio/wav")
           |> put(URI.parse(upload.url).path, "audio")
           |> response(404)

    assert conn |> recycle() |> get(URI.parse(download.url).path) |> response(404)
    assert {:ok, %{url: url}} = Storage.presign_put(key, "audio/wav")
    assert URI.parse(url).host == "storage.test"
  end

  test "the temporary-data notice appears only in review mode in both interface languages", %{
    conn: conn
  } do
    for locale <- ["en", "hi"] do
      document =
        conn
        |> recycle()
        |> get(~p"/?ui_language=#{locale}")
        |> html_response(200)
        |> LazyHTML.from_document()

      refute Enum.empty?(LazyHTML.query_by_id(document, "review-instance-notice"))
    end

    Application.put_env(:skad, :review_instance, false)
    document = conn |> recycle() |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    assert Enum.empty?(LazyHTML.query_by_id(document, "review-instance-notice"))
  end

  defp upload_and_publish(conn, kind, mime_type, body) do
    conn =
      post(conn, ~p"/media/uploads", %{
        "kind" => kind,
        "mime_type" => mime_type,
        "byte_size" => byte_size(body),
        "sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      })

    instructions = json_response(conn, 200)
    path = URI.parse(instructions["url"]).path

    assert conn
           |> recycle()
           |> put_req_header("content-type", mime_type)
           |> put(path, body)
           |> response(204) == ""

    conn = post(recycle(conn), ~p"/media/uploads/complete", instructions["completion"])
    completed = json_response(conn, 200)
    item = Media.get_item(completed["public_id"])
    assert item.processing_state == :ready
    assert item.visibility == :quarantine
    assert conn |> recycle() |> get(~p"/media/#{item.public_id}") |> response(404)

    %{water: entry, scope: scope} = Skad.ModerationFixtures.records()

    {:ok, receipt} =
      Contributions.submit_entry_change(
        item.kind,
        entry,
        %{client_submission_id: Ecto.UUID.generate()},
        [item.public_id]
      )

    submission = Repo.get_by!(Submission, public_id: receipt.public_id)
    assert {:ok, _published} = Contributions.approve_submission(scope, submission)
    item = Media.get_item(item.public_id)
    conn = get(recycle(conn), ~p"/media/#{item.public_id}")
    path = conn |> redirected_to(302) |> URI.parse() |> Map.fetch!(:path)
    conn = get(recycle(conn), path)
    assert response(conn, 200) == body
    assert get_resp_header(conn, "content-type") == [mime_type]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    expired =
      Phoenix.Token.sign(SkadWeb.Endpoint, "review-media-get", item.public_object_key,
        signed_at: System.system_time(:second) - 301
      )

    assert conn |> recycle() |> get(~p"/review-media/#{expired}") |> response(404)
  end
end
