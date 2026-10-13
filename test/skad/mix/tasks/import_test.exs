defmodule Mix.Tasks.Skad.ImportTest do
  use ExUnit.Case, async: true

  test "requires an explicit database and rejects unknown options before writing" do
    for args <- [[], ["manifest.json"], ["manifest.json", "--database", "target.db", "--force"]] do
      assert_raise Mix.Error, ~r/Usage:/, fn -> Mix.Tasks.Skad.Import.run(args) end
    end
  end

  test "rejects an invalid manifest before creating the database" do
    database = Path.join(System.tmp_dir!(), "skad-invalid-import-#{Ecto.UUID.generate()}.db")

    assert_raise Mix.Error, ~r/Could not read a version 1 manifest/, fn ->
      Mix.Tasks.Skad.Import.run(["missing-manifest.json", "--database", database, "--fresh"])
    end

    refute File.exists?(database)
  end
end
