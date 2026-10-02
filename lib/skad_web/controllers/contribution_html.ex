defmodule SkadWeb.ContributionHTML do
  use SkadWeb, :html

  embed_templates "contribution_html/*"

  defdelegate primary_form_text(entry), to: SkadWeb.PageHTML

  def entry_change_title(:correction), do: "Suggest a correction"
  def entry_change_title(:addition), do: "Add information"
  def entry_change_title(:example), do: "Add an example"
  def entry_change_title(:audio), do: "Add pronunciation audio"
  def entry_change_title(:image), do: "Add cultural images"

  def entry_change_action(:correction, entry), do: ~p"/entries/#{entry.public_id}/corrections"
  def entry_change_action(:addition, entry), do: ~p"/entries/#{entry.public_id}/additions"
  def entry_change_action(:example, entry), do: ~p"/entries/#{entry.public_id}/examples"
  def entry_change_action(:audio, entry), do: ~p"/entries/#{entry.public_id}/audio"
  def entry_change_action(:image, entry), do: ~p"/entries/#{entry.public_id}/images"

  def status_label(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
