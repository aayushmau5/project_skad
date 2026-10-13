# Hamskad CSV ingestion

The intake has two steps: prepare a reviewable manifest, then import it into an
explicitly selected SQLite database. Python 3 uses its standard CSV parser;
there are no additional dependencies. The Mix task uses the application's
changesets, publication logic, and full-text search index.

## Prepare and review

```sh
python3 -B scripts/prepare_hamskad.py "$HOME/Downloads/Skad - Hamskad.csv" \
  --output tmp/ingestion/hamskad
```

The source CSV is read only. Generated files under `tmp/` are ignored by Git.
The required columns, in order, are `Word,Meaning,English,Hindi,Village,Region`.
Malformed CSV, missing headers, and wrong column counts fail preparation.

| Output | Purpose |
| --- | --- |
| `manifest.json` | Importable entries, shared concepts, stable UUIDs, source hash, and row references |
| `cleaned.csv` | One accepted word per row, with descriptions and local context |
| `review.csv` | Excluded rows with their original content and a reason |
| `report.json` | Counts, removed duplicates, and repeated spellings with different descriptions or places |
| `report.md` | Readable summary and cleanup rules |

Clear `/`, `;`, and `,` alternatives become separate searchable entries sharing
the same concept. Spaces are preserved inside expressions. Line breaks and
extra whitespace become single spaces, including wrapped compound numbers.
Unicode is normalized to NFC. Trailing delimiters are removed.

Only records with the same normalized spelling, descriptions, village, and
region are deduplicated. Different meanings and village contexts are kept.
Identical sets of descriptions share a concept; matching one English gloss
alone does not merge records. The manifest retains every source row reference
when duplicates are removed.

English and Hindi columns retain their language labels. Additional `Meaning`
text is classified as Hindi when it contains Devanagari and otherwise English;
matching descriptions are removed. Numeric meanings remain literal numbers.
This is script inference, so romanized Hindi needs an explicit Hindi column in
the reviewed source. `Village` becomes `place_label`, and `Region` becomes
`variety_label`. No spellings, translations, or place-name equivalences are
invented.

Rows with embedded explanations or transliterations, missing words or
descriptions, empty alternatives, leading combining marks, or a suspected
word/meaning reversal are excluded for review. The supplied Tree/Bothang pair
is specifically held as a suspected reversal. Correct these rows in a copy of
the original CSV, keeping the six-column layout, then regenerate the outputs.
Source row numbers refer to spreadsheet records, with the header as row 1,
rather than physical lines in a multiline CSV.

Inspect the repeated spellings in `report.json` before merging further. Some
are homographs, near-synonymous descriptions, or village-specific forms; a
language expert needs to distinguish them. A database built before review
contains only the accepted subset.

## Build a fresh database

```sh
mix skad.import tmp/ingestion/hamskad/manifest.json \
  --database tmp/ingestion/hamskad/hamskad.db --fresh
```

`--database` is required. `--fresh` refuses an existing database or SQLite
sidecar files. The task runs migrations and starts only the repository. It
does not run demo seeds or start the web server, and can run locally with the
default development configuration without production object-storage secrets.

All imported language, concept, entry, form, and search-index changes are in
one transaction. A bad entry rolls the dataset back; migrations remain applied.
The task checks SQLite integrity and foreign keys, checkpoints the WAL, and
stops its repository before returning the database path.

To rerun the same manifest, omit `--fresh`:

```sh
mix skad.import tmp/ingestion/hamskad/manifest.json \
  --database tmp/ingestion/hamskad/hamskad.db
```

Imported UUIDs are stable across preparation runs and row ordering. Existing
UUIDs are skipped, preserving later moderator edits. Changed source content
generates new UUIDs: this task is an insert-and-skip import, not a synchronization
or deletion tool. For the initial production dataset, finish review and build
a new database at a new path instead of importing successive corrections into
the same candidate file.

## Production handoff

Keep the original CSV and generated review artifacts with the final database
for provenance. After review, the stopped and checkpointed `.db` file can be
copied to persistent local storage on the single production application host.
Set the release's `DATABASE_PATH` to that file and make it writable by the
application's user. Production endpoint and R2 configuration still come from
the normal release environment. Importing the data does not deploy the app or
create a moderator account.

Do not copy a database while an application is writing to it. Once it is in
service, use the existing `bin/skad-data` maintenance-window backup/restore
workflow, which also includes object-storage state.
