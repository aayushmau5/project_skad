defmodule Mix.Tasks.Skad.Benchmark do
  use Mix.Task

  @requirements ["app.config"]

  alias Skad.Archive
  alias Skad.Archive.Concept
  alias Skad.Archive.Entry
  alias Skad.Archive.EntryForm
  alias Skad.Archive.Example
  alias Skad.Archive.ExampleLink
  alias Skad.Archive.Language
  alias Skad.Archive.LocalizedText
  alias Skad.Archive.Search
  alias Skad.Media
  alias Skad.Media.Item
  alias Skad.Repo

  @shortdoc "Benchmarks the representative SQLite and HTTP workload"

  @moduledoc """
  Builds and measures an isolated synthetic archive using the PD-018 workload.

      mix skad.benchmark --database /tmp/skad-pd018.sqlite3 --reset

  The default workload contains 100,000 entries, 300,000 forms, 200,000
  examples, and 100,000 media rows. It measures warm-cache query latency,
  query plans, twenty concurrent readers with one writer, and the public search
  and entry HTTP paths. ApacheBench (`ab`) is required for the HTTP measurements.

  Use a smaller dataset for a quick harness check:

      mix skad.benchmark --database /tmp/skad-smoke.sqlite3 --entries 1000 --samples 50 --http-requests 100 --reset

  `--reset` deletes only the exact database path supplied with `--database`,
  including its SQLite WAL and shared-memory files. Never point it at production.
  Pass `--skip-seed` to reuse an already prepared database or `--skip-http` when
  only database measurements are needed.
  """

  @switches [
    database: :string,
    entries: :integer,
    samples: :integer,
    readers: :integer,
    http_requests: :integer,
    port: :integer,
    reset: :boolean,
    skip_seed: :boolean,
    skip_http: :boolean
  ]

  @budgets_us %{
    exact_form: 10_000,
    autocomplete: 20_000,
    full_text: 50_000,
    entry_page: 25_000
  }

  @batch_size 500

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Invalid arguments. Run `mix help skad.benchmark` for usage.")
    end

    database = required_database!(opts)
    entry_count = positive_option!(opts, :entries, 100_000)
    samples = positive_option!(opts, :samples, 500)
    readers = positive_option!(opts, :readers, 20)
    http_requests = positive_option!(opts, :http_requests, 2_000)
    port = positive_option!(opts, :port, 4_100)
    reset? = Keyword.get(opts, :reset, false)
    skip_seed? = Keyword.get(opts, :skip_seed, false)
    skip_http? = Keyword.get(opts, :skip_http, false)

    validate_database_target!(database, reset?, skip_seed?)
    reset_database!(database, reset?)
    configure_repo(database)
    configure_endpoint(port, not skip_http?)
    migrate!()
    start_application!()
    Logger.configure(level: :warning)

    tune_database()
    seed!(entry_count, skip_seed?)
    verify_counts!(entry_count)
    Repo.query!("PRAGMA optimize")

    Mix.shell().info("\nEnvironment")
    Mix.shell().info("  database: #{database}")
    Mix.shell().info("  database size: #{format_megabytes(File.stat!(database).size)}")
    Mix.shell().info("  entries: #{format_integer(entry_count)}")
    Mix.shell().info("  samples per operation: #{format_integer(samples)}")
    Mix.shell().info("  Mix environment: #{Mix.env()}")
    Mix.shell().info("  repo pool size: #{repo_pool_size()}")
    Mix.shell().info("  BEAM schedulers: #{:erlang.system_info(:schedulers_online)}")
    Mix.shell().info("  system: #{system_description()}")

    plans = explain_query_plans(entry_count)
    database_results = measure_database(entry_count, samples)
    concurrent_result = measure_concurrency(entry_count, samples, readers)

    http_results =
      if skip_http? do
        []
      else
        measure_http(entry_count, http_requests, readers, port)
      end

    print_plans(plans)
    print_database_results(database_results)
    print_concurrent_result(concurrent_result)
    print_http_results(http_results)
    print_memory(database)

    failures =
      Enum.reject(database_results, & &1.passed?) ++
        if(concurrent_result.errors == 0, do: [], else: [concurrent_result]) ++
        Enum.reject(http_results, &(&1.failed_requests == 0))

    if failures != [] do
      Mix.raise("Benchmark completed with failed budgets or request errors")
    end
  end

  defp required_database!(opts) do
    case opts[:database] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _other -> Mix.raise("--database PATH is required and must name an isolated database")
    end
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> Mix.raise("--#{String.replace(to_string(key), "_", "-")} must be positive")
    end
  end

  defp reset_database!(_database, false), do: :ok

  defp reset_database!(database, true) do
    Enum.each([database, database <> "-wal", database <> "-shm"], fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Mix.raise("Could not remove #{path}: #{:file.format_error(reason)}")
      end
    end)
  end

  defp validate_database_target!(database, reset?, skip_seed?) do
    if File.exists?(database) and not reset? and not skip_seed? do
      Mix.raise(
        "Benchmark database already exists; pass --skip-seed to reuse a verified benchmark " <>
          "database or --reset to replace this exact path: #{database}"
      )
    end
  end

  defp configure_repo(database) do
    config =
      :skad
      |> Application.fetch_env!(Repo)
      |> Keyword.put(:database, database)
      |> Keyword.delete(:pool)

    Application.put_env(:skad, Repo, config)
  end

  defp configure_endpoint(port, enabled?) do
    config = Application.fetch_env!(:skad, SkadWeb.Endpoint)
    http = Keyword.merge(config[:http] || [], ip: {127, 0, 0, 1}, port: port)

    config =
      config
      |> Keyword.put(:server, enabled?)
      |> Keyword.put(:http, http)
      |> Keyword.put(:code_reloader, false)
      |> Keyword.delete(:live_reload)
      |> Keyword.delete(:watchers)

    Application.put_env(:skad, SkadWeb.Endpoint, config)
    Application.put_env(:skad, :dev_routes, false)
  end

  defp migrate! do
    case Ecto.Migrator.with_repo(
           Repo,
           &Ecto.Migrator.run(&1, :up, all: true, log: false),
           mode: :temporary,
           pool_size: 1
         ) do
      {:ok, _versions, _apps} -> :ok
      {:error, reason} -> Mix.raise("Could not migrate benchmark database: #{inspect(reason)}")
    end
  end

  defp start_application! do
    case Application.ensure_all_started(:skad) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("Could not start benchmark application: #{inspect(reason)}")
    end
  end

  defp tune_database do
    Repo.query!("PRAGMA journal_mode = WAL")
    Repo.query!("PRAGMA synchronous = NORMAL")
    Repo.query!("PRAGMA foreign_keys = ON")
  end

  defp seed!(_entry_count, true) do
    verify_benchmark_marker!()
    Mix.shell().info("Reusing the verified benchmark dataset")
  end

  defp seed!(entry_count, false) do
    existing = count("entries")

    cond do
      existing == entry_count ->
        Mix.shell().info(
          "Benchmark dataset already contains #{format_integer(entry_count)} entries"
        )

      existing != 0 ->
        Mix.raise(
          "Benchmark database contains #{existing} entries; use the expected --entries value, " <>
            "choose another database, or pass --reset"
        )

      true ->
        Mix.shell().info("Seeding #{format_integer(entry_count)} representative entries...")
        started = System.monotonic_time()
        insert_language!()

        1..entry_count
        |> Enum.chunk_every(@batch_size)
        |> Enum.with_index(1)
        |> Enum.each(fn {ids, batch_number} ->
          insert_batch!(ids)

          if rem(batch_number, 20) == 0 or List.last(ids) == entry_count do
            Mix.shell().info("  seeded #{format_integer(List.last(ids))} entries")
          end
        end)

        seconds = elapsed_seconds(started)
        write_benchmark_marker!(entry_count)
        Mix.shell().info("Seeded representative dataset in #{Float.round(seconds, 1)} seconds")
    end
  end

  defp write_benchmark_marker!(entry_count) do
    Repo.query!("""
    CREATE TABLE skad_benchmark_metadata (
      format INTEGER NOT NULL,
      entry_count INTEGER NOT NULL,
      CHECK (format = 1),
      CHECK (entry_count > 0)
    )
    """)

    Repo.query!("INSERT INTO skad_benchmark_metadata(format, entry_count) VALUES (1, ?)", [
      entry_count
    ])
  end

  defp verify_benchmark_marker! do
    marker_exists =
      Repo.query!(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'skad_benchmark_metadata'"
      ).rows == [[1]]

    unless marker_exists do
      Mix.raise("--skip-seed requires a database created by mix skad.benchmark")
    end
  end

  defp insert_language! do
    Repo.insert_all(Language, [
      %{
        id: 1,
        public_id: uuid("00000001", 1),
        slug: "benchmark",
        code: "bmk",
        name: "Benchmark",
        direction: :ltr,
        active: true
      }
    ])
  end

  defp insert_batch!(ids) do
    concepts =
      Enum.map(ids, fn id ->
        %{
          id: id,
          public_id: uuid("10000000", id),
          editorial_label: "Benchmark concept #{id}",
          editorial_note: "Synthetic performance fixture"
        }
      end)

    entries =
      Enum.map(ids, fn id ->
        %{
          id: id,
          public_id: uuid("20000000", id),
          language_id: 1,
          concept_id: id,
          definitions: [%LocalizedText{language: "en", text: definition(id)}],
          part_of_speech: "noun",
          usage_note: "Synthetic usage note for #{topic(id)}",
          cultural_note: "Synthetic cultural note"
        }
      end)

    forms = Enum.flat_map(ids, &forms/1)
    examples = Enum.flat_map(ids, &examples/1)
    links = Enum.flat_map(ids, &example_links/1)
    media = Enum.map(ids, &media/1)

    Repo.transaction(
      fn ->
        insert_all!(Concept, concepts)
        insert_all!(Entry, entries)
        insert_all!(EntryForm, forms)
        insert_all!(Example, examples)
        insert_all!(ExampleLink, links)
        insert_all!(Item, media)
        insert_search_rows!(ids)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> Mix.raise("Could not seed benchmark batch: #{inspect(reason)}")
    end
  end

  defp insert_all!(schema, rows) do
    {inserted, nil} = Repo.insert_all(schema, rows, timeout: :infinity)

    if inserted != length(rows) do
      Repo.rollback("expected #{length(rows)} #{schema} rows, inserted #{inserted}")
    end
  end

  defp insert_search_rows!(ids) do
    placeholders = Enum.map_join(ids, ",", fn _id -> "(?, ?, ?, ?, ?, ?, ?)" end)

    params =
      Enum.flat_map(ids, fn id ->
        [
          id,
          id,
          1,
          Enum.join([primary_form(id), alias_form(id), transliteration(id)], " "),
          definition(id),
          "Synthetic usage and cultural note #{topic(id)}",
          "#{primary_form(id)} appears in benchmark examples"
        ]
      end)

    Repo.query!(
      "INSERT INTO entry_search(rowid, entry_id, language_id, forms, definitions, notes, examples) VALUES " <>
        placeholders,
      params,
      timeout: :infinity
    )
  end

  defp forms(id) do
    common = %{entry_id: id, language_id: 1}

    [
      Map.merge(common, %{
        text: primary_form(id),
        normalized_text: primary_form(id),
        kind: :spelling,
        is_primary: true
      }),
      Map.merge(common, %{
        text: alias_form(id),
        normalized_text: alias_form(id),
        kind: :alias,
        is_primary: false
      }),
      Map.merge(common, %{
        text: transliteration(id),
        normalized_text: transliteration(id),
        kind: :transliteration,
        is_primary: false
      })
    ]
  end

  defp examples(entry_id) do
    Enum.map(1..2, fn offset ->
      id = example_id(entry_id, offset)
      text = "#{primary_form(entry_id)} appears in benchmark example #{id}"

      %{
        id: id,
        public_id: uuid("30000000", id),
        language_id: 1,
        text: text,
        normalized_text: String.downcase(text),
        translations: []
      }
    end)
  end

  defp example_links(entry_id) do
    Enum.map(1..2, fn offset ->
      %{
        example_id: example_id(entry_id, offset),
        entry_id: entry_id,
        start_offset: 0,
        end_offset: byte_size(primary_form(entry_id)),
        surface_text: primary_form(entry_id),
        role: :focus
      }
    end)
  end

  defp media(id) do
    public_id = uuid("40000000", id)

    %{
      id: id,
      public_id: public_id,
      kind: :audio,
      entry_id: id,
      original_object_key: "private/audio/#{public_id}",
      public_object_key: "public/audio/#{public_id}",
      mime_type: "audio/wav",
      byte_size: 88_278,
      sha256: String.pad_leading(Integer.to_string(id, 16), 64, "0"),
      duration_ms: 1_000,
      processing_state: :ready,
      visibility: :public,
      attribution_text: "Synthetic benchmark media"
    }
  end

  defp verify_counts!(entry_count) do
    expected = %{
      "languages" => 1,
      "concepts" => entry_count,
      "entries" => entry_count,
      "entry_forms" => entry_count * 3,
      "examples" => entry_count * 2,
      "example_links" => entry_count * 2,
      "media" => entry_count,
      "entry_search" => entry_count
    }

    Enum.each(expected, fn {table, expected_count} ->
      actual_count = count(table)

      if actual_count != expected_count do
        Mix.raise("#{table} contains #{actual_count} rows; expected #{expected_count}")
      end
    end)
  end

  defp measure_database(entry_count, samples) do
    language = Repo.get!(Language, 1)
    ids = sample_ids(entry_count, samples)
    groups = Enum.map(ids, &group/1)

    [
      measure(:exact_form, samples, fn index ->
        id = Enum.at(ids, index)
        [_result | _rest] = Archive.exact_lookup(primary_form(id), language)
      end),
      measure(:autocomplete, samples, fn index ->
        group = Enum.at(groups, index)
        [_result | _rest] = Archive.prefix_lookup(topic(group), language)
      end),
      measure(:full_text, samples, fn index ->
        group = Enum.at(groups, index)
        [_result | _rest] = Search.full_text_lookup(topic(group), language.id)
      end),
      measure(:entry_page, samples, fn index ->
        id = Enum.at(ids, index)
        entry = Archive.get_public_entry(uuid("20000000", id))
        _audio = Media.get_public_entry_audio(entry)
        _images = Media.list_public_concept_images(entry.concept)
      end)
    ]
  end

  defp measure(name, samples, operation) do
    Enum.each(0..(samples - 1), operation)

    timings =
      Enum.map(0..(samples - 1), fn index ->
        {microseconds, _result} = :timer.tc(fn -> operation.(index) end)
        microseconds
      end)

    p95 = percentile(timings, 95)

    %{
      name: name,
      samples: samples,
      p50_us: percentile(timings, 50),
      p95_us: p95,
      p99_us: percentile(timings, 99),
      max_us: Enum.max(timings),
      budget_us: Map.fetch!(@budgets_us, name),
      passed?: p95 < Map.fetch!(@budgets_us, name)
    }
  end

  defp measure_concurrency(entry_count, samples, readers) do
    iterations = max(1, div(samples + readers - 1, readers))

    reader_tasks =
      Enum.map(1..readers, fn reader ->
        Task.async(fn ->
          receive do
            :go -> concurrent_reads(entry_count, iterations, reader)
          end
        end)
      end)

    writer_task =
      Task.async(fn ->
        receive do
          :go -> concurrent_writes(max(10, div(samples, 20)))
        end
      end)

    Enum.each([writer_task | reader_tasks], &send(&1.pid, :go))
    reader_results = Task.await_many(reader_tasks, :infinity)
    writer_result = Task.await(writer_task, :infinity)

    read_timings = Enum.flat_map(reader_results, & &1.timings)
    read_errors = Enum.sum(Enum.map(reader_results, & &1.errors))

    %{
      readers: readers,
      reads: length(read_timings),
      writes: length(writer_result.timings),
      read_p95_us: percentile(read_timings, 95),
      write_p95_us: percentile(writer_result.timings, 95),
      errors: read_errors + writer_result.errors
    }
  end

  defp concurrent_reads(entry_count, iterations, reader) do
    Enum.reduce(1..iterations, %{timings: [], errors: 0}, fn iteration, result ->
      id = sample_id(entry_count, reader * 10_007 + iteration * 7_919)

      operation = fn ->
        if rem(iteration, 2) == 0 do
          Archive.search(topic(group(id)), Repo.get!(Language, 1))
        else
          Archive.get_public_entry(uuid("20000000", id))
        end
      end

      record_operation(result, operation)
    end)
  end

  defp concurrent_writes(iterations) do
    Enum.reduce(1..iterations, %{timings: [], errors: 0}, fn iteration, result ->
      operation = fn ->
        Repo.query!("UPDATE concepts SET editorial_note = ? WHERE id = 1", [
          "Concurrent benchmark write #{iteration}"
        ])
      end

      record_operation(result, operation)
    end)
  end

  defp record_operation(result, operation) do
    try do
      {microseconds, _value} = :timer.tc(operation)
      %{result | timings: [microseconds | result.timings]}
    rescue
      _exception -> %{result | errors: result.errors + 1}
    catch
      _kind, _reason -> %{result | errors: result.errors + 1}
    end
  end

  defp measure_http(entry_count, requests, readers, port) do
    unless System.find_executable("ab") do
      Mix.raise("ApacheBench (`ab`) is required; pass --skip-http for database-only results")
    end

    base_url = "http://127.0.0.1:#{port}"
    id = sample_id(entry_count, 7_919)

    case Req.get(base_url <> "/", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      result -> Mix.raise("Benchmark HTTP server did not become ready: #{inspect(result)}")
    end

    [
      run_ab(:search_http, base_url <> "/?q=#{topic(group(id))}", requests, readers),
      run_ab(:entry_http, base_url <> "/entries/#{uuid("20000000", id)}", requests, readers)
    ]
  end

  defp run_ab(name, url, requests, readers) do
    {output, status} =
      System.cmd(
        System.find_executable("ab"),
        ["-k", "-n", Integer.to_string(requests), "-c", Integer.to_string(readers), url],
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("ApacheBench failed for #{url}:\n#{output}")
    end

    %{
      name: name,
      requests: integer_metric!(output, ~r/Complete requests:\s+(\d+)/),
      failed_requests: integer_metric!(output, ~r/Failed requests:\s+(\d+)/),
      requests_per_second: float_metric!(output, ~r/Requests per second:\s+([\d.]+)/),
      mean_ms: float_metric!(output, ~r/Time per request:\s+([\d.]+).*\(mean\)/),
      p95_ms: integer_metric!(output, ~r/^\s*95%\s+(\d+)/m),
      p99_ms: integer_metric!(output, ~r/^\s*99%\s+(\d+)/m)
    }
  end

  defp integer_metric!(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _other -> Mix.raise("Could not parse ApacheBench output:\n#{output}")
    end
  end

  defp float_metric!(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      [value] -> String.to_float(value)
      _other -> Mix.raise("Could not parse ApacheBench output:\n#{output}")
    end
  end

  defp explain_query_plans(entry_count) do
    id = sample_id(entry_count, 7_919)
    prefix = topic(group(id)) <> "*"

    [
      plan(
        :exact_form,
        "SELECT entry_id FROM entry_forms WHERE normalized_text = ? AND language_id = ? GROUP BY entry_id LIMIT 20",
        [primary_form(id), 1]
      ),
      plan(
        :autocomplete,
        "SELECT entry_id FROM entry_forms WHERE language_id = ? AND normalized_text GLOB ? GROUP BY entry_id LIMIT 20",
        [1, prefix]
      ),
      plan(
        :full_text,
        "SELECT entry_id FROM entry_search WHERE entry_search MATCH ? AND language_id = ? ORDER BY rank LIMIT 20",
        ["\"#{topic(group(id))}\"", 1]
      ),
      plan(
        :entry,
        "SELECT entries.id FROM entries JOIN concepts ON concepts.id = entries.concept_id WHERE entries.public_id = ? AND entries.archived_at IS NULL AND concepts.archived_at IS NULL",
        [Ecto.UUID.dump!(uuid("20000000", id))]
      ),
      plan(:entry_forms, "SELECT id FROM entry_forms WHERE entry_id = ?", [id]),
      plan(:entry_examples, "SELECT id FROM example_links WHERE entry_id = ?", [id]),
      plan(:entry_media, "SELECT id FROM media WHERE entry_id = ?", [id])
    ]
  end

  defp plan(name, sql, params) do
    rows = Repo.query!("EXPLAIN QUERY PLAN " <> sql, params).rows
    %{name: name, details: Enum.map(rows, &List.last/1)}
  end

  defp print_plans(plans) do
    Mix.shell().info("\nQuery plans")

    Enum.each(plans, fn plan ->
      Mix.shell().info("  #{plan.name}")
      Enum.each(plan.details, &Mix.shell().info("    #{&1}"))
    end)
  end

  defp print_database_results(results) do
    Mix.shell().info("\nWarm-cache application query latency")
    Mix.shell().info("  operation       p50      p95      p99      max   budget  result")

    Enum.each(results, fn result ->
      status = if result.passed?, do: "PASS", else: "FAIL"

      Mix.shell().info(
        "  #{pad(result.name, 13)} #{pad_ms(result.p50_us)} #{pad_ms(result.p95_us)} " <>
          "#{pad_ms(result.p99_us)} #{pad_ms(result.max_us)} #{pad_ms(result.budget_us)}  #{status}"
      )
    end)
  end

  defp print_concurrent_result(result) do
    Mix.shell().info("\nConcurrent SQLite workload")

    Mix.shell().info(
      "  #{result.readers} readers / 1 writer: #{result.reads} reads, #{result.writes} writes, " <>
        "read p95 #{milliseconds(result.read_p95_us)} ms, " <>
        "write p95 #{milliseconds(result.write_p95_us)} ms, #{result.errors} errors"
    )
  end

  defp print_http_results([]), do: :ok

  defp print_http_results(results) do
    Mix.shell().info("\nHTTP workload")
    Mix.shell().info("  path          requests  failed    req/s    mean     p95     p99")

    Enum.each(results, fn result ->
      Mix.shell().info(
        "  #{pad(result.name, 13)} #{pad(result.requests, 8)} #{pad(result.failed_requests, 7)} " <>
          "#{pad(Float.round(result.requests_per_second, 1), 8)} " <>
          "#{pad(Float.round(result.mean_ms, 1), 7)} " <>
          "#{pad(result.p95_ms, 7)} #{pad(result.p99_ms, 7)} ms"
      )
    end)
  end

  defp print_memory(database) do
    beam = :erlang.memory(:total)

    Mix.shell().info("\nFootprint")
    Mix.shell().info("  BEAM memory: #{format_megabytes(beam)}")
    Mix.shell().info("  OS RSS: #{format_megabytes(rss_bytes())}")
    Mix.shell().info("  SQLite database: #{format_megabytes(File.stat!(database).size)}")
  end

  defp count(table) do
    [[value]] = Repo.query!("SELECT count(*) FROM #{table}").rows
    value
  end

  defp sample_ids(entry_count, samples) do
    Enum.map(1..samples, &sample_id(entry_count, &1 * 7_919))
  end

  defp sample_id(entry_count, seed), do: rem(seed - 1, entry_count) + 1
  defp group(id), do: div(id - 1, 100)
  defp example_id(entry_id, offset), do: (entry_id - 1) * 2 + offset

  defp primary_form(id), do: "#{topic(group(id))}-#{pad_integer(id, 6)}"
  defp alias_form(id), do: primary_form(id) <> "-alias"
  defp transliteration(id), do: "roman-#{pad_integer(id, 6)}"
  defp topic(group), do: "term#{pad_integer(group, 4)}"
  defp definition(id), do: "Definition for #{topic(group(id))} item#{pad_integer(id, 6)}"

  defp uuid(prefix, id) do
    "#{prefix}-0000-4000-8000-#{pad_integer(id, 12)}"
  end

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = max(0, ceil(length(sorted) * percentile / 100) - 1)
    Enum.at(sorted, index)
  end

  defp repo_pool_size do
    :skad |> Application.fetch_env!(Repo) |> Keyword.fetch!(:pool_size)
  end

  defp rss_bytes do
    pid = System.pid()

    case System.cmd("ps", ["-o", "rss=", "-p", pid], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer() |> Kernel.*(1_024)
      _other -> 0
    end
  end

  defp system_description do
    case System.cmd("uname", ["-a"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _other -> "unavailable"
    end
  end

  defp elapsed_seconds(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :millisecond)
    |> Kernel./(1_000)
  end

  defp format_integer(value), do: value |> Integer.to_string() |> add_thousands_separator()

  defp add_thousands_separator(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_megabytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp milliseconds(microseconds), do: Float.round(microseconds / 1_000, 2)
  defp pad_ms(microseconds), do: microseconds |> milliseconds() |> pad(8)
  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width)

  defp pad_integer(value, width),
    do: value |> Integer.to_string() |> String.pad_leading(width, "0")
end
