> **Important: this is a rough, provisional map, not a fixed implementation plan.**
>
> The order and boundaries must change as implementation teaches us more. At any
> point, the immediate focus is only the next layer: understand it thoroughly,
> define its scope and completion criteria, implement it, and inspect the result
> before planning the following layer in depth. Later layers are reminders, not
> commitments, and must not justify speculative code in the current layer.

# Rough implementation layers

This file helps keep implementation work narrow. It does not override the
accepted product decisions, architecture, or data model.

## Working rule

- Give each layer one primary domain or responsibility.
- Define what is included, what is excluded, and what proves completion before
  implementing the layer.
- Do not add preparatory abstractions or infrastructure for later layers.
- Stop after each layer, review what was learned, and revise this map if needed.
- Put unavoidable cross-domain integration in its own explicit layer.

## Immediate focus

### Review the completed media slice

Completed uploads have their stored size and declared content type checked,
then receive a server-side copy under a public object key and are marked ready
synchronously. They remain quarantined and inaccessible through public routes
until moderator approval atomically attaches them to an entry or concept and
changes their visibility.

Contributors can upload or record one pronunciation and upload up to five
cultural images with a new-entry submission. Moderators can preview, replace,
or remove submission media and can upload or remove concept images. Public
entry pages render approved media through short-lived signed reads.

### Deferred media hardening

Before anonymous uploads are exposed publicly at meaningful volume, reconsider
server-side checksum verification, actual-type detection, full image/audio
decoding, dimension and duration limits, normalized public renditions, and an
Oban media queue with durable retries and visible failure reasons. Add that
machinery when malformed uploads, processing latency, or production reliability
requires it; it is intentionally not part of the current synchronous path.

Cleanup of abandoned uploads, corrections, additions, standalone media
submissions, and browser-resumable uploads also remain outside this layer.

The moderator concept correction is also complete: moderators can create and
edit a concept with a private editorial note, search concepts by their metadata
or entries, and attach an approved new entry to an existing concept.

### Deferred public archive refinement

When one exact written form belongs to entries in different concepts, show the
entries together as distinct meanings of that word. Keep each definition and
entry link separate, and do not merge their concepts automatically.

## Rough map of later layers

### 2. Persistence foundation

Configure SQLite, the durable database path, migration conventions, and the
database test setup. Do not create product tables.

### 3. Archive core

Implement languages, concepts, entries, and forms, including their migrations,
constraints, schemas, and context API. Do not add search or pages.

### 4. Search

Implement normalization, exact lookup, prefix lookup, and FTS5 over the Archive
API. Do not add presentation concerns.

### 5. Public archive

Add server-rendered search results and entry pages using the established
Archive and Search APIs.

### 6. Accounts

Add moderator authentication and authorization. Do not add contribution review.

### 7. Contributions

Add submission storage, validation, receipts, and idempotency. Do not apply
submissions to canonical archive records.

### 8. Moderation

Add review decisions, revisions, and the transactional approval path that
connects Contributions to Archive.

### 9. Examples

Add examples, translations, confirmed word links, matching, and their public
display.

### 10. Media

Add media persistence in narrow steps: database design, Ecto schemas, the Media
context, then object storage, uploads, publication, and withdrawal behavior.
Defer people and structured consent records until a supported workflow needs
them.

### 11. Background work

Add Oban and only the first background jobs required by implemented behavior.

### 12. Browser resilience

Add locally retained drafts, retry states, and resumable uploads.

### 13. Import and export

Add reviewed dataset import, provenance, stable exports, and restore-compatible
identifiers.

### 14. Operations

Validate the representative workload, backups, restore, deployment, standard
releases, and finally the proposed Burrito packaging approach.
