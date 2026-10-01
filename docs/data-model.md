# Project Skad v0 data model

- **Status:** Accepted v0 schema
- **Date:** 2026-10-01
- **Approach:** Keep the conceptual archive model, but implement only the smallest physical schema that supports the first complete product loop.
- **Architecture:** [architecture.md](architecture.md)
- **Decision log:** [product-decisions.md](product-decisions.md)

This document describes the first SQLite schema. One conceptual entity does not automatically require one table.

## V0 boundary

The schema must support:

1. Search for a word in any supported language.
2. View its meaning, alternate forms, translations, examples, audio, and cultural context.
3. Connect words in different languages through a shared concept.
4. Make words inside examples clickable.
5. Accept a contribution without publishing it immediately.
6. Review and publish accepted contributions.
7. Preserve revision history and media attribution metadata.
8. Keep exact lookup, autocomplete, full-text search, and entry-page queries fast at the PD-018 acceptance workload.

It does not attempt to model every future linguistic, editorial, or community feature.

## Storage boundary

| Storage | Responsibility |
| --- | --- |
| SQLite | Text, relationships, submissions, revisions, and media metadata |
| Object storage | Audio, images, and derived media files |
| Browser storage | Unsent drafts, pending uploads, and cached pages; v1 may add offline dictionary packs |

## The ten domain tables

    languages
        |
        └──< entries >── concepts
                |
                ├──< entry_forms
                ├──< example_links >── examples
                └──< media

    submissions ── reviewed by ── moderator_accounts
         |
         ├──< media
         └── approved changes ──> revisions

The ten tables are:

1. **languages**
2. **concepts**
3. **entries**
4. **entry_forms**
5. **examples**
6. **example_links**
7. **media**
8. **submissions**
9. **moderator_accounts**
10. **revisions**

Phoenix authentication tokens, Oban jobs, SQLite internals, and the FTS5 virtual table are infrastructure tables rather than product-domain tables.

## Relationship diagram

~~~mermaid
flowchart TB
  LANG["languages<br/>Which language?"]
  CON["concepts<br/>Shared idea"]
  ENT["entries<br/>One language-specific meaning"]
  FORM["entry_forms<br/>Spellings and transliterations"]
  EX["examples<br/>Reusable sentence"]
  LINK["example_links<br/>Clickable span"]
  MED["media<br/>Audio/image metadata"]
  SUB["submissions<br/>Unreviewed proposal"]
  ACC["moderator_accounts<br/>Reviewer login"]
  REV["revisions<br/>Accepted history"]

  LANG --> ENT
  CON --> ENT
  ENT --> FORM
  EX --> LINK
  ENT --> LINK
  ENT --> MED
  CON --> MED
  SUB --> MED
  ACC --> SUB
  SUB --> REV
  ACC --> REV
~~~

Read it from `entries`: a language says which language the meaning belongs to, a concept connects equivalent entries across languages, and entry_forms contains the searchable ways to write that entry. Examples connect through example_links because one sentence may contain many entries and one entry may appear in many sentences.

## Worked example

The mock WATER record demonstrates the central path:

| Table | Mock rows |
| --- | --- |
| languages | `1 English`, `2 Hindi` |
| concepts | `10 WATER` |
| entries | `100 English WATER meaning`, `101 Hindi WATER meaning` |
| entry_forms | `1000 water` (primary), `1010 पानी` (primary), `1011 paani` (transliteration) |
| examples | `4000 The child will drink water.` |
| example_links | the `water` span points to entry `100`; the `drink` span points to its own entry |
| media | `6000` describes a private original and public playback object for entry `100` |

Searching for either `पानी` or `paani` finds entry `101` through entry_forms. To find its English equivalent, the application follows entry `101` to concept `10`, finds entry `100`, and displays its primary form `water`. There is no pairwise translations table.

The example text is stored once. Its confirmed links make `drink` and `water` independently clickable. If a submitted sentence contains a form shared by several entries—such as two meanings of `bank`—the matcher presents candidates rather than guessing the intended meaning.

Opening the English entry follows:

    entries 100
    ├── languages 1                 → English
    ├── entry_forms 1000           → water
    ├── concepts 10                 → WATER
    │   └── entries 101
    │       └── entry_forms 1010, 1011 → पानी / paani
    ├── example_links → examples 4000
    └── media 6000                  → audio/image metadata and object keys

## Shared conventions

- Use compact SQLite integer primary keys internally.
- Give public and exported records an immutable public_id.
- Store timestamps in UTC.
- Use archived_at for published records that must disappear without breaking old references.
- Use JSON only for small nested lists that are always loaded with their parent.
- Keep large files outside SQLite.
- Keep submissions separate from canonical public records.
- Treat FTS data as derived and rebuildable.

V0 public_id values are application-generated UUID strings stored as SQLite TEXT
(`:binary_id` in Ecto migrations). Integer IDs remain internal.

## 1. languages

### Why it exists

Identifies the language of an entry, example, or translation. Adding a language means adding one row, not adding new columns throughout the schema.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| public_id | TEXT | Stable export identifier |
| slug | TEXT | Stable application name such as hindi |
| code | TEXT, nullable | Standard or project-defined code where one exists |
| name | TEXT | Display/editorial name |
| direction | TEXT | ltr or rtl |
| active | BOOLEAN | Whether new entries may use the language |

Unique indexes: public_id, slug, and non-null code.

No separate language-variety table exists initially. An entry or media row may carry a reviewed variety_label until repeated structured variety data justifies normalization.

## 2. concepts

### Why it exists

Connects entries from different languages that express the same underlying idea.

    Concept: WATER
    ├── English entry: water
    └── Hindi entry: पानी

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| public_id | TEXT | Stable public/export identifier |
| editorial_label | TEXT | Short moderator-facing label |
| editorial_note | TEXT, nullable | Internal clarification |
| archived_at | TIMESTAMP, nullable | Retains stable references |

The editorial label does not make one language canonical.

## 3. entries

### Why it exists

This is the main dictionary table. One row means:

> One word or expression, in one language, with one particular meaning.

It deliberately combines the earlier ideas of lexeme, sense, and definition. Searchable written forms are child rows in entry_forms because they are a performance-critical access path.

If the spelling “bank” has two unrelated meanings, it has two entry rows connected to two concepts. The interface may group those rows into one word page.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| public_id | TEXT | Stable public/export identifier |
| language_id | INTEGER | Required entry language |
| concept_id | INTEGER | Required shared concept |
| definitions | JSON | One or more definitions with their language |
| part_of_speech | TEXT, nullable | Noun, verb, phrase, etc. |
| variety_label | TEXT, nullable | Reviewed regional/community label when known |
| place_label | TEXT, nullable | Broad publishable place label when useful |
| usage_note | TEXT, nullable | Usage guidance |
| cultural_note | TEXT, nullable | Reviewed cultural context |
| archived_at | TIMESTAMP, nullable | Removes it from public results without erasing history |

Example nested value:

    definitions:
      - language: english
        text: Water; a clear liquid used for drinking.

Required foreign keys: language_id and concept_id.

Initial indexes and constraints:

- Unique public_id.
- Unique (id, language_id), used by entry_forms to enforce matching languages.
- Index concept_id.

Application validation prevents an empty definition list and requires exactly one primary entry_forms row before publication. Definitions remain JSON because the first product normally reads and edits them with the entry. Searchable text is flattened into FTS5.

## 4. entry_forms

### Why it exists

Stores every spelling or representation by which an entry can be found. Indexed rows make exact lookup, autocomplete, transliteration search, and automatic example matching fast without reading JSON.

    entry 101: Hindi WATER meaning
      ├── पानी    primary
      └── paani   transliteration

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| entry_id | INTEGER | Required parent entry |
| language_id | INTEGER | Repeated entry language for the hot search index |
| text | TEXT | Displayed spelling or expression |
| normalized_text | TEXT | Application-generated lookup value |
| kind | TEXT | spelling, transliteration, historical, or alias |
| is_primary | BOOLEAN | Whether this is the entry's one displayed primary form |

Initial indexes and constraints:

- Foreign key (entry_id, language_id) references entries(id, language_id), preventing a form from claiming another language.
- Index (normalized_text, language_id, entry_id) for language-agnostic exact and prefix lookup.
- Index (language_id, normalized_text, entry_id) for language-filtered lookup and example matching.
- Unique (entry_id, normalized_text, kind) to prevent accidental duplicate forms.
- Partial unique index on entry_id where is_primary is true.
- Non-empty text and normalized_text.
- kind must be one of the documented values.

Two entries may intentionally have the same form because homographs and distinct meanings are valid. Application validation requires at least one form and exactly one primary form before an entry is published.

## 5. examples

### Why it exists

Stores a reviewed sentence once, even when several words inside it are clickable.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| public_id | TEXT | Stable identifier |
| language_id | INTEGER | Language of the original sentence |
| text | TEXT | Original sentence |
| normalized_text | TEXT | Matching/search form |
| translations | JSON | Small list of translated sentences and their languages |
| archived_at | TIMESTAMP, nullable | Retains history and links |

Example translation:

    - language: hindi
      text: बच्चा पानी पिएगा।

## 6. example_links

### Why it exists

Connects exact spans of an example to the intended dictionary entries. This relationship cannot live neatly inside either parent because one example links to many entries and one entry appears in many examples.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| example_id | INTEGER | Required example |
| entry_id | INTEGER | Exact contextual meaning |
| start_offset | INTEGER | Start of the linked span |
| end_offset | INTEGER | End of the linked span |
| surface_text | TEXT | Expected text at the span |
| role | TEXT | focus or reference |

Initial rules:

- Index example_id and entry_id.
- Offsets are zero-based UTF-8 byte offsets with an exclusive end offset.
- Require end_offset greater than start_offset.
- Derive surface_text from the example and validate that offsets fall on Unicode boundaries.
- Require at least one focus link and reject overlapping confirmed spans.
- Editing example text requires rematching and reconfirming its links.
- Automatic matching produces suggestions; only confirmed matches become rows.

## 7. media

### Why it exists

Describes an audio or image object stored outside SQLite. It combines the earlier media-asset, recording, and image-attachment tables.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| public_id | TEXT | Stable public/export identifier |
| kind | TEXT | audio or image |
| entry_id | INTEGER, nullable | Word/meaning this media describes |
| concept_id | INTEGER, nullable | Concept this image illustrates |
| submission_id | INTEGER, nullable | Pending contribution that currently owns this media |
| original_object_key | TEXT | Preserved original in object storage |
| public_object_key | TEXT, nullable | Public playback/display object |
| mime_type | TEXT | Validated original type |
| byte_size | INTEGER | Original size |
| sha256 | TEXT | Integrity and duplicate detection |
| duration_ms | INTEGER, nullable | Audio |
| width | INTEGER, nullable | Image |
| height | INTEGER, nullable | Image |
| variety_label | TEXT, nullable | Reviewed variety represented |
| place_label | TEXT, nullable | Broad publishable location |
| attribution_text | TEXT, nullable | Approved display attribution |
| processing_state | TEXT | Uploaded, validated, processing, ready, or failed |
| visibility | TEXT | Quarantine, private, public, withdrawn, or pending deletion |
| archived_at | TIMESTAMP, nullable | Retains history |

Initial rules:

- Unique object keys.
- Index entry_id, concept_id, submission_id, sha256, processing_state, and visibility.
- Public media requires a public target and a ready public object.
- Quarantined media may temporarily have no entry or concept.
- A submission and a published entry each have at most one active audio row.

An entry may retain replaced or withdrawn audio rows as history, but exposes at
most one active pronunciation recording. A concept may have several active
images.

## 8. submissions

### Why it exists

Keeps unreviewed material outside canonical public tables.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| public_id | TEXT | Safe receipt identifier |
| client_submission_id | TEXT | Offline idempotency key |
| kind | TEXT | New entry, correction, example, audio, image, or addition |
| target_type | TEXT, nullable | Existing record type |
| target_public_id | TEXT, nullable | Existing record being changed |
| payload | JSON | Original proposal |
| reviewed_payload | JSON, nullable | Moderator-edited working proposal; the original remains unchanged |
| status | TEXT | Pending, reviewing, clarification needed, approved, rejected, or withdrawn |
| review_history | JSON | Small chronological list of review decisions and messages |
| reviewed_by_account_id | INTEGER, nullable | Current/final moderator |
| reviewed_at | TIMESTAMP, nullable | Current/final decision time |
| review_note | TEXT, nullable | Current/final explanation |
| received_at | TIMESTAMP | Server acknowledgement time |

Initial rules:

- Unique public_id and client_submission_id.
- Index (status, received_at).
- Submission payloads and review history are private.

Approval changes canonical tables and creates revisions in one SQLite transaction. Object-storage work completes through an idempotent background job.

## 9. moderator_accounts

### Why it exists

Provides authentication for editors. Contributors do not need accounts initially.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| email | TEXT | Unique normalized moderator email |
| password_hash | TEXT | Password verifier; never a password |
| display_name | TEXT | Moderator attribution |
| active | BOOLEAN | Disables access without deleting history |
| last_login_at | TIMESTAMP, nullable | Operational information |

Phoenix authentication will add its conventional token/session table.

## 10. revisions

### Why it exists

Preserves accepted changes and their provenance without requiring separate source, provenance, and import tables initially.

### Draft columns

| Column | Type | Purpose |
| --- | --- | --- |
| id | INTEGER | Internal primary key |
| target_type | TEXT | Canonical record type |
| target_public_id | TEXT | Stable target identifier |
| action | TEXT | Create, update, archive, restore, merge, or withdraw |
| before_state | JSON, nullable | Previous canonical snapshot |
| after_state | JSON, nullable | New canonical snapshot |
| actor_type | TEXT | Moderator, system, or importer |
| moderator_account_id | INTEGER, nullable | Moderator responsible |
| submission_id | INTEGER, nullable | Contribution that caused the change |
| source | JSON, nullable | Citation, dataset, contributor, collector, or import metadata |
| reason | TEXT, nullable | Human-readable explanation |
| inserted_at | TIMESTAMP | Immutable event time |

Initial rules:

- Index (target_type, target_public_id, inserted_at).
- Index submission_id.
- Append-only in ordinary operation.
- Never include passwords, quarantined object keys, or temporary signed URLs in snapshots.

## Search

Search uses:

1. Normal entry_forms indexes beginning with normalized_text for global search and with (language_id, normalized_text) for language-filtered search and example matching.
2. One rebuildable FTS5 row per active entry.

The FTS row contains entry_id and language_id as unindexed identifiers, plus flattened forms, definitions, notes, and confirmed focus-example text. FTS is a derived index, not the source of truth.

Initial ranking:

1. Exact primary form.
2. Exact alternate form or transliteration.
3. Form prefix.
4. FTS form match.
5. FTS definition, note, or example match.

Autocomplete and full-text responses return a small bounded result set. Alphabetical browse pages use keyset pagination based on the last normalized form and ID rather than deep OFFSET pagination.

For automatic example linking, the application normalizes one sentence, extracts candidate words and phrases, and looks them up through entry_forms. It tries longer phrases first and asks for confirmation when several entries share the same form. It never scans every entry or parses alternate-form JSON.

An entry or confirmed example change updates canonical rows and the corresponding FTS row in the same SQLite transaction. A maintenance operation can discard and rebuild all FTS rows from canonical data.

## Performance baseline

The acceptance dataset is:

- 100,000 published entries.
- Approximately 300,000 entry_forms rows.
- Approximately 200,000 examples.
- Approximately 100,000 media rows, excluding media bytes.
- Twenty concurrent readers and one ordinary writer.

On a 1-vCPU, 1 GB Linux machine with a warmed database cache, initial p95 database-time budgets are:

| Operation | p95 budget |
| --- | ---: |
| Exact-form lookup | Below 10 ms |
| Autocomplete | Below 20 ms |
| Full-text search, first 20 results | Below 50 ms |
| Normal entry-page queries | Below 25 ms |

Benchmarks use representative scripts, spelling collisions, transliterations, definitions, and examples rather than empty generated strings. Each hot query is checked with EXPLAIN QUERY PLAN; unexpected full-table scans and temporary sorts are fixed before another service is considered. Run SQLite's supported planner optimization after migrations and when the dataset changes substantially.

## Privacy boundary

Public pages, APIs, and exports may contain reviewed entries, examples, confirmed links, public media metadata, and approved attribution. Future v1 offline packs use the same public allowlist.

They must not contain:

- Submission payloads or review messages.
- Moderator credentials or sessions.
- Quarantined object keys.
- Temporary signed URLs.
- Private revision metadata.

## Deletion and withdrawal

- Published entries, concepts, examples, and media are archived rather than casually deleted.
- Media withdrawal immediately removes affected media from public queries; cached clients reconcile on their next successful refresh.
- Object deletion occurs asynchronously after the retention policy allows it.
- Submissions and quarantined uploads follow a separate retention policy that remains open.
- Revisions remain append-only except when law or safety requires removal of private information.

## Atomic operations

The following happen inside one SQLite transaction:

- Approve a submission, apply canonical changes, update submission status, and write revisions.
- Create or edit entry forms and refresh the entry's FTS row.
- Change an example and replace all confirmed links.
- Withdraw or archive media and create its revision.

Object-storage operations are recorded as intended state and completed by retryable background jobs.

## Indexes to create initially

- Unique public IDs.
- entries(id, language_id), unique, for the entry_forms composite foreign key.
- entries(concept_id).
- entry_forms(language_id, normalized_text, entry_id).
- entry_forms(normalized_text, language_id, entry_id).
- entry_forms(entry_id, normalized_text, kind), unique.
- entry_forms(entry_id), unique where is_primary is true.
- examples(language_id).
- example_links(example_id) and example_links(entry_id).
- media(entry_id) and media(concept_id).
- media(sha256), media(processing_state), and media(visibility).
- submissions(status, received_at).
- revisions(target_type, target_public_id, inserted_at).

Add no speculative indexes. Use EXPLAIN QUERY PLAN against real queries before adding more.

## Validation records

Before migrations are considered settled, this model must represent:

1. One concept expressed in all launch languages.
2. One spelling with two meanings represented as two entries.
3. Alternate spelling and transliteration search.
4. One example with several clickable words and an ambiguous match.
5. One active pronunciation recording plus retained replacement history for an entry.
6. One media withdrawal.
7. One correction with before-and-after history.
8. One spreadsheet import recorded in revision source metadata.
9. One export and restore with stable public IDs.
10. The PD-018 acceptance dataset meeting its query-plan and latency budgets.

## Deferred evolution

V0 deliberately keeps several values inline or in validated JSON. Promote one only when real records show it needs independent identity, reuse, querying, constraints, permissions, history, or privacy boundaries.

| Deferred structure | Current v0 representation | Promote when |
| --- | --- | --- |
| people and consents | Flat reviewed attribution text on media; anonymous submissions | Repeated contributors or speakers need stable identity, or a supported workflow needs structured grants and withdrawal records |
| language_varieties, places | Reviewed labels on entries/media | Repeated labels need filters, stable identity, hierarchy, or location privacy |
| lexemes and senses | One entry per language-specific meaning | Several meanings need a shared lexical identity or duplicate media/attribution becomes painful |
| definitions | Validated JSON on entries | Definitions need independent review, attribution, ordering, history, or filters |
| example_translations | Validated JSON on examples | Individual translations gain attribution, moderation, audio, or independent queries |
| media_assets | One media row with original and public object keys | One original is reused or several public formats need independent lifecycle tracking |
| submission_events | Current fields plus small review-history JSON | Reviews become collaborative, cyclical, reportable, or concurrently edited |
| sources, provenance_records, import_batches | Structured metadata on revisions | Sources are reused, need public citations, or repeated imports need batch control |
| collections and concept_relationships | Editorial queries and shared concepts | Curators need persistent ordered sets or tested broader/narrower/related navigation |
| contributor_accounts | Contributors submit without login | Cross-device drafts or private clarification require identity |
| external search, graph, or vector store | SQLite indexes and FTS5 | Measured latency/ranking cannot be repaired in SQLite or a validated feature requires semantic similarity |

When promoting a structure, document the failing records or query, the new constraints, the data migration, and the rollback/export effect. Do not normalize only because a richer model looks theoretically cleaner.
