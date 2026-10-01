defmodule SkadWeb.MediaControllerTest do
  use SkadWeb.ConnCase

  alias Skad.Archive
  alias Skad.Media
  alias Skad.Media.Storage

  setup {Req.Test, :verify_on_exit!}

  test "prepares and completes a direct browser upload", %{conn: conn} do
    upload = %{
      "kind" => "audio",
      "mime_type" => "audio/webm",
      "byte_size" => 8_192,
      "sha256" => String.duplicate("a", 64)
    }

    conn = post(conn, ~p"/media/uploads", upload)
    instructions = json_response(conn, 200)
    assert instructions["url"] =~ "/skad-test/private/audio/"
    assert instructions["headers"] == %{"content-type" => "audio/webm"}

    Req.Test.expect(Storage, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "8192")
      |> Plug.Conn.put_resp_header("content-type", "audio/webm")
      |> Plug.Conn.send_resp(200, "")
    end)

    Req.Test.expect(Storage, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path =~ "/skad-test/public/audio/"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    conn = post(recycle(conn), ~p"/media/uploads/complete", instructions["completion"])
    completed = json_response(conn, 200)
    assert completed["kind"] == "audio"
    assert {:ok, _public_id} = Ecto.UUID.cast(completed["public_id"])

    item = Media.get_item(completed["public_id"])
    assert item.processing_state == :ready
    assert item.public_object_key =~ "public/audio/"
  end

  test "redirects only public media to a short-lived object URL", %{conn: conn} do
    entry = insert_entry()
    {:ok, item} = Media.create_item(entry, audio_attrs())

    assert response(get(conn, ~p"/media/#{item.public_id}"), 404) == "Media not found"

    {:ok, item} =
      Media.update_item(item, %{
        processing_state: :ready,
        visibility: :public,
        public_object_key: "public/audio/#{item.public_id}"
      })

    conn = get(recycle(conn), ~p"/media/#{item.public_id}")
    location = redirected_to(conn, 302)
    assert URI.parse(location).path == "/skad-test/public/audio/#{item.public_id}"
    assert URI.parse(location).query =~ "X-Amz-Expires=300"
  end

  defp insert_entry do
    {:ok, language} =
      Archive.create_language(%{
        slug: "english",
        code: "en",
        name: "English",
        direction: :ltr
      })

    {:ok, entry} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{definitions: [%{language: "english", text: "A clear liquid."}]},
        forms: [%{text: "water", kind: :spelling, is_primary: true}]
      })

    entry
  end

  defp audio_attrs do
    %{
      kind: :audio,
      original_object_key: "private/audio/#{Ecto.UUID.generate()}",
      mime_type: "audio/webm",
      byte_size: 8_192,
      sha256: String.duplicate("a", 64)
    }
  end
end
