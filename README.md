# Project Skad

Project Skad is a living multilingual archive for the languages of Kinnaur. It is intended to preserve more than word-to-word translations: spellings, meanings, pronunciation, examples, cultural context, contributors, consent, and editorial history all belong to the record.

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

## Current stage

The product direction, v0 architecture, and first data model are settled enough to begin implementation. The next useful step is a thin vertical slice: import a small reviewed dataset, search it, view an entry, submit a change, and approve it through the real persistence path.

## Existing source material

- [Current Zed Tells website](https://www.zedtells.com/)
- [Existing dictionary dataset](https://docs.google.com/spreadsheets/d/1DP8Y66XIfZoM14Zteo_EtUKmlRfT1woa86i6TVPoVHY/edit?gid=0#gid=0)
- [Existing contribution form](https://docs.google.com/forms/d/e/1FAIpQLScqBV3_pVMQ_morV5zkwu-OjV7sNfBku9as9ai1w-ma61BNKQ/viewform)
- [Donate-a-word responses](https://docs.google.com/spreadsheets/d/1DS5h6Q38MUHDRvJ1w335q3VCbD9AnS0ZYafQIv4y1k8/edit?gid=2013417617#gid=2013417617)

## Historical artifacts

- [first-web.png](first-web.png) is an early interface sketch.
- `mock/` contains an exploratory website prototype.

They are useful references, but they do not define the product or architecture.

## Why build the core rather than extend DictPress?

DictPress helped establish the desired single-binary deployment ergonomics, but Project Skad needs first-class multilingual concepts, reusable linked examples, contribution review, consent, media, and revision history. Keeping those concerns in one small Skad application is simpler than splitting the product between DictPress and companion services.
