defmodule SkadWeb.ModeratorSubmissionHTML do
  use SkadWeb, :html

  alias Skad.Contributions

  embed_templates "moderator_submission_html/*"

  def status_label(status) when is_atom(status), do: status |> Atom.to_string() |> status_label()

  def status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def status_label(_status), do: "Unknown"

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

  def example_approvable?(submission, suggestions, error) do
    is_nil(payload_value(submission, "example")) or
      (is_nil(error) and Enum.any?(suggestions, &(&1.role == :focus)))
  end

  def format_time(nil), do: nil
  def format_time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
end
