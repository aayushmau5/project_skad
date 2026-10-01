defmodule SkadWeb.ContributionHTML do
  use SkadWeb, :html

  embed_templates "contribution_html/*"

  defdelegate primary_form_text(entry), to: SkadWeb.PageHTML

  def status_label(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
