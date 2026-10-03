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
        |> put_flash(
          :error,
          gettext("This submission identifier was already used for different content.")
        )
        |> render_new(
          %{Contributions.change_new_entry(retry_params) | action: :insert},
          media_public_ids
        )

      {:error, :invalid_media} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_flash(
          :error,
          gettext("The uploaded media could not be attached. Please upload it again.")
        )
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
      nil ->
        SkadWeb.PageController.not_found(conn, gettext("Contribution receipt not found"))

      receipt ->
        render(conn, :show, page_title: gettext("Contribution received"), receipt: receipt)
    end
  end

  def correct(conn, %{"public_id" => public_id}) do
    render_entry_change(conn, public_id, :correction)
  end

  def add(conn, %{"public_id" => public_id}) do
    render_entry_change(conn, public_id, :addition)
  end

  def example(conn, %{"public_id" => public_id}) do
    render_entry_change(conn, public_id, :example)
  end

  def audio(conn, %{"public_id" => public_id}) do
    render_entry_change(conn, public_id, :audio)
  end

  def images(conn, %{"public_id" => public_id}) do
    render_entry_change(conn, public_id, :image)
  end

  def create_correction(conn, %{"public_id" => public_id} = params) do
    create_entry_change(conn, public_id, :correction, Map.get(params, "contribution", %{}))
  end

  def create_addition(conn, %{"public_id" => public_id} = params) do
    create_entry_change(conn, public_id, :addition, Map.get(params, "contribution", %{}))
  end

  def create_example(conn, %{"public_id" => public_id} = params) do
    create_entry_change(conn, public_id, :example, Map.get(params, "contribution", %{}))
  end

  def create_audio(conn, %{"public_id" => public_id} = params) do
    create_entry_change(conn, public_id, :audio, Map.get(params, "contribution", %{}))
  end

  def create_images(conn, %{"public_id" => public_id} = params) do
    create_entry_change(conn, public_id, :image, Map.get(params, "contribution", %{}))
  end

  defp render_new(conn, changeset, media_public_ids \\ []) do
    media_items =
      media_public_ids
      |> Enum.map(&Media.get_item/1)
      |> Enum.reject(&is_nil/1)

    render(conn, :new,
      page_title: gettext("Suggest a word"),
      form: Phoenix.Component.to_form(changeset, as: :contribution),
      languages: Archive.list_active_languages(),
      media_items: media_items,
      media_context_form:
        Phoenix.Component.to_form(conn.params["media_context"] || %{}, as: :media_context)
    )
  end

  defp render_entry_change(conn, public_id, kind, changeset \\ nil, media_public_ids \\ []) do
    case Archive.get_public_entry(public_id) do
      nil ->
        SkadWeb.PageController.not_found(conn, gettext("Entry not found"))

      entry ->
        changeset =
          changeset ||
            Contributions.change_entry_change(kind, entry, %{
              client_submission_id: Ecto.UUID.generate()
            })

        render(conn, :entry_change,
          page_title: entry_change_title(kind),
          entry: entry,
          kind: kind,
          form: Phoenix.Component.to_form(changeset, as: :contribution),
          media_items: media_items(media_public_ids),
          media_context_form:
            Phoenix.Component.to_form(conn.params["media_context"] || %{}, as: :media_context)
        )
    end
  end

  defp create_entry_change(conn, public_id, kind, params) do
    media_public_ids = params |> Map.get("media_public_ids") |> List.wrap()
    proposal_params = Map.delete(params, "media_public_ids")

    case Archive.get_public_entry(public_id) do
      nil ->
        SkadWeb.PageController.not_found(conn, gettext("Entry not found"))

      entry ->
        case Contributions.submit_entry_change(kind, entry, proposal_params, media_public_ids) do
          {:ok, receipt} ->
            redirect(conn, to: ~p"/contributions/#{receipt.public_id}")

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render_entry_change(
              public_id,
              kind,
              %{changeset | action: :insert},
              media_public_ids
            )

          {:error, :idempotency_conflict} ->
            retry_params =
              Map.put(proposal_params, "client_submission_id", Ecto.UUID.generate())

            conn
            |> put_status(:conflict)
            |> put_flash(
              :error,
              gettext("This submission identifier was already used for different content.")
            )
            |> render_entry_change(
              public_id,
              kind,
              %{Contributions.change_entry_change(kind, entry, retry_params) | action: :insert},
              media_public_ids
            )

          {:error, :already_exists} ->
            conn
            |> put_status(:conflict)
            |> put_flash(:error, gettext("That contribution is already part of this entry."))
            |> render_entry_change(
              public_id,
              kind,
              %{
                Contributions.change_entry_change(kind, entry, proposal_params)
                | action: :insert
              },
              media_public_ids
            )

          {:error, :invalid_media} ->
            conn
            |> put_status(:unprocessable_entity)
            |> put_flash(:error, media_error(kind))
            |> render_entry_change(
              public_id,
              kind,
              %{Contributions.change_entry_change(kind, entry, proposal_params) | action: :insert}
            )
        end
    end
  end

  defp entry_change_title(:correction), do: gettext("Suggest a correction")
  defp entry_change_title(:addition), do: gettext("Add information")
  defp entry_change_title(:example), do: gettext("Add an example")
  defp entry_change_title(:audio), do: gettext("Add pronunciation audio")
  defp entry_change_title(:image), do: gettext("Add cultural images")

  defp media_items(public_ids) do
    public_ids
    |> Enum.map(&Media.get_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp media_error(:audio), do: gettext("Upload exactly one ready audio file and try again.")
  defp media_error(:image), do: gettext("Upload between one and five ready images and try again.")
  defp media_error(_kind), do: gettext("Media is not accepted for this contribution type.")
end
