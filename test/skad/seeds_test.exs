defmodule Skad.SeedsTest do
  use Skad.DataCase

  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink
  alias Skad.Archive.Language

  test "loads the JSON seed data into the real database and can be rerun" do
    seed_path = Path.expand("../../priv/repo/seeds.json", __DIR__)
    seed_data = seed_path |> File.read!() |> Jason.decode!()
    entries = for meaning <- seed_data["meanings"], entry <- meaning["entries"], do: entry

    Code.eval_file(Path.expand("../../priv/repo/seeds.exs", __DIR__))
    apply(Module.concat(["Skad", "Seeds"]), :run, [])

    assert Repo.aggregate(Language, :count) == length(seed_data["languages"])
    assert Archive.get_language_by_slug("navaskad").name == "Navaskad"
    assert Archive.get_language_by_slug("pahari-kinnauri").code == "kjo"
    assert Repo.aggregate(Concept, :count) == length(seed_data["meanings"])
    assert Repo.aggregate(Entry, :count) == length(entries)
    assert Repo.aggregate(EntryForm, :count) == Enum.sum(Enum.map(entries, &length(&1["forms"])))
    assert Repo.aggregate(Example, :count) == length(seed_data["examples"])

    assert Repo.aggregate(ExampleLink, :count) ==
             Enum.sum(Enum.map(seed_data["examples"], &length(&1["links"])))

    hindi = Archive.get_language_by_slug("hindi")
    assert [%{entry: entry, matched_form: form}] = Archive.search("pani", hindi)
    assert form.text == "Pani"
    assert entry.concept.editorial_label == "WATER"
  end
end
