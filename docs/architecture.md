# Project Skad architecture

- **Status:** Accepted v0 architecture
- **Date:** 2026-09-28
- **Decision log:** [product-decisions.md](product-decisions.md)
- **Data model:** [data-model.md](data-model.md)

This document turns the accepted product decisions into one deployable system. It describes runtime and failure boundaries, not user workflows or a future distributed platform.

## Architectural principle

> SQLite and object storage hold durable truth. BEAM processes coordinate work, isolate failures, and keep the system responsive.

The Elixir runtime is used for supervision, cheap concurrent processes, message passing, controlled background work, graceful shutdown, and observability. It is not used to create an in-memory copy of the domain model.

## System topology

~~~mermaid
flowchart LR
  B["Browser / PWA<br/>HTML, cache, local drafts"]
  C["Caddy<br/>TLS and compression"]

  subgraph host["One commodity Linux machine"]
    P["Phoenix release"]
    DB["SQLite<br/>canonical data, FTS5, Oban"]
    DIR["Durable data directory"]
    P <--> DB
    DB --- DIR
  end

  OBJ["Cloudflare R2 (S3 API)<br/>private + public media"]
  BACKUP["Remote database backups"]

  B -->|"small HTML/JSON requests"| C
  C --> P
  B -->|"signed direct upload/download"| OBJ
  P -->|"validate, publish, withdraw"| OBJ
  DB -->|"continuous replication or snapshots"| BACKUP
~~~

There is one centrally hosted application and one writable SQLite database. Slow connections are handled by small server-rendered responses, browser caching, resumable drafts, and resumable large-media uploads. Version 0 has no downloaded dictionary packs, local archive search, local site server, bidirectional database synchronization, or multi-primary deployment.

## What runs where

| Location | Responsibility |
| --- | --- |
| Browser | Render HTML, progressively enhance interactions, cache useful responses, retain unsent drafts and media, and upload directly to object storage |
| Caddy | Terminate TLS, compress responses, and proxy to Phoenix |
| Phoenix release | Serve pages and endpoints, authenticate moderators, enforce rules, coordinate transactions, sign object requests, run jobs, and expose health/metrics |
| SQLite | Store canonical records, FTS5 search data, revisions, sessions, and durable Oban jobs |
| Cloudflare R2 | Store private originals and public media objects |
| Backup storage | Hold replicated SQLite state and retained snapshots |

## OTP runtime

The initial supervision tree is intentionally small:

    Skad.Application (:one_for_one)
    ├── Skad.Repo
    ├── Skad.PubSub
    ├── Oban
    │   ├── media queue       concurrency: 1
    │   └── maintenance queue concurrency: 1
    └── SkadWeb.Endpoint

Starting the endpoint last means it stops first during an orderly shutdown, preventing new requests while jobs and database connections shut down. A failing request, LiveView, or job fails in its own process rather than taking down the application. The owning supervisor restores long-running infrastructure.

A `Task.Supervisor`, `DynamicSupervisor`, Registry, or custom GenServer is added only when a concrete runtime-owned process requires it. They are not default layers.

## Application boundaries

Phoenix contexts are code boundaries, not separate applications or permanent processes:

| Context | Owns |
| --- | --- |
| `Archive` | Languages, concepts, entries, forms, examples, links, and server-side search |
| `Contributions` | Submissions, moderation, revisions, and accepted-change transactions |
| `Media` | Signed uploads, media metadata, validation, publication, and withdrawal |
| `Accounts` | Moderator identities, authentication, sessions, and authorization |

Search remains inside `Archive`. Background workers live beside the context whose operation they perform. Contexts communicate through public functions and stable IDs, not by sharing private schemas or process state.

## Synchronous work versus background work

The web request performs work the user needs confirmed immediately:

- Search and render a page.
- Save a submission or moderator decision.
- Commit canonical data, revisions, and the corresponding FTS update.
- Create an upload session or signed object-storage request.
- Enqueue any required follow-up job in the same database transaction as its triggering change.

Oban performs work that may finish later, must retry, or must survive a restart:

### Future media queue

- Verify an uploaded object, checksum, actual type, size, and duration or dimensions.
- Create the public playback or display object when one is required.
- Publish approved media from the private area to the public area.
- Remove public objects after media withdrawal.
- Clean abandoned multipart uploads and expired quarantine objects.

This queue is deferred while media volume is low. The current path checks
stored size and declared content type, performs a synchronous server-side copy,
and relies on moderator preview before publication.

### Maintenance queue

- Rebuild FTS5 from canonical records.
- Process a controlled bulk import.
- Re-evaluate example-link suggestions after forms change.

Search, ordinary page rendering, saving a draft, and the canonical approval transaction are not background jobs. Initially each queue runs one job at a time to protect the small machine and SQLite's single-writer path.

## Media upload path

1. The browser saves the contribution and selected media locally.
2. Phoenix validates metadata and returns server-chosen object keys plus short-lived signed upload instructions.
3. Small objects use one direct signed upload. Large objects use the object store's native multipart upload so completed chunks survive a connection interruption.
4. The browser reports completion to Phoenix; retries are idempotent.
5. Phoenix verifies stored size and declared content type, copies the object
   server-side to its public key, and records it as quarantined and `ready`.
6. Moderator approval attaches ready media to an entry or concept and makes it
   publicly reachable.
7. The local browser draft is removed only after server acknowledgement.

Server-side checksum verification, actual-type detection, full decoding,
duration and dimension limits, renditions, and durable media retries are future
hardening for meaningful public anonymous-upload volume.

The application server does not proxy media bytes. A failed connection leaves a visible resumable draft rather than an apparently successful submission.

## Runtime communication

Phoenix PubSub carries ephemeral notifications such as “media processing finished” to an open moderation screen. It does not hold truth. After reconnecting, a LiveView or page reloads current state from SQLite.

LiveView is appropriate for connected moderator workflows. Essential public reading, search navigation, and contribution-draft safety cannot depend on a persistent socket.

## SQLite concurrency and backpressure

- Public reads may execute concurrently.
- Canonical writes use short transactions.
- Ecto and SQLite own database access; there is no custom database-write GenServer.
- Oban queue limits prevent media and maintenance work from flooding the writer.
- CPU-heavy media work never runs inside a web request. If FFmpeg becomes necessary, an Oban job runs one supervised external process at a time.
- Large exports and object checks stream data rather than loading complete files into BEAM memory.

## Failure behaviour

| Failure | Required behaviour |
| --- | --- |
| Browser connection drops | Keep cached content and local draft; show retryable state |
| Direct upload stops | Resume completed multipart chunks or retry a small upload |
| Web request crashes | Only that request fails; log its request ID and return a safe error |
| Background job fails | Record the failure and retry with backoff |
| Application restarts | Supervision restores services; durable jobs remain in SQLite |
| PubSub message is missed | Reload durable state from SQLite |
| Object storage is unavailable | Preserve database state and retry the idempotent job later |
| Media is withdrawn | Hide it transactionally first; delete public objects asynchronously |
| FTS index is damaged or stale | Rebuild it from canonical data |
| Host is lost | Restore SQLite and reconnect stable object keys on a fresh host |

## Security boundaries

- Public and private media use separate object-storage areas.
- The server chooses object keys and issues short-lived, narrowly scoped signed requests.
- Only moderator accounts can publish canonical changes.
- Quarantined keys and submission payloads never enter public responses, exports, logs, PubSub messages, or job arguments.
- Jobs carry stable record IDs and reload authoritative state when they execute.
- Every external operation is idempotent because a job may run more than once.

## Observability and operations

- Structured logs include request ID and, when applicable, submission, media, and job IDs.
- Telemetry covers Phoenix request time, Ecto query time, Oban queue depth/runtime/failures, and BEAM memory and scheduler health.
- Health checks distinguish process health from database readiness.
- Deployments stop accepting requests, allow a bounded graceful shutdown, snapshot before migrations, replace the executable, migrate, and restart against the unchanged data directory.
- A restore drill, not the existence of a backup file, proves recoverability.

## Durable data directory

The replaceable executable does not own durable state. The configured data directory contains:

    skad-data/
    ├── skad.sqlite3
    ├── secrets/
    ├── temporary/
    └── backups/

The Burrito extraction cache and compiled application directory are disposable. Object media remains outside this directory.

## Explicit non-goals

Version 0 does not include:

- Microservices or a separate worker deployment.
- Distributed Erlang, clustering, or node discovery.
- Redis, an external queue, or an external search service.
- A GenServer for each word, user, upload, or session.
- ETS as a second source of truth or a speculative application cache.
- Unsupervised spawned processes or an in-memory durable queue.
- A local site server or bidirectional database synchronization.
- Downloaded dictionary packs or browser-side archive search in v0.

Add one of these only after a measured failure identifies the missing capability and the simpler supervised monolith cannot solve it.

## V1 future improvement: offline dictionary packs

Version 1 may add separately downloadable language packs and an optional complete pack. A pack contains entry IDs, primary and alternate forms, transliterations, short definitions, and confirmed example links. It is versioned, checksummed, stored in IndexedDB separately from contribution drafts, and activated only after the complete new version has been verified.

The initial offline search should support exact and prefix lookup across forms and transliterations. Updates replace a complete selected pack; delta synchronization is deferred. Audio and images remain optional downloads outside the mandatory text pack.

Offline full-text search across definitions and examples is not committed. SQLite/WASM or a custom browser search index is justified only if real v1 usage shows that indexed form lookup is insufficient.

## Architecture validation

The architecture is not proven until the vertical slice in product-decisions.md demonstrates:

- Slow-network reading, search, resumable drafts, and interrupted media uploads.
- Transactional approval and job insertion.
- Job retry across an application restart.
- PubSub updates with durable reload after reconnect.
- The PD-018 database workload on the target machine.
- Graceful upgrade, backup, and full restore on a fresh host.
