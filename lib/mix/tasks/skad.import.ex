defmodule Mix.Tasks.Skad.Import do
  use Mix.Task

  @shortdoc "Imports a prepared dataset into an explicitly selected SQLite database"
  @moduledoc """
  Imports a prepared JSON manifest, migrating the target database first.
  Starts only the repository and never loads demo seeds or starts the web server.

      mix skad.import MANIFEST.json --database PATH [--fresh]

  --database is required, so the development database cannot be selected accidentally.
  --fresh refuses an existing file. Reruns without --fresh skip imported UUIDs.
  The repository is stopped and its WAL checkpointed before the task exits.
  """

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [database: :string, fresh: :boolean])

    unless invalid == [] and length(paths) == 1 and opts[:database] do
      Mix.raise("Usage: mix skad.import MANIFEST.json --database PATH [--fresh]")
    end

    manifest = load_manifest!(hd(paths))
    database = Path.expand(opts[:database])

    Mix.Task.run("app.config")

    if Process.whereis(Skad.Repo) do
      Mix.raise("Run skad.import in a separate Mix process with the repository stopped")
    end

    File.mkdir_p!(Path.dirname(database))
    if opts[:fresh], do: reserve_fresh_database!(database)
    config = Application.fetch_env!(:skad, Skad.Repo)

    Application.put_env(
      :skad,
      Skad.Repo,
      config |> Keyword.put(:database, database) |> Keyword.put(:log, false)
    )

    try do
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(Skad.Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true, log: false)

          case Skad.Archive.Ingestion.import(manifest) do
            {:ok, counts} ->
              verify_database!(repo)
              counts

            {:error, reason} ->
              Mix.raise("Import rolled back: #{inspect(reason)}")
          end
        end)

      Mix.shell().info(
        "Imported #{result.inserted} entries; skipped #{result.skipped} existing entries"
      )

      Mix.shell().info("Database: #{database}")
    after
      Application.put_env(:skad, Skad.Repo, config)
    end
  end

  defp load_manifest!(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"version" => 1, "language" => language, "meanings" => meanings} = data} <-
           Jason.decode(content),
         true <- is_map(language) and is_list(meanings) and meanings != [] do
      data
    else
      reason -> Mix.raise("Could not read a version 1 manifest: #{inspect(reason)}")
    end
  end

  defp reserve_fresh_database!(database) do
    if File.exists?(database <> "-wal") or File.exists?(database <> "-shm") do
      Mix.raise("Refusing existing SQLite sidecar files for #{database}")
    end

    case File.open(database, [:write, :exclusive]) do
      {:ok, file} -> File.close(file)
      {:error, reason} -> Mix.raise("Cannot create fresh database #{database}: #{reason}")
    end
  end

  defp verify_database!(repo) do
    unless repo.query!("PRAGMA quick_check").rows == [["ok"]] and
             repo.query!("PRAGMA foreign_key_check").rows == [] do
      Mix.raise("Database integrity check failed")
    end

    case repo.query!("PRAGMA wal_checkpoint(TRUNCATE)").rows do
      [[0, _log, _checkpointed]] -> :ok
      _busy -> Mix.raise("Could not checkpoint SQLite WAL; do not copy this database yet")
    end
  end
end
