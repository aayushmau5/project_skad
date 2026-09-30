defmodule Mix.Tasks.Skad.Moderator.Create do
  use Mix.Task

  @shortdoc "Creates a moderator account"

  @moduledoc """
  Creates a moderator account with a generated password shown once.

      mix skad.moderator.create EMAIL DISPLAY_NAME
  """

  @impl Mix.Task
  def run([email | display_name_parts]) when display_name_parts != [] do
    Mix.Task.run("app.start")

    password = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    case Skad.Accounts.create_moderator_account(%{
           email: email,
           display_name: Enum.join(display_name_parts, " "),
           password: password,
           password_confirmation: password
         }) do
      {:ok, account} ->
        Mix.shell().info("Created moderator #{account.email}")
        Mix.shell().info("Generated password (shown once): #{password}")

      {:error, changeset} ->
        Mix.raise("Could not create moderator: #{inspect(changeset.errors)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix skad.moderator.create EMAIL DISPLAY_NAME")
  end
end
