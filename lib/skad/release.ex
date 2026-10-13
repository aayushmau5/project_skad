defmodule Skad.Release do
  @moduledoc "Bootstraps the disposable review release without touching normal production data."

  alias Skad.Accounts
  alias Skad.Repo

  def prepare_review do
    unless Application.get_env(:skad, :review_instance, false),
      do: raise("The review startup requires SKAD_REVIEW_INSTANCE=true")

    database = Repo.config()[:database]

    unless File.exists?(database) do
      File.mkdir_p!(Path.dirname(database))
      File.cp!(Application.app_dir(:skad, "priv/review/skad.sqlite3"), database)
    end

    {:ok, :ok, _apps} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
        password = System.fetch_env!("SKAD_REVIEW_MODERATOR_PASSWORD")
        email = "reviewer@skad.example"

        unless Accounts.get_moderator_account_by_email(email) do
          {:ok, _account} =
            Accounts.create_moderator_account(%{
              email: email,
              display_name: "Review Moderator",
              password: password,
              password_confirmation: password
            })
        end

        :ok
      end)

    :ok
  end
end
