defmodule SkadWeb.ModeratorConceptController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Contributions

  def index(conn, params) do
    query = get_in(params, ["search", "query"]) || ""
    render_index(conn, query)
  end

  def create(conn, %{"concept" => attrs}) do
    case Contributions.create_concept(conn.assigns.current_scope, attrs) do
      {:ok, concept} ->
        conn
        |> put_flash(:info, "Concept created.")
        |> redirect(to: ~p"/moderator/concepts/#{concept.public_id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_index("", changeset)

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
            |> put_flash(:info, "Concept updated.")
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

  defp render_index(conn, query, changeset \\ nil) do
    changeset =
      changeset || Contributions.change_concept(conn.assigns.current_scope, %Concept{})

    render(conn, :index,
      page_title: "Manage concepts",
      concepts: Archive.search_concepts(query),
      search_form: Phoenix.Component.to_form(%{"query" => query}, as: :search),
      concept_form: Phoenix.Component.to_form(changeset, as: :concept)
    )
  end

  defp render_show(conn, concept, changeset \\ nil) do
    changeset =
      changeset || Contributions.change_concept(conn.assigns.current_scope, concept)

    render(conn, :show,
      page_title: concept.editorial_label,
      concept: concept,
      form: Phoenix.Component.to_form(changeset, as: :concept)
    )
  end
end
