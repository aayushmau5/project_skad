# Project Skad

Project Skad is a living multilingual archive for the languages of Kinnaur. It is intended to preserve more than word-to-word translations: spellings, meanings, pronunciation, examples, cultural context, and editorial history all belong to the record.

## V0 goal

The first version supports one complete loop:

1. Search for a word or expression in any supported language.
2. Read its meanings, alternate forms, translations, examples, and approved media.
3. Suggest a new word, more information, or a correction.
4. Review the contribution before it becomes public.

V0 is centrally hosted and designed to remain useful on slow or interrupted connections. It uses small server-rendered pages, browser caching, locally retained contribution drafts, and resumable media uploads. Downloadable offline dictionary packs are a possible v1 improvement.

## Technical direction

- One Elixir/Phoenix application, maintained by one person.
- SQLite in WAL mode, with indexed forms and FTS5 search.
- Audio and images in S3-compatible object storage; only metadata and stable keys in SQLite.
- Oban jobs in the same database for retryable media and maintenance work.
- HTML first, with LiveView only where a connected interaction benefits from it.
- One small Linux machine, Caddy, remote backups, and no required Docker setup.
- A self-contained Burrito executable is the preferred packaging target, pending a representative build; a standard Mix release is the fallback.

## Canonical documents

| Document | What it owns |
| --- | --- |
| [product-decisions.md](product-decisions.md) | Product choices, rationale, constraints, open questions, and validation targets |
| [architecture.md](architecture.md) | Runtime boundaries, deployment shape, failure handling, jobs, and media flow |
| [data-model.md](data-model.md) | The v0 schema, relationships, worked example, indexes, and deferred data-model changes |

These documents are the current source of truth. Avoid creating a new planning file when the information belongs in one of them.

## Local object storage

Local development uses RustFS as the S3-compatible store. RustFS provides a
maintained local server with tested presigned PUT support.

Start the store and create the private development bucket:

```sh
docker compose up -d
docker compose ps -a
```

The S3 endpoint is `http://127.0.0.1:9000`; the console is available at
`http://127.0.0.1:9001`. The local credentials are `SKADLOCAL` and
`skad-local-development-secret`, and the bucket is `skad-private`. These
loopback-only defaults can be overridden with `R2_ENDPOINT`, `R2_REGION`,
`R2_BUCKET`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY`. RustFS uses the
same application-facing variables as Cloudflare R2 so the upload code does not
need a separate local configuration shape.

Stop the service without deleting its named volume:

```sh
docker compose down
```

Production uses Cloudflare R2 through its S3-compatible API. Configure:

```sh
R2_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
R2_REGION=auto
R2_BUCKET=<BUCKET_NAME>
R2_ACCESS_KEY_ID=<ACCESS_KEY_ID>
R2_SECRET_ACCESS_KEY=<SECRET_ACCESS_KEY>
```

Use an R2 API token limited to Object Read & Write access on the intended
bucket. Do not expose these credentials to the browser; Phoenix will use them
only to issue short-lived upload instructions.

Because the browser uploads directly, configure the R2 bucket's CORS policy
for the deployed application origin:

```json
[
  {
    "AllowedOrigins": ["https://your-skad-host.example"],
    "AllowedMethods": ["PUT"],
    "AllowedHeaders": ["Content-Type"],
    "MaxAgeSeconds": 3600
  }
]
```

See Cloudflare's [R2 CORS documentation](https://developers.cloudflare.com/r2/buckets/cors/).

## Backup and restore

`bin/skad-data` creates a checked backup containing one SQLite snapshot and a
mirror of the complete object-storage bucket. Backups use a short maintenance
window so the database and media cannot change while the bundle is assembled.

Stop the application, set the production storage variables plus the durable
database path, and explicitly acknowledge the maintenance window:

```sh
export DATABASE_PATH=/srv/skad-data/skad.sqlite3
export R2_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
export R2_REGION=auto
export R2_BUCKET=skad-private
export R2_ACCESS_KEY_ID=<ACCESS_KEY_ID>
export R2_SECRET_ACCESS_KEY=<SECRET_ACCESS_KEY>
export SKAD_APP_STOPPED=1

bin/skad-data backup /srv/skad-data/backups/2026-10-02T060000Z
bin/skad-data verify /srv/skad-data/backups/2026-10-02T060000Z
```

Copy the completed backup directory to retained storage on another machine or
provider. A backup left only on the application host does not protect against
host loss. The bundle contains moderator password hashes and unpublished
submissions, so keep its existing restrictive permissions and encrypt remote
copies.

Restore only while the application is stopped, into a database path that does
not exist and an already-created empty bucket:

```sh
export DATABASE_PATH=/srv/skad-restore/skad.sqlite3
export R2_BUCKET=skad-restore-empty

bin/skad-data restore /srv/skad-data/backups/2026-10-02T060000Z
```

Start the application against the restored database and bucket, then verify
search, one public entry, its media, and moderator login. The restore command
refuses to overwrite an existing database or merge into a non-empty bucket.

## Current stage

The first complete archive loop is working: new entries, corrections, additions, standalone examples, entry-targeted audio/images, moderation, atomic publication, search, and public reading. Audio approval replaces the current entry pronunciation, while image approval adds to the entry concept's gallery. Exact duplicates of existing canonical entry content are rejected; new-entry forms remain reviewable because identical spelling can represent distinct meanings. Upload completion verifies stored metadata, makes a synchronous server-side copy under a public key, and marks the quarantined media ready; only moderator approval makes it publicly reachable. [implementation-layers.md](docs/implementation-layers.md) records the deliberately deferred validation and background-processing hardening.

The first operational recovery path is also available: a maintenance-window
command snapshots SQLite and object storage together, verifies checksums and
database integrity, and restores only into empty targets. Deployment automation
and scheduled off-host retention remain deliberately separate work.

## Historical artifacts

- [first-web.png](first-web.png) is an early interface sketch.
- `mock/` contains an exploratory website prototype.

They are useful references, but they do not define the product or architecture.

## Why build the core rather than extend DictPress?

DictPress helped establish the desired single-binary deployment ergonomics, but Project Skad needs first-class multilingual concepts, reusable linked examples, contribution review, media, and revision history. Keeping those concerns in one small Skad application is simpler than splitting the product between DictPress and companion services.
