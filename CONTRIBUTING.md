# Contributing to Skad

You can help with code, documentation, interface translations, accessibility, or knowledge of Kinnaur's languages. Preserve differences between speakers and places, and include context when a word has a local form or meaning.

## Share language knowledge

Use **Contribute** in the application to suggest a word. On a word's page, you can suggest a correction or add an example, recording, image, or more information. These contributions need no account and are reviewed before publication.

Include the language, village or community, and source when known. Share recordings and images only with permission for public use. Language records belong in the contribution flow; pull requests are for changes to the software, documentation, and development fixtures.

## Issues and pull requests

- Check existing issues and pull requests before starting. Discuss larger changes in an issue so they fit the project's direction.
- For a bug, include steps to reproduce, expected and actual behavior, and relevant browser or environment details.
- Fork the repository, create a branch, and keep each pull request focused on one change.
- Explain the problem, what changed, and how you checked it. Include screenshots for interface changes in both Hindi and English.
- Use synthetic examples in tests and reports. Keep credentials, contributor details, and unpublished submissions out of the repository.

## Development setup

Install Erlang and Elixir using the versions in [`.tool-versions`](.tool-versions). Native dependencies also need a C compiler and Make. Node.js is needed to run the JavaScript tests; Docker with Compose is optional for testing media uploads.

From the repository root:

```sh
mix setup
mix phx.server
```

`mix setup` installs dependencies, creates the local SQLite database, loads the seed archive, and builds assets. Open [localhost:4000](http://localhost:4000). Search and text contributions work without object storage.

### Moderator access

Create a local moderator account in another terminal:

```sh
mix skad.moderator.create moderator@example.test "Local Moderator"
```

The command displays a generated password once. Use it to sign in at [localhost:4000/moderator/log-in](http://localhost:4000/moderator/log-in).

### Local media storage

The included Compose configuration starts RustFS and creates the private development bucket:

```sh
docker compose up -d
docker compose ps -a
```

The S3 endpoint is `http://127.0.0.1:9000`, and the console is at [127.0.0.1:9001](http://127.0.0.1:9001). Development defaults are:

| Setting | Default |
| --- | --- |
| `R2_ENDPOINT` | `http://127.0.0.1:9000` |
| `R2_REGION` | `us-east-1` |
| `R2_BUCKET` | `skad-private` |
| `R2_ACCESS_KEY_ID` | `SKADLOCAL` |
| `R2_SECRET_ACCESS_KEY` | `skad-local-development-secret` |

These defaults are configured in `config/runtime.exs`. Export overrides in the application terminal before starting Phoenix; Compose reads the same bucket and credential variables.

Stop the store while keeping its named volume:

```sh
docker compose down
```

Production storage and backup instructions live in [architecture.md](docs/architecture.md#production-object-storage).

## Making changes

- Read [Design.md](Design.md) before changing an interface, interaction, or translated copy. Keep public pages usable on phones and without JavaScript, and check Hindi as well as English.
- Follow the coding conventions in [AGENTS.md](AGENTS.md). Reuse existing components and dependencies; use `Req` for HTTP requests.
- Add or update tests for changed behavior. Use stable DOM IDs for interface assertions, and generate migrations with `mix ecto.gen.migration`.
- Document changes in the existing [architecture](docs/architecture.md), [data model](docs/data-model.md), or [product decisions](docs/product-decisions.md) where appropriate. Deferred work belongs in [future.md](docs/future.md).

## Checks before a pull request

Run the project's required checks:

```sh
mix precommit
```

This compiles with warnings treated as errors, checks for unused dependency locks, formats code, and runs the Elixir tests. For JavaScript changes, also run:

```sh
node --test test/assets/*.mjs
mix assets.build
```

For interface changes, check keyboard navigation, visible focus, and the Hindi and English layouts at a narrow phone width and 200% zoom.
