# Performance baseline

## 2026-10-02 production-mode runs

This run exercises the PD-018 dataset through the real Ecto and Phoenix paths:

- 100,000 published entries
- 300,000 entry forms
- 200,000 examples and confirmed example links
- 100,000 public media-metadata rows
- a five-connection Ecto pool
- twenty concurrent readers and one writer

The generated SQLite database was approximately 235-238 MB. The application ran
with `MIX_ENV=prod`; ApacheBench generated HTTP traffic from the same machine or
container as the server.

### Constrained ARM64 Linux results

The production build ran in Docker Desktop's ARM64 Linux VM with one BEAM
scheduler, one CPU of quota, no swap, and first a 1 GB and then a 512 MB memory
limit. The same prebuilt image was used for the 512 MB observation, so dependency
compilation was outside the measured resource limit.

#### Warm-cache database results

| Operation | 1 GB p95 | 512 MB p95 | PD-018 p95 budget | Result |
| --- | ---: | ---: | ---: | --- |
| Exact-form lookup | 0.55 ms | 0.56 ms | < 10 ms | Pass |
| Autocomplete | 1.01 ms | 1.02 ms | < 20 ms | Pass |
| FTS top 20 | 1.07 ms | 1.22 ms | < 50 ms | Pass |
| Entry-page database work | 1.95 ms | 2.02 ms | < 25 ms | Pass |

All recorded query plans used the expected covering, unique, primary-key, or
FTS5 virtual-table indexes. The autocomplete grouping used a temporary B-tree
over its bounded index result.

#### Concurrent workload

Twenty readers completed 500 mixed search and entry reads while one writer
completed 25 ordinary SQLite updates in each run.

| Limit | Read p95 | Write p95 | Errors |
| --- | ---: | ---: | ---: |
| 1 CPU / 1 GB | 101.36 ms | 35.57 ms | 0 |
| 1 CPU / 512 MB | 95.86 ms | 6.31 ms | 0 |

#### HTTP workload

Each route received 2,000 requests at concurrency 20. The load generator ran
inside the same constrained container and therefore shared its single CPU with
the application.

| Limit and route | Requests/second | Mean | p95 | p99 | Failed requests |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 GB public search | 221.4 | 90.3 ms | 105 ms | 109 ms | 0 |
| 1 GB public entry | 345.6 | 57.9 ms | 93 ms | 96 ms | 0 |
| 512 MB public search | 230.0 | 87.0 ms | 102 ms | 105 ms | 0 |
| 512 MB public entry | 270.8 | 73.8 ms | 103 ms | 287 ms | 0 |

The 1 GB run reported 121.7 MB of BEAM memory and 244.3 MB OS RSS. The 512 MB
run reported 121.5 MB of BEAM memory and 242.1 MB OS RSS. Neither run was killed
or produced an application, HTTP, or SQLite error.

### Unconstrained ARM64 Mac baseline

Each operation was warmed with the same 500 deterministic samples before the
measured 500-sample pass. These timings include the real Ecto queries and
preloads rather than substitute SQL microbenchmarks.

| Operation | p50 | p95 | p99 | Maximum | PD-018 p95 budget | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Exact-form lookup | 0.23 ms | 0.32 ms | 0.38 ms | 1.04 ms | < 10 ms | Pass |
| Autocomplete | 0.83 ms | 1.46 ms | 1.78 ms | 2.55 ms | < 20 ms | Pass |
| FTS top 20 | 0.60 ms | 0.79 ms | 0.91 ms | 1.13 ms | < 50 ms | Pass |
| Entry-page database work | 0.89 ms | 1.15 ms | 1.31 ms | 2.71 ms | < 25 ms | Pass |

`EXPLAIN QUERY PLAN` used the covering entry-form indexes for exact and prefix
lookup, the FTS5 virtual-table index for full-text search, the unique entry
public-ID index, and the entry indexes for forms, examples, and media. The
prefix query used a temporary B-tree for its bounded grouped result.

#### Concurrent workload

Twenty readers completed 500 mixed search and entry reads while one writer
completed 25 ordinary SQLite updates:

| Read p95 | Write p95 | Errors |
| ---: | ---: | ---: |
| 51.82 ms | 6.98 ms | 0 |

#### HTTP workload

The production-configured Bandit endpoint used the same five-connection pool.
Each route received 2,000 requests at concurrency 20.

| Route | Requests/second | Mean | p95 | p99 | Failed requests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Public search | 429.4 | 46.6 ms | 59 ms | 106 ms | 0 |
| Public entry | 1,010.2 | 19.8 ms | 24 ms | 32 ms | 0 |

At the end of the run, the BEAM reported 124.3 MB of allocated memory. The OS
reported 64.7 MB resident for the process; these values use different accounting
rules and should be tracked independently rather than compared directly.

### Reproduce

Build the production assets, create the isolated database, and run the task:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix skad.benchmark \
  --database /tmp/skad-pd018.sqlite3 \
  --entries 100000 \
  --samples 500 \
  --http-requests 2000 \
  --reset
```

Production runtime variables from `config/runtime.exs` must also be supplied.
The object-storage settings are loaded but no object request is made by this
workload.

### What this proves

This is strong evidence that the schema, indexes, SQLite configuration,
application query paths, and HTTP rendering have substantial headroom at the
representative data volume. It covers the specified Linux CPU and memory limits,
including the 512 MB observation. Docker Desktop still uses a local VM and host
storage rather than the eventual VPS, so the benchmark should be repeated after
deployment before choosing the smallest production machine. Cold-cache,
throttled-network, and low-end-phone measurements remain separate checks.
