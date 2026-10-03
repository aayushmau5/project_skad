defmodule SkadWeb.ModeratorSubmissionHTML do
  use SkadWeb, :html

  alias Skad.Contributions

  embed_templates "moderator_submission_html/*"

  attr :submissions, :list, required: true
  attr :next_cursor, :string, default: nil
  attr :selected, :string, default: nil
  attr :cursor, :string, default: nil

  def review_queue(assigns) do
    ~H"""
    <aside id="moderator-submission-queue" class="review-queue" aria-labelledby="review-queue-heading">
      <h2 id="review-queue-heading">{gettext("Review queue")}</h2>
      <p :if={@submissions == []} id="empty-submission-queue">
        {gettext("No submissions need review.")}
      </p>
      <ol :if={@submissions != []} class="result-list">
        <li
          :for={submission <- @submissions}
          id={"submission-#{submission.public_id}"}
          class="result-card"
        >
          <.link
            id={"review-submission-#{submission.public_id}"}
            href={review_path(submission, @cursor)}
            aria-current={if @selected == submission.public_id, do: "page"}
          >
            <span>{payload_value(submission, "primary_form") || gettext("Untitled submission")}</span>
            <span class="result-meta"> · {status_label(submission.kind)} · {status_label(
              submission.status
            )}</span>
            <span class="result-meta">{format_time(submission.received_at)}</span>
          </.link>
        </li>
      </ol>
      <p :if={@next_cursor}>
        <.link id="next-submissions-page" href={~p"/moderator/submissions?after=#{@next_cursor}"}>{gettext(
          "Next submissions"
        )}</.link>
      </p>
    </aside>
    """
  end

  attr :submission, :map, required: true

  def proposal(assigns) do
    ~H"""
    <section id="submission-payload" class="entry-section">
      <h2>
        {if @submission.reviewed_payload,
          do: gettext("Reviewed proposal"),
          else: gettext("Proposal")}
      </h2>
      <dl>
        <dt>{gettext("Kind")}</dt>
        <dd>{status_label(@submission.kind)}</dd>
        <dt>{gettext("Language")}</dt>
        <dd id="submission-language">{payload_value(@submission, "language_slug")}</dd>
        <dt :if={@submission.kind in [:new_entry, :correction]}>{gettext("Meaning")}</dt>
        <dd
          :if={@submission.kind in [:new_entry, :correction]}
          phx-no-format
          id="submission-definition"
        >{payload_value(@submission, "definition") || "—"}</dd>
        <dt :if={@submission.kind in [:new_entry, :correction]}>{gettext("Part of speech")}</dt>
        <dd :if={@submission.kind in [:new_entry, :correction]}>
          {payload_value(@submission, "part_of_speech") || "—"}
        </dd>
        <dt :if={@submission.kind in [:new_entry, :correction]}>{gettext("Usage note")}</dt>
        <dd :if={@submission.kind in [:new_entry, :correction]}>
          {payload_value(@submission, "usage_note") || "—"}
        </dd>
        <dt :if={@submission.kind in [:new_entry, :correction]}>
          {gettext("Cultural context")}
        </dt>
        <dd :if={@submission.kind in [:new_entry, :correction]}>
          {payload_value(@submission, "cultural_note") || "—"}
        </dd>
        <dt :if={@submission.kind == :addition}>{gettext("Alternate form")}</dt>
        <dd :if={@submission.kind == :addition} id="submission-alternate-form">
          {payload_value(@submission, "alternate_form") || "—"}
        </dd>
        <dt :if={@submission.kind == :addition}>{gettext("Form type")}</dt>
        <dd :if={@submission.kind == :addition}>
          {payload_value(@submission, "form_kind") || "—"}
        </dd>
        <dt :if={@submission.kind in [:new_entry, :addition, :example]}>
          {gettext("Example")}
        </dt>
        <dd :if={@submission.kind in [:new_entry, :addition, :example]} id="submission-example">
          {payload_value(@submission, "example") || "—"}
        </dd>
        <dt>{gettext("Received")}</dt>
        <dd>{format_time(@submission.received_at)}</dd>
        <dt>{gettext("Receipt")}</dt>
        <dd><code>{@submission.public_id}</code></dd>
      </dl>
    </section>
    """
  end

  def queue_query(nil), do: %{}
  def queue_query(cursor), do: %{"after" => cursor}

  defp review_path(submission, nil), do: ~p"/moderator/submissions/#{submission.public_id}"

  defp review_path(submission, cursor),
    do: ~p"/moderator/submissions/#{submission.public_id}?after=#{cursor}"

  def status_label(status) when is_atom(status), do: status |> Atom.to_string() |> status_label()

  def status_label("pending"), do: gettext("Pending")
  def status_label("reviewing"), do: gettext("Reviewing")
  def status_label("approved"), do: gettext("Approved")
  def status_label("rejected"), do: gettext("Rejected")
  def status_label("clarification_needed"), do: gettext("More information needed")
  def status_label("withdrawn"), do: gettext("Withdrawn")
  def status_label("new_entry"), do: gettext("New word")
  def status_label("correction"), do: gettext("Correction")
  def status_label("addition"), do: gettext("Addition")
  def status_label("example"), do: gettext("Example")
  def status_label("audio"), do: gettext("Pronunciation audio")
  def status_label("image"), do: gettext("Cultural image")
  def status_label("uploaded"), do: gettext("Uploaded")
  def status_label("validated"), do: gettext("Validated")
  def status_label("processing"), do: gettext("Processing")
  def status_label("ready"), do: gettext("Ready")
  def status_label("failed"), do: gettext("Failed")
  def status_label("edited"), do: gettext("Edited")
  def status_label("media_attached"), do: gettext("Media attached")
  def status_label("audio_replaced"), do: gettext("Audio replaced")
  def status_label("media_removed"), do: gettext("Media removed")
  def status_label(_status), do: gettext("Unknown")

  def payload_value(submission, key) do
    submission |> Contributions.effective_payload() |> Map.get(key)
  end

  def original_payload_value(submission, key), do: Map.get(submission.payload, key)

  defdelegate example_segments(text, suggestions), to: SkadWeb.PageHTML, as: :text_segments

  def example_candidate_options(suggestion) do
    Enum.map(suggestion.candidates, fn entry ->
      definition = SkadWeb.PageHTML.first_definition(entry)
      label = SkadWeb.PageHTML.primary_form_text(entry)
      label = if definition, do: "#{label} — #{definition}", else: label
      {label, entry.public_id}
    end)
  end

  def concept_candidate_options(concepts) do
    Enum.map(concepts, fn concept ->
      entries =
        concept.entries
        |> Enum.take(3)
        |> Enum.map(&SkadWeb.PageHTML.primary_form_text/1)

      label =
        if entries == [],
          do: concept.editorial_label,
          else: "#{concept.editorial_label} — #{Enum.join(entries, ", ")}"

      {label, concept.public_id}
    end)
  end

  def example_approvable?(submission, suggestions, error) do
    is_nil(payload_value(submission, "example")) or
      (is_nil(error) and Enum.any?(suggestions, &(&1.role == :focus)))
  end

  def media_approvable?(%{kind: :audio}, media_items),
    do:
      length(media_items) == 1 and
        Enum.all?(media_items, &(&1.kind == :audio and &1.processing_state == :ready))

  def media_approvable?(%{kind: :image}, media_items),
    do:
      media_items != [] and length(media_items) <= 5 and
        Enum.all?(media_items, &(&1.kind == :image and &1.processing_state == :ready))

  def media_approvable?(_submission, media_items),
    do: Enum.all?(media_items, &(&1.processing_state == :ready))

  def format_time(nil), do: nil
  def format_time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
end
