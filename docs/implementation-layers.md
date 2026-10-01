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

### 10e. Submission media context

Complete the backend flow for media attached to a new-entry submission. A
completed anonymous upload begins unowned and quarantined. Submission creation
claims at most one audio item and five images atomically. While the submission
is open, its active audio can be replaced and any attached item can be removed.
Approval moves the audio to the new language-specific entry and the images to
its concept in the same transaction as the archive publication.

It is complete when context tests prove idempotent claiming, ownership and
count limits, moderator replacement/removal, correct final targets, and full
rollback when any attached item is not ready. Browser recording, upload inputs,
moderation UI, validation jobs, renditions, cleanup, corrections, additions,
and standalone media submissions remain outside this layer.

The object-storage foundation is complete: Phoenix issues five-minute signed
instructions for server-owned keys, supports JPEG, PNG, WebP, and common browser
audio types, verifies stored size and signed content type, and records one
quarantined media row without proxying file bytes.

The moderator concept correction is complete: moderators can create and edit a
concept with a private editorial note, search concepts by their metadata or
entries, and attach an approved new entry to an existing concept.

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
