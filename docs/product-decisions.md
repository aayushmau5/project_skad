# Project Skad product decisions

- **Last consolidated:** 2026-10-01
- **Architecture:** [architecture.md](architecture.md)
- **Data model:** [data-model.md](data-model.md)

This file records current product decisions and their rationale. Detailed runtime and schema specifications live in the linked canonical documents rather than being repeated here.

Statuses are **Accepted**, **Proposed**, or **Superseded**. New evidence should create or revise a decision instead of silently changing direction.

## PD-001 — Build a living language archive

- **Status:** Accepted

Project Skad is a multilingual archive of Kinnaur's languages, not only a translation dictionary. It preserves forms, sound, meaning, examples, cultural context, source, and review history.

The v0 product loop is:

1. Find a word in any supported language.
2. Understand its meaning, forms, pronunciation, examples, and context.
3. Suggest a word, addition, or correction.
4. Review the contribution before publication.

Quizzes, games, profiles, and advanced community features wait until this loop works reliably.

## PD-002 — Separate shared concepts, meanings, and searchable forms

- **Status:** Accepted

A concept connects equivalent entries across languages. One entry represents one language-specific meaning. Its primary spelling, alternatives, transliterations, historical forms, and search aliases are indexed entry_forms rows.

Languages are records rather than fixed database columns. The complete physical schema and its worked WATER example are in [data-model.md](data-model.md).

## PD-003 — Optimize for one maintainer

- **Status:** Accepted

Clarity, development speed, low cost, backup, and recovery take priority over theoretical throughput. Start with one application and one database, prefer platform features and mature dependencies, and add infrastructure only after measurement shows a need.

## PD-004 — Use an Elixir/Phoenix monolith

- **Status:** Accepted

One Phoenix application serves public pages, search, contributions, moderation, media coordination, and the few JSON endpoints the product needs.

The code boundaries are `Archive`, `Contributions`, `Media`, and `Accounts`. They are contexts, not services or permanent processes. V0 has no microservices, distributed Erlang, Kubernetes, Redis, separate frontend application, or GraphQL layer.

## PD-005 — Use SQLite, WAL, and FTS5

- **Status:** Accepted

SQLite through Ecto is the canonical database. WAL supports the read-heavy single-node workload; FTS5 handles full-text search; indexed entry_forms rows handle exact and prefix lookup. If durable jobs become necessary, they must use the same database rather than introduce another service by default.

Move to Postgres only when several application nodes must write, measured write contention harms users, high availability becomes mandatory, or the representative workload misses its targets after query and index fixes.

## PD-006 — Store media in Cloudflare R2

- **Status:** Accepted

Production media uses Cloudflare R2 through its S3-compatible API. Local
development uses RustFS against the same application configuration shape.
SQLite stores stable object keys and metadata, not audio or image bytes.
Private/quarantine and public media are separate. Browsers upload directly with
short-lived signed instructions and bounded single-object uploads.

Preserve originals, check stored size and declared content type, create the
public object with a synchronous server-side copy, and make it reachable only
after moderation. Actual-type and checksum verification, full decoding,
renditions, and durable background retries are deferred until public anonymous
upload volume or observed failures justify them.

## PD-010 — Never lose an in-progress contribution

- **Status:** Accepted; implementation deferred

Contribution fields, the client submission UUID, and selected media should remain locally saved until the server acknowledges receipt. Failed sends should remain visible and retryable. This guarantee is not implemented yet and is tracked in [future.md](future.md).

## PD-011 — Use HTML first and LiveView selectively

- **Status:** Accepted

Phoenix renders essential public content as HTML with progressive enhancement. Useful reading and navigation do not require JavaScript or a persistent socket. LiveView is appropriate where a connected moderator or administrative interaction benefits from it.

## PD-012 — Enforce a low-bandwidth budget

- **Status:** Accepted

Initial public-page targets are:

- Meaningful content without JavaScript.
- Cold page below roughly 100 KB compressed, excluding requested media.
- Initial JavaScript below roughly 60–75 KB compressed.
- CSS below roughly 30 KB compressed.
- Largest Contentful Paint at or below 2.5 seconds in throttled mobile testing.
- No hosted fonts, autoplay media, third-party trackers, or large component libraries.
- Responsive images and audio loaded only after user intent.

These are measured budgets, not reasons to remove accessibility or failure handling.

## PD-013 — Deploy one small, recoverable system

- **Status:** Accepted

Production begins with one Phoenix release, Caddy for TLS, SQLite on local persistent storage, S3-compatible media storage, standard application logs, and health/readiness endpoints. Scheduled encrypted off-host retention and backup-failure alerts remain required operational safeguards in [future.md](future.md).

Start with 2 GB RAM until the smaller target in PD-014 is proven. Deployment is incomplete until a fresh machine can restore the database and reconnect the media inventory.

## PD-014 — Package a self-contained executable without Docker

- **Status:** Proposed pending a representative build

Ship an official Mix release packaged with Burrito for Linux x86-64 and ARM64. The executable contains the Erlang runtime, application, assets, migrations, and SQLite native code. Durable state stays in an external data directory.

The intended interface is:

```sh
chmod +x skad
./skad serve --data-dir ./skad-data
```

Validate idle memory at or below roughly 256 MB on a 1 GB machine and observe the same build on 512 MB. A standard Mix release remains the fallback. Docker, orchestration, macOS/Windows binaries, and mandatory FFmpeg are outside v0.

## PD-015 — Make examples reusable and word-linked

- **Status:** Accepted

An example is stored once and may contain several confirmed text spans linked to the exact entries intended in context. Links are either a focus or a reference. Clicking a link shows a compact definition and route to the full entry.

On submission, deterministic matching normalizes the sentence, tries longer phrases first, and looks up indexed forms in the same language. Unambiguous matches become suggestions; ambiguous meanings require contributor or moderator choice. Reviewed links never change silently.

## PD-016 — Use the compact ten-table relational model

- **Status:** Accepted; revised 2026-10-01

The v0 domain tables are languages, concepts, entries, entry_forms, examples, example_links, media, submissions, moderator_accounts, and revisions. People and structured consent records are deferred until a supported workflow needs stable participant identity or structured permission history.

Unreviewed submissions remain outside canonical public data. Approval changes canonical rows and creates append-only revision history in one transaction. Privacy boundaries, constraints, indexes, and deferred promotion triggers are in [data-model.md](data-model.md).

## PD-018 — Treat 100,000 entries as the database baseline

- **Status:** Accepted

The acceptance dataset contains 100,000 published entries, approximately 300,000 forms, 200,000 examples, 100,000 media-metadata rows, twenty concurrent readers, and one ordinary writer.

On a 1-vCPU, 1 GB Linux machine with a warm cache, initial p95 database budgets are:

| Operation | Budget |
| --- | ---: |
| Exact-form lookup | Below 10 ms |
| Autocomplete | Below 20 ms |
| FTS top 20 | Below 50 ms |
| Normal entry-page queries | Below 25 ms |

Every hot query must be checked with `EXPLAIN QUERY PLAN`. Common paths use bounded results and keyset pagination. No external search service, cache service, read replica, or sharding is introduced before SQLite is measured and tuned.

## PD-020 — Use OTP for isolation and coordination, not domain storage

- **Status:** Accepted

SQLite and object storage hold durable truth. BEAM processes provide request isolation, supervision, controlled concurrency, PubSub notifications, graceful shutdown, and live diagnostics.

The supervision tree contains Ecto Repo, the release migrator, Phoenix PubSub, and the Endpoint. Contexts remain ordinary modules; there are no per-entry GenServers, in-memory durable queues, speculative ETS caches, unsupervised tasks, or distributed nodes. See [architecture.md](architecture.md).

## PD-021 — Build v0 for slow networks; defer offline packs to v1

- **Status:** Accepted

V0 is centrally hosted and optimized for slow connections. It includes small server-rendered pages and bounded direct media uploads. Search remains online. Local contribution drafts and resumable media uploads are deferred until real use justifies them.

V1 may add versioned, checksummed language packs in IndexedDB with atomic replacement and exact/prefix lookup over forms and transliterations. Contribution drafts remain isolated from pack updates; media stays optional. Delta synchronization and offline full-text search are deferred until measured need justifies their complexity.

## Superseded decisions

| ID | Replaced by | Earlier direction |
| --- | --- | --- |
| PD-007, PD-008, PD-009 | PD-021 | Put downloadable offline dictionary data in the initial release |
| PD-017 | PD-018 | Keep alternate forms in JSON and use eleven domain tables |
| PD-019 | PD-021 | Describe v0 as an offline-tolerant client including downloaded packs |

## Open decisions

- Object-storage and VPS providers, regions, and data residency.
- Launch interface languages.
- Search-normalization and transliteration conventions per language.
- Media permission, retention, and takedown policy.
- Moderator ownership and the meaning of a verified entry.
- Integration with the existing Zed Tells site.
- Public licenses for text, recordings, images, and exports.
- Whether v1 requires offline full-text search.

## Remaining work

The deduplicated backlog and its completion boundaries live in
[future.md](future.md). Completed behavior is described in the README and
[architecture.md](architecture.md).
