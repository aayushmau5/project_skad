defmodule SkadWeb.ModeratorSubmissionController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Contributions
  alias Skad.Media
  alias Skad.Media.Item

  def index(conn, params) do
    page =
      Contributions.page_submissions_for_review(
        conn.assigns.current_scope,
        params["after"]
      )

    render(conn, :index,
      page_title: "Submission queue",
      submissions: page.submissions,
      next_cursor: page.next_cursor
    )
  end

  def show(conn, %{"public_id" => public_id} = params) do
    case Contributions.get_submission_for_review(conn.assigns.current_scope, public_id) do
      nil -> send_resp(conn, :not_found, "Submission not found")
      submission -> render_show(conn, submission, %{}, nil, concept_query(params))
    end
  end

  def update(conn, %{"public_id" => public_id} = params) do
    case Contributions.get_submission_for_review(conn.assigns.current_scope, public_id) do
      nil ->
        send_resp(conn, :not_found, "Submission not found")

      submission ->
        moderation = Map.get(params, "moderation", %{})
        decide(conn, submission, moderation)
    end
  end

  def update_proposal(conn, %{"public_id" => public_id} = params) do
    case Contributions.get_submission_for_review(conn.assigns.current_scope, public_id) do
      nil ->
        send_resp(conn, :not_found, "Submission not found")

      submission ->
        proposal = Map.get(params, "proposal", %{})

        case Contributions.update_submission_for_review(
               conn.assigns.current_scope,
               submission,
               proposal
             ) do
          {:ok, submission} ->
            conn
            |> put_flash(:info, "Proposal changes saved.")
            |> redirect(to: ~p"/moderator/submissions/#{submission.public_id}")

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render_show(submission, %{}, %{changeset | action: :update})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> put_flash(:error, error_message(reason))
            |> render_show(submission)
        end
    end
  end

  def attach_media(
        conn,
        %{"public_id" => public_id, "media_public_id" => media_public_id} = params
      ) do
    with %{} = submission <-
           Contributions.get_submission_for_review(conn.assigns.current_scope, public_id),
         %Item{} = item <- Media.get_item(media_public_id),
         {:ok, _item} <- attach_media_item(conn, submission, item, params["action"]) do
      json(conn, %{ok: true})
    else
      nil ->
        send_resp(conn, :not_found, "Submission or media not found")

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message(reason)})
    end
  end

  def preview_media(conn, %{"public_id" => public_id, "media_public_id" => media_public_id}) do
    with %{} = submission <-
           Contributions.get_submission_for_review(conn.assigns.current_scope, public_id),
         %Item{} = item <- Media.get_item(media_public_id),
         {:ok, preview} <-
           Contributions.preview_submission_media(conn.assigns.current_scope, submission, item) do
      redirect(conn, external: preview.url)
    else
      nil -> send_resp(conn, :not_found, "Submission or media not found")
      {:error, _reason} -> send_resp(conn, :not_found, "Submission media not found")
    end
  end

  def remove_media(conn, %{"public_id" => public_id, "media_public_id" => media_public_id}) do
    with %{} = submission <-
           Contributions.get_submission_for_review(conn.assigns.current_scope, public_id),
         %Item{} = item <- Media.get_item(media_public_id),
         {:ok, _item} <-
           Contributions.remove_submission_media(conn.assigns.current_scope, submission, item) do
      conn
      |> put_flash(:info, "Media removed from the submission.")
      |> redirect(to: ~p"/moderator/submissions/#{submission.public_id}")
    else
      nil ->
        send_resp(conn, :not_found, "Submission or media not found")

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: ~p"/moderator/submissions/#{public_id}")
    end
  end

  defp decide(conn, submission, %{"decision" => "approve"} = params) do
    case Contributions.approve_submission(
           conn.assigns.current_scope,
           submission,
           params["note"],
           params["example_choices"] || %{},
           %{
             public_id: params["concept_public_id"],
             editorial_label: params["concept_editorial_label"],
             editorial_note: params["concept_editorial_note"]
           }
         ) do
      {:ok, %{entry: entry}} ->
        conn
        |> put_flash(:info, "Submission approved and published.")
        |> redirect(to: ~p"/entries/#{entry.public_id}")

      {:error, reason} ->
        decision_error(conn, submission, params, reason)
    end
  end

  defp decide(conn, submission, %{"decision" => decision} = params)
       when decision in ["reviewing", "rejected"] do
    status = decision_status(decision)

    case Contributions.moderate_submission(
           conn.assigns.current_scope,
           submission,
           status,
           params["note"]
         ) do
      {:ok, submission} ->
        conn
        |> put_flash(:info, decision_message(status))
        |> redirect(to: ~p"/moderator/submissions/#{submission.public_id}")

      {:error, reason} ->
        decision_error(conn, submission, params, reason)
    end
  end

  defp decide(conn, submission, params) do
    decision_error(conn, submission, params, :invalid_decision)
  end

  defp decision_error(conn, submission, params, reason) do
    status = if reason == :invalid_transition, do: :conflict, else: :unprocessable_entity

    conn
    |> put_status(status)
    |> put_flash(:error, error_message(reason))
    |> render_show(submission, params)
  end

  defp render_show(
         conn,
         submission,
         params \\ %{},
         edit_changeset \\ nil,
         concept_query \\ nil
       ) do
    edit_changeset =
      if submission.kind in [:new_entry, :correction, :addition, :example] do
        edit_changeset ||
          Contributions.change_submission_for_review(conn.assigns.current_scope, submission)
      end

    concept_query = concept_query || params["concept_query"] || ""
    concept_candidates = concept_candidates(concept_query, params["concept_public_id"])

    moderation_params =
      params
      |> Map.put_new(
        "concept_editorial_label",
        Contributions.effective_payload(submission)["primary_form"]
      )
      |> Map.put_new("concept_query", concept_query)

    {example_suggestions, example_match_error} = example_suggestions(submission)

    target_entry =
      if submission.target_type == "entry",
        do: Archive.get_public_entry(submission.target_public_id)

    example_choices =
      case params["example_choices"] do
        choices when is_map(choices) -> choices
        _other -> default_example_choices(example_suggestions)
      end

    render(conn, :show,
      page_title: "Review submission",
      submission: submission,
      target_entry: target_entry,
      form: Phoenix.Component.to_form(moderation_params, as: :moderation),
      edit_form: edit_changeset && Phoenix.Component.to_form(edit_changeset, as: :proposal),
      concept_search_form:
        Phoenix.Component.to_form(%{"query" => concept_query}, as: :concept_search),
      concept_candidates: concept_candidates,
      languages: Archive.list_active_languages(),
      example_suggestions: example_suggestions,
      example_choices: example_choices,
      example_match_error: example_match_error,
      media_items: Contributions.list_submission_media(conn.assigns.current_scope, submission)
    )
  end

  defp attach_media_item(conn, submission, item, "replace") do
    Contributions.replace_submission_audio(conn.assigns.current_scope, submission, item)
  end

  defp attach_media_item(conn, submission, item, "attach") do
    Contributions.attach_submission_media(conn.assigns.current_scope, submission, item)
  end

  defp attach_media_item(_conn, _submission, _item, _action), do: {:error, :invalid_media}

  defp concept_query(%{"concept_search" => %{"query" => query}}) when is_binary(query),
    do: query

  defp concept_query(_params), do: ""

  defp concept_candidates(query, selected_public_id) do
    selected = if selected_public_id, do: Archive.get_concept(selected_public_id)

    query
    |> Archive.search_concepts()
    |> then(fn concepts -> if selected, do: [selected | concepts], else: concepts end)
    |> Enum.uniq_by(& &1.id)
  end

  defp example_suggestions(submission) do
    case Contributions.suggest_example_links(submission) do
      {:ok, suggestions} -> {suggestions, nil}
      {:error, :example_too_long} -> {[], "Keep the example to 100 words or fewer."}
      {:error, _reason} -> {[], "The example could not be matched."}
    end
  end

  defp default_example_choices(suggestions) do
    suggestions
    |> Enum.with_index()
    |> Map.new(fn
      {%{role: :reference, candidates: [entry]}, index} ->
        {Integer.to_string(index), entry.public_id}

      {_suggestion, index} ->
        {Integer.to_string(index), ""}
    end)
  end

  defp decision_status("reviewing"), do: :reviewing
  defp decision_status("rejected"), do: :rejected

  defp decision_message(:reviewing), do: "Submission marked as reviewing."
  defp decision_message(:rejected), do: "Submission rejected."

  defp error_message(:review_note_required), do: "A note is required for this decision."

  defp error_message(:invalid_transition),
    do: "The submission status changed. Reload and try again."

  defp error_message(:unsupported_payload), do: "This submission payload cannot be approved."
  defp error_message(:target_not_found), do: "The target entry is no longer available."
  defp error_message(:language_inactive), do: "This submission's language is not active."
  defp error_message(:concept_not_found), do: "Choose an available concept or create a new one."
  defp error_message(:example_focus_missing), do: "The example must contain the proposed word."
  defp error_message(:invalid_example_links), do: "Choose valid entries for the example links."
  defp error_message(:example_too_long), do: "Keep the example to 100 words or fewer."
  defp error_message(:invalid_decision), do: "Choose a valid moderation decision."
  defp error_message(:audio_already_attached), do: "Replace the existing audio instead."
  defp error_message(:image_limit_reached), do: "A submission can have at most five images."
  defp error_message(:invalid_media_kind), do: "Choose media of the expected type."
  defp error_message(:invalid_media), do: "The uploaded media could not be attached."
  defp error_message(:already_exists), do: "That content is already published on this entry."

  defp error_message(%Ecto.Changeset{}),
    do: "Attached media must finish processing before approval."

  defp error_message(_reason), do: "The moderation decision could not be saved."
end
