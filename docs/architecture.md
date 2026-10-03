# Project Skad architecture

- **Status:** Current v0 architecture
- **Updated:** 2026-10-03
- **Decision log:** [product-decisions.md](product-decisions.md)
- **Data model:** [data-model.md](data-model.md)
- **Deferred work:** [future.md](future.md)

This document describes the system that exists now. Future infrastructure and
product work lives only in `future.md`.

## Architectural principle

SQLite and object storage hold durable truth. The Phoenix application enforces
rules, coordinates transactions, and serves the public and moderator
interfaces. Contexts are code boundaries, not services or permanent processes.

## Topology

~~~mermaid
flowchart LR
  B["Browser<br/>server-rendered HTML + small JS hooks"]
  C["Caddy<br/>TLS and compression"]
  P["Phoenix release"]
  DB["SQLite<br/>canonical data + FTS5"]
  OBJ["S3-compatible object storage<br/>quarantine + public media"]
  BACKUP["Checked backup bundle<br/>SQLite + object mirror"]

  B --> C --> P
  P <--> DB
  B -->|"signed direct upload"| OBJ
  P -->|"inspect, copy, publish"| OBJ
  DB --> BACKUP
  OBJ --> BACKUP
~~~

There is one application node and one writable SQLite database. Production
media uses Cloudflare R2; local development uses RustFS through the same S3
interface. `bin/skad-data` creates and verifies maintenance-window backup
bundles containing both database and object-storage state.

## OTP runtime

The application supervision tree is deliberately small:

    Skad.Application (:one_for_one)
    ├── Skad.Repo
    ├── Ecto.Migrator
    ├── Skad.PubSub
    └── SkadWeb.Endpoint

There is no DNS clustering, custom telemetry supervisor, job queue, registry,
or domain GenServer. Dependencies may run their own application processes; in
particular, the standard telemetry poller emits the VM measurements displayed
by LiveDashboard.

## Application boundaries

| Context | Owns |
| --- | --- |
| `Archive` | Languages, concepts, entries, forms, examples, links, and search |
| `Contributions` | Submissions, moderation, revisions, and atomic publication |
| `Media` | Signed uploads, object metadata, publication, and withdrawal state |
| `Accounts` | Moderator identities, sessions, and authorization |

Public routes use normal controller requests. Moderator routes use the same
session-backed authorization pipeline. LiveDashboard additionally revalidates
the session in a LiveView `on_mount` hook.

## Synchronous request path

Work needed to confirm a user action happens in the request:

- Search and render pages.
- Store submissions and moderator decisions.
- Update canonical rows, revisions, and FTS state in one transaction.
- Prepare a signed direct upload.
- Inspect a completed upload and make the server-side object copy.

These operations are bounded by result limits and upload size limits. There is
no durable background worker today. Work that needs cleanup, robust retries, or
expensive media inspection is listed in [future.md](future.md).

## Media path

1. Phoenix validates declared metadata and returns a server-chosen key plus a
   short-lived signed upload URL.
2. The browser uploads the bounded object directly to storage.
3. The browser reports completion idempotently.
4. Phoenix checks stored size and declared content type, copies the object to
   its eventual public key, and records it as ready but quarantined.
5. Moderator approval attaches the media to an entry or concept and changes
   its visibility so public routes may return signed reads.

The server does not proxy media bytes. Checksum verification, actual-type
detection, decoding, renditions, lifecycle cleanup, resumable multipart state,
and durable retries are not implemented yet.

## Queue bounds

Public search and autocomplete return bounded result sets. The moderator review
queue returns 20 submissions ordered by `(received_at, id)` and advances with a
keyset cursor. The browser's Back action provides reverse navigation without
maintaining server-side pagination state.

## Failure and recovery boundaries

| Event | Current behavior |
| --- | --- |
| Web request crashes | The request process fails; other requests continue and the request ID is logged |
| Application restarts | Supervision restores the repository, PubSub, and endpoint |
| PubSub message is missed | Pages reload durable state from SQLite |
| Invalid or incomplete upload | It remains private and cannot be published |
| Media is withdrawn | Public queries hide it and the record enters deletion state |
| FTS becomes stale | It can be rebuilt from canonical SQLite rows |
| Host is lost | Restore a verified SQLite-and-object bundle onto a fresh host |

Physical cleanup of abandoned or withdrawn objects and automatic retry of
failed object-store operations are deferred.

## Moderator diagnostics

Authenticated moderators can open `/moderator/dashboard`. Phoenix
LiveDashboard exposes current application, process, Ecto, request, and VM
information using the telemetry events already emitted by Phoenix, Ecto, and
the standard VM poller. Its request logger can stream logs while the dashboard
is open.

LiveDashboard is a live diagnostic view, not retained incident history,
automatic alerting, or an error tracker. Those capabilities should be added
only if operating the pilot demonstrates a concrete need for them.

## Explicit non-goals

V0 has no microservices, distributed Erlang, clustering, Redis, external search
service, separate frontend application, GraphQL layer, custom in-memory source
of truth, or speculative caching layer. Add infrastructure only after a
measured failure shows that the supervised monolith cannot meet the need.
