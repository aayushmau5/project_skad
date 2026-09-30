defmodule Skad.Seeds do
  alias Skad.Archive
  alias Skad.Archive.Example
  alias Skad.Repo

  @seed_path Path.join(__DIR__, "seeds.json")

  def run do
    data = @seed_path |> File.read!() |> Jason.decode!()
    languages = seed_languages(Map.fetch!(data, "languages"))
    entries = seed_meanings(Map.fetch!(data, "meanings"), languages)
    seed_examples(Map.get(data, "examples", []), languages, entries)
  end

  defp seed_languages(language_attrs) do
    Map.new(language_attrs, fn attrs ->
      slug = Map.fetch!(attrs, "slug")
      language = Archive.get_language_by_slug(slug) || ok!(Archive.create_language(attrs))
      {slug, language}
    end)
  end

  defp seed_meanings(meanings, languages) do
    Enum.reduce(meanings, %{}, fn meaning, seeded_entries ->
      concept_attrs = Map.fetch!(meaning, "concept")
      entry_specs = Map.fetch!(meaning, "entries")
      seed_meaning(concept_attrs, entry_specs, languages, seeded_entries)
    end)
  end

  defp seed_meaning(_concept_attrs, [], _languages, _seeded_entries) do
    raise "a seeded meaning must contain at least one entry"
  end

  defp seed_meaning(concept_attrs, entry_specs, languages, seeded_entries) do
    concept_label = Map.fetch!(concept_attrs, "editorial_label")

    {source_spec, source_entry} =
      Enum.find_value(entry_specs, fn spec ->
        language = language!(languages, spec)

        case existing_entry(spec, language, &(&1.concept.editorial_label == concept_label)) do
          nil -> nil
          entry -> {spec, entry}
        end
      end) || seed_first_entry(concept_attrs, hd(entry_specs), languages)

    seeded_entries = put_entry!(seeded_entries, source_spec, source_entry)

    entry_specs
    |> List.delete(source_spec)
    |> Enum.reduce(seeded_entries, fn spec, entries ->
      language = language!(languages, spec)

      entry =
        existing_entry(spec, language, &(&1.concept_id == source_entry.concept_id)) ||
          ok!(Archive.publish_equivalent(source_entry, language, entry_attrs(spec)))

      put_entry!(entries, spec, entry)
    end)
  end

  defp seed_first_entry(concept_attrs, spec, languages) do
    language = language!(languages, spec)
    entry = ok!(Archive.publish_new_meaning(language, entry_attrs(spec, concept_attrs)))
    {spec, entry}
  end

  defp existing_entry(spec, language, matches_concept?) do
    primary_text =
      spec
      |> Map.fetch!("forms")
      |> Enum.find(& &1["is_primary"])
      |> case do
        nil -> raise "seeded entry #{inspect(spec["key"])} needs one primary form"
        form -> Map.fetch!(form, "text")
      end

    primary_text
    |> Archive.exact_lookup(language)
    |> Enum.map(& &1.entry)
    |> Enum.find(matches_concept?)
  end

  defp seed_examples(examples, languages, entries) do
    Enum.each(examples, fn spec ->
      language = language!(languages, spec)
      example_attrs = Map.fetch!(spec, "example")

      unless Repo.get_by(Example, language_id: language.id, text: example_attrs["text"]) do
        links =
          spec
          |> Map.fetch!("links")
          |> Enum.map(fn link ->
            entry = Map.fetch!(entries, Map.fetch!(link, "entry"))

            link
            |> Map.delete("entry")
            |> Map.put("entry_public_id", entry.public_id)
          end)

        ok!(
          Archive.publish_usage_example(language, %{
            "example" => example_attrs,
            "links" => links
          })
        )
      end
    end)
  end

  defp entry_attrs(spec, concept_attrs \\ nil) do
    %{
      "concept" => concept_attrs,
      "entry" => Map.fetch!(spec, "entry"),
      "forms" => Map.fetch!(spec, "forms")
    }
  end

  defp language!(languages, spec) do
    Map.fetch!(languages, Map.fetch!(spec, "language"))
  end

  defp put_entry!(entries, spec, entry) do
    key = Map.fetch!(spec, "key")

    if Map.has_key?(entries, key) do
      raise "duplicate seeded entry key #{inspect(key)}"
    else
      Map.put(entries, key, entry)
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("could not seed archive: #{inspect(reason)}")
end

Skad.Seeds.run()
