defmodule SkadWeb.ContributionHTML do
  use SkadWeb, :html

  embed_templates "contribution_html/*"

  defdelegate primary_form_text(entry), to: SkadWeb.PageHTML

  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, required: true

  def media_context(assigns) do
    ~H"""
    <div id={@id} class="media-controls">
      <p>
        {gettext("Only share recordings or images you have permission to make public after review.")}
      </p>
      <.input
        field={@form[:place_label]}
        type="text"
        label={gettext("Village or community (optional)")}
        class="auth-input"
        data-media-place
      />
      <.input
        field={@form[:variety_label]}
        type="text"
        label={gettext("Local language variety (optional)")}
        class="auth-input"
        data-media-variety
      />
      <.input
        field={@form[:attribution_text]}
        type="text"
        label={gettext("Speaker or photographer credit (optional, public)")}
        class="auth-input"
        data-media-attribution
      />
      <.input
        field={@form[:permission]}
        type="checkbox"
        label={gettext("I have permission to share this media publicly after review.")}
        data-media-permission
      />
      <noscript><p>
        {gettext(
          "Recording and uploads need JavaScript. You can still send a word or text suggestion."
        )}
      </p></noscript>
    </div>
    """
  end

  def entry_change_title(:correction), do: gettext("Suggest a correction")
  def entry_change_title(:addition), do: gettext("Add information")
  def entry_change_title(:example), do: gettext("Add an example")
  def entry_change_title(:audio), do: gettext("Add pronunciation audio")
  def entry_change_title(:image), do: gettext("Add cultural images")

  def entry_change_action(:correction, entry), do: ~p"/entries/#{entry.public_id}/corrections"
  def entry_change_action(:addition, entry), do: ~p"/entries/#{entry.public_id}/additions"
  def entry_change_action(:example, entry), do: ~p"/entries/#{entry.public_id}/examples"
  def entry_change_action(:audio, entry), do: ~p"/entries/#{entry.public_id}/audio"
  def entry_change_action(:image, entry), do: ~p"/entries/#{entry.public_id}/images"

  def status_label(:pending), do: gettext("Waiting for review")
  def status_label(:reviewing), do: gettext("Under review")
  def status_label(:approved), do: gettext("Published")
  def status_label(:rejected), do: gettext("Not published")
  def status_label(:clarification_needed), do: gettext("More information needed")
  def status_label(:withdrawn), do: gettext("Withdrawn")
end
