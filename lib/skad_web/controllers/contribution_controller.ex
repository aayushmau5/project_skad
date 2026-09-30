defmodule SkadWeb.ContributionController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Contributions

  def new(conn, _params) do
    changeset =
      Contributions.change_new_entry(%{client_submission_id: Ecto.UUID.generate()})

    render_new(conn, changeset)
  end

  def create(conn, %{"contribution" => params}) do
    case Contributions.submit_new_entry(params) do
      {:ok, receipt} ->
        redirect(conn, to: ~p"/contributions/#{receipt.public_id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(%{changeset | action: :insert})

      {:error, :idempotency_conflict} ->
        retry_params = Map.put(params, "client_submission_id", Ecto.UUID.generate())

        conn
        |> put_status(:conflict)
        |> put_flash(:error, "This submission identifier was already used for different content.")
        |> render_new(%{Contributions.change_new_entry(retry_params) | action: :insert})
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

  defp render_new(conn, changeset) do
    render(conn, :new,
      page_title: "Suggest a word",
      form: Phoenix.Component.to_form(changeset, as: :contribution),
      languages: Archive.list_active_languages()
    )
  end
end
