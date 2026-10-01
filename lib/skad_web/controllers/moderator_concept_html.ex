defmodule SkadWeb.ModeratorConceptHTML do
  use SkadWeb, :html

  embed_templates "moderator_concept_html/*"

  def entry_label(entry) do
    "#{SkadWeb.PageHTML.primary_form_text(entry)} — #{entry.language.name}"
  end
end
