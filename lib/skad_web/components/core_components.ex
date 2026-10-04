defmodule SkadWeb.CoreComponents do
  @moduledoc """
  Provides the shared flash, form input, and icon components used by Skad.
  """
  use Phoenix.Component
  use Gettext, backend: SkadWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role={if @kind == :error, do: "alert", else: "status"}
      class={["flash", "flash-#{@kind}"]}
      {@rest}
    >
      <p :if={@title}><strong>{@title}</strong></p>
      <p>{msg}</p>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :description, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label checkbox-label">
          <input
            type="checkbox"
            id={@id}
            aria-invalid={if @errors != [], do: "true"}
            aria-describedby={error_description(@id, @errors, @rest)}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {Map.drop(@rest, [:"aria-describedby", :"aria-invalid"])}
          />{@label}
        </span>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"} class="field-errors">
        <p :for={msg <- @errors}>{msg}</p>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          aria-invalid={if @errors != [], do: "true"}
          aria-describedby={error_description(@id, @errors, @rest)}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {Map.drop(@rest, [:"aria-describedby", :"aria-invalid"])}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"} class="field-errors">
        <p :for={msg <- @errors}>{msg}</p>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
      </label>
      <p :if={@description} id={"#{@id}-description"} class="input-description help-text">
        {@description}
      </p>
      <textarea
        id={@id}
        aria-invalid={if @errors != [], do: "true"}
        aria-describedby={error_description(@id, @errors, @rest, @description)}
        name={@name}
        class={[
          @class || "w-full textarea",
          @errors != [] && (@error_class || "textarea-error")
        ]}
        {Map.drop(@rest, [:"aria-describedby", :"aria-invalid"])}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <div :if={@errors != []} id={"#{@id}-errors"} class="field-errors">
        <p :for={msg <- @errors}>{msg}</p>
      </div>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
      </label>
      <p :if={@description} id={"#{@id}-description"} class="input-description help-text">
        {@description}
      </p>
      <input
        type={@type}
        name={@name}
        id={@id}
        aria-invalid={if @errors != [], do: "true"}
        aria-describedby={error_description(@id, @errors, @rest, @description)}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        multiple={@multiple}
        class={[
          @class || "w-full input",
          @errors != [] && (@error_class || "input-error")
        ]}
        {Map.drop(@rest, [:"aria-describedby", :"aria-invalid"])}
      />
      <div :if={@errors != []} id={"#{@id}-errors"} class="field-errors">
        <p :for={msg <- @errors}>{msg}</p>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :languages, :list, required: true
  attr :include_all, :boolean, default: false

  def language_chips(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []
    assigns = assign(assigns, :errors, Enum.map(errors, &translate_error/1))

    ~H"""
    <fieldset
      id={@field.id}
      class="language-choices"
      aria-invalid={if @errors != [], do: "true"}
      aria-describedby={if @errors != [], do: "#{@field.id}-errors"}
    >
      <legend class="label">{@label}</legend>
      <div class="language-chips">
        <label :if={@include_all} class="language-chip">
          <input
            type="radio"
            id={"#{@field.id}_all"}
            name={@field.name}
            value=""
            checked={@field.value in [nil, ""]}
          />
          <span>{gettext("All languages")}</span>
        </label>
        <label :for={language <- @languages} class="language-chip">
          <input
            type="radio"
            id={"#{@field.id}_#{language.slug}"}
            name={@field.name}
            value={language.slug}
            checked={@field.value == language.slug}
            required={!@include_all}
            aria-invalid={if @errors != [], do: "true"}
            aria-describedby={if @errors != [], do: "#{@field.id}-errors"}
          />
          <span>{language_label(language)}</span>
        </label>
      </div>
      <p :if={@languages == [] && !@include_all} class="help-text">
        {gettext("No languages are available right now. Please try again later.")}
      </p>
      <div :if={@errors != []} id={"#{@field.id}-errors"} class="field-errors">
        <p :for={message <- @errors}>{message}</p>
      </div>
    </fieldset>
    """
  end

  def language_label(%{name: "Hindi"}), do: gettext("Hindi")
  def language_label(%{name: "Hamskad"}), do: gettext("Hamskad")
  def language_label(%{name: "Navaskad"}), do: gettext("Navaskad")
  def language_label(%{name: "Pahari Kinnauri"}), do: gettext("Pahari Kinnauri")
  def language_label(%{name: name}), do: name

  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, required: true

  def form_errors(assigns) do
    ~H"""
    <p :if={@form.errors != []} id={@id} class="flash flash-error" role="alert">
      {gettext("Check the highlighted fields. Your entered information is still here.")}
    </p>
    """
  end

  defp error_description(id, errors, rest, description \\ nil) do
    [
      rest[:"aria-describedby"],
      if(description, do: "#{id}-description"),
      if(errors != [], do: "#{id}-errors")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      description -> description
    end
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(SkadWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SkadWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
