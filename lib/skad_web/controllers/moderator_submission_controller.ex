defmodule SkadWeb.ModeratorSubmissionController do
  use SkadWeb, :controller

  alias Skad.Archive
  alias Skad.Contributions

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Submission queue",
      submissions: Contributions.list_submissions_for_review(conn.assigns.current_scope)
    )
  end

  def show(conn, %{"public_id" => public_id}) do
    case Contributions.get_submission_for_review(conn.assigns.current_scope, public_id) do
      nil -> send_resp(conn, :not_found, "Submission not found")
      submission -> render_show(conn, submission)
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

  defp decide(conn, submission, %{"decision" => "approve"} = params) do
    case Contributions.approve_submission(
           conn.assigns.current_scope,
           submission,
           params["note"],
           params["example_choices"] || %{}
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

  defp render_show(conn, submission, params \\ %{}, edit_changeset \\ nil) do
    edit_changeset =
      edit_changeset ||
        Contributions.change_submission_for_review(conn.assigns.current_scope, submission)

    {example_suggestions, example_match_error} = example_suggestions(submission)

    example_choices =
      case params["example_choices"] do
        choices when is_map(choices) -> choices
        _other -> default_example_choices(example_suggestions)
      end

    render(conn, :show,
      page_title: "Review submission",
      submission: submission,
      form: Phoenix.Component.to_form(params, as: :moderation),
      edit_form: Phoenix.Component.to_form(edit_changeset, as: :proposal),
      languages: Archive.list_active_languages(),
      example_suggestions: example_suggestions,
      example_choices: example_choices,
      example_match_error: example_match_error
    )
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
  defp error_message(:language_inactive), do: "This submission's language is not active."
  defp error_message(:example_focus_missing), do: "The example must contain the proposed word."
  defp error_message(:invalid_example_links), do: "Choose valid entries for the example links."
  defp error_message(:example_too_long), do: "Keep the example to 100 words or fewer."
  defp error_message(:invalid_decision), do: "Choose a valid moderation decision."
  defp error_message(_reason), do: "The moderation decision could not be saved."
end
