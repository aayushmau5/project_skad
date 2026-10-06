defmodule SkadWeb.ModeratorConceptController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Contributions
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Media.Storage

  def index(conn, params) do
    query = get_in(params, ["search", "query"]) || ""

    render(conn, :index,
      page_title: gettext("Manage concepts"),
      concept_page: Archive.list_concepts(query, params["page"]),
      query: query,
      search_form: Phoenix.Component.to_form(%{"query" => query}, as: :search)
    )
  end

  def new(conn, params) do
    changeset =
      Contributions.change_concept(
        conn.assigns.current_scope,
        %Concept{},
        params["concept"] || %{}
      )

    render_new(conn, changeset)
  end

  def matches(conn, params) do
    label = params["label"] || ""

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_resp_header("cache-control", "private, no-store")
    |> render(:matches,
      matches: Archive.concept_matches(label),
      checked?: String.trim(label) != ""
    )
  end

  def create(conn, %{"intent" => "check", "concept" => attrs}) do
    changeset = Contributions.change_concept(conn.assigns.current_scope, %Concept{}, attrs)
    render_new(conn, changeset)
  end

  def create(conn, %{"concept" => attrs}) do
    case Contributions.create_concept(conn.assigns.current_scope, attrs) do
      {:ok, concept} ->
        conn
        |> put_flash(:info, gettext("Concept created."))
        |> redirect(to: ~p"/moderator/concepts/#{concept.public_id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(changeset)

      {:error, _reason} ->
        send_resp(conn, :unprocessable_entity, "Concept could not be created")
    end
  end

  def show(conn, %{"public_id" => public_id}) do
    case Archive.get_concept(public_id) do
      nil -> send_resp(conn, :not_found, "Concept not found")
      concept -> render_show(conn, concept)
    end
  end

  def update(conn, %{"public_id" => public_id, "concept" => attrs}) do
    case Archive.get_concept(public_id) do
      nil ->
        send_resp(conn, :not_found, "Concept not found")

      concept ->
        case Contributions.update_concept(conn.assigns.current_scope, concept, attrs) do
          {:ok, concept} ->
            conn
            |> put_flash(:info, gettext("Concept updated."))
            |> redirect(to: ~p"/moderator/concepts/#{concept.public_id}")

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render_show(concept, changeset)

          {:error, _reason} ->
            send_resp(conn, :unprocessable_entity, "Concept could not be updated")
        end
    end
  end

  def prepare_media(conn, %{"public_id" => public_id} = params) do
    with %Concept{} = concept <- Archive.get_concept(public_id),
         {:ok, instructions} <- Media.prepare_image_upload(concept, params) do
      json(conn, instructions)
    else
      nil ->
        send_resp(conn, :not_found, "Concept not found")

      {:error, _reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid image upload."})
    end
  end

  def complete_media(conn, %{"public_id" => public_id} = params) do
    with %Concept{} = concept <- Archive.get_concept(public_id),
         {:ok, %Item{} = item} <- Media.complete_image_upload(concept, params) do
      json(conn, %{public_id: item.public_id, kind: item.kind})
    else
      nil ->
        send_resp(conn, :not_found, "Concept not found")

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "The image upload could not be verified."})
    end
  end

  def preview_media(conn, %{"public_id" => public_id, "media_public_id" => media_public_id}) do
    with %Concept{} = concept <- Archive.get_concept(public_id),
         %Item{concept_id: concept_id} = item <- Media.get_item(media_public_id),
         true <- concept_id == concept.id,
         {:ok, preview} <- Storage.presign_get(item.original_object_key) do
      redirect(conn, external: preview.url)
    else
      _missing_or_unavailable -> send_resp(conn, :not_found, "Concept image not found")
    end
  end

  def remove_media(conn, %{"public_id" => public_id, "media_public_id" => media_public_id}) do
    with %Concept{} = concept <- Archive.get_concept(public_id),
         %Item{} = item <- Media.get_item(media_public_id),
         {:ok, _item} <- Media.remove_concept_image(concept, item) do
      conn
      |> put_flash(:info, gettext("Image removed from the concept."))
      |> redirect(to: ~p"/moderator/concepts/#{concept.public_id}")
    else
      nil ->
        send_resp(conn, :not_found, "Concept image not found")

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("The concept image could not be removed."))
        |> redirect(to: ~p"/moderator/concepts/#{public_id}")
    end
  end

  defp render_new(conn, changeset) do
    label = Ecto.Changeset.get_field(changeset, :editorial_label) || ""

    render(conn, :new,
      page_title: gettext("Create concept"),
      matches: Archive.concept_matches(label),
      checked?: String.trim(label) != "",
      concept_form: Phoenix.Component.to_form(changeset, as: :concept)
    )
  end

  defp render_show(conn, concept, changeset \\ nil) do
    changeset =
      changeset || Contributions.change_concept(conn.assigns.current_scope, concept)

    render(conn, :show,
      page_title: concept.editorial_label,
      concept: concept,
      form: Phoenix.Component.to_form(changeset, as: :concept),
      media_items: Media.list_concept_images(concept)
    )
  end
end
