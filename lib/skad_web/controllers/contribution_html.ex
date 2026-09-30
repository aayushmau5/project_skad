defmodule SkadWeb.ContributionHTML do
  use SkadWeb, :html

  embed_templates "contribution_html/*"

  def status_label(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
