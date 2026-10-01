defmodule SkadWeb.ContributionController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Contributions
  alias Skad.Media

  def new(conn, _params) do
    changeset =
      Contributions.change_new_entry(%{client_submission_id: Ecto.UUID.generate()})

    render_new(conn, changeset)
  end

  def create(conn, %{"contribution" => params}) do
    media_public_ids = params |> Map.get("media_public_ids") |> List.wrap()
    proposal_params = Map.delete(params, "media_public_ids")

    case Contributions.submit_new_entry(proposal_params, media_public_ids) do
      {:ok, receipt} ->
        redirect(conn, to: ~p"/contributions/#{receipt.public_id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(%{changeset | action: :insert}, media_public_ids)

      {:error, :idempotency_conflict} ->
        retry_params = Map.put(proposal_params, "client_submission_id", Ecto.UUID.generate())

        conn
        |> put_status(:conflict)
        |> put_flash(:error, "This submission identifier was already used for different content.")
        |> render_new(%{Contributions.change_new_entry(retry_params) | action: :insert})

      {:error, :invalid_media} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_flash(:error, "The uploaded media could not be attached. Please upload it again.")
        |> render_new(%{Contributions.change_new_entry(proposal_params) | action: :insert})
    end
  end

  def create(conn, _params) do
    changeset =
      Contributions.change_new_entry(%{client_submission_id: Ecto.UUID.generate()})

    conn
    |> put_status(:unprocessable_entity)
    |> render_new(%{changeset | action: :insert})
  end

  def show(conn, %{"public_id" => public_id}) do
    case Contributions.get_receipt(public_id) do
      nil -> send_resp(conn, :not_found, "Contribution receipt not found")
      receipt -> render(conn, :show, page_title: "Contribution received", receipt: receipt)
    end
  end

  defp render_new(conn, changeset, media_public_ids \\ []) do
    media_items =
      media_public_ids
      |> Enum.map(&Media.get_item/1)
      |> Enum.reject(&is_nil/1)

    render(conn, :new,
      page_title: "Suggest a word",
      form: Phoenix.Component.to_form(changeset, as: :contribution),
      languages: Archive.list_active_languages(),
      media_items: media_items
    )
  end
end
