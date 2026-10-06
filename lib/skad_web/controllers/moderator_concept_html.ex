defmodule SkadWeb.ModeratorConceptHTML do
  use SkadWeb, :html

  embed_templates "moderator_concept_html/*"

  def entry_label(entry) do
    "#{SkadWeb.PageHTML.primary_form_text(entry)} — #{entry.language.name}"
  end

  def concepts_path(query, page, locale) do
    ~p"/moderator/concepts?#{%{search: %{query: query}, page: page, ui_language: locale}}"
  end

  attr :matches, :map, required: true
  attr :checked?, :boolean, required: true

  def concept_matches(assigns) do
    ~H"""
    <div id="concept-match-results">
      <p :if={@checked?} id="concept-match-message" role="status">
        <%= cond do %>
          <% @matches.exact? -> %>
            {gettext(
              "A concept with this name already exists. Open it below instead of creating it again."
            )}
          <% @matches.concepts != [] -> %>
            {gettext("These concepts may be related. Check them before creating a new one.")}
          <% true -> %>
            {gettext("No matching concepts found.")}
        <% end %>
      </p>
      <ul :if={@matches.concepts != []} id="concept-matches" class="result-list">
        <li
          :for={concept <- @matches.concepts}
          id={"matching-concept-#{concept.public_id}"}
          class="result-card"
        >
          <.link href={~p"/moderator/concepts/#{concept.public_id}"} class="result-link">
            {concept.editorial_label}
          </.link>
          <p :if={concept.editorial_note}>{concept.editorial_note}</p>
          <p class="result-meta">{gettext("Entries: %{count}", count: length(concept.entries))}</p>
        </li>
      </ul>
    </div>
    """
  end
end
