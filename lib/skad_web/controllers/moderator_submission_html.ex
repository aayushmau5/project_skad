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

  def format_time(nil), do: nil
  def format_time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
end
