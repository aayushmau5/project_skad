# Disposable review deployment

The review release runs on one Render Free web service with SQLite and temporary
media storage. It includes the cleaned Hamskad archive: 1,731 entries grouped into
1,579 words. Audio and image uploads use signed URLs served by Phoenix, with the
same submission and moderator approval flow as normal production.

Render Free sleeps after 15 minutes without traffic. Opening the app again can
take about a minute. Restarting, redeploying, or waking the service can discard
review submissions and uploaded media. The original Hamskad archive is restored
from `priv/review/skad.sqlite3` whenever the runtime database is absent.

The packaged database contains public archive records only. Moderator accounts,
sessions, submissions, revisions, examples, and media are excluded. On first boot,
the release creates `moderator@test.com` using the password configured in
`SKAD_REVIEW_MODERATOR_PASSWORD`.

## Render configuration

Deploy the `render-dev-deployment` branch from the existing GitHub repository.
Use the Free plan in Singapore, build with `./bin/build-review`, and start with
`_build/prod/rel/skad/bin/review`. Use `/ready` as the health check.

`render.yaml` records the same configuration. Auto-deployment is disabled so a
branch push does not interrupt reviewers.

Required environment variables:

| Variable | Value |
| --- | --- |
| `ELIXIR_VERSION` | `1.20.4` |
| `ERLANG_VERSION` | `29.1.1` |
| `SKAD_REVIEW_INSTANCE` | `true` |
| `DATABASE_PATH` | `/tmp/skad-review/skad.sqlite3` |
| `POOL_SIZE` | `2` |
| `SECRET_KEY_BASE` | A generated secret of at least 64 bytes |
| `SKAD_REVIEW_MODERATOR_PASSWORD` | A configured password of at least 12 characters |

Render supplies `PORT` and `RENDER_EXTERNAL_HOSTNAME`. A custom domain can use
`PHX_HOST` instead. Store secrets in Render, never in the repository.

## Local production check

Build with `./bin/build-review`. To start the release, set the review variables
above, use an isolated local database path and an unused port, set `PHX_HOST` to
`localhost`, and run `_build/prod/rel/skad/bin/review`.

## Normal production

This mode is intended for disposable design reviews. Normal production uses
durable SQLite storage and R2, with `SKAD_REVIEW_INSTANCE` unset. The review startup
script refuses to run outside review mode, and the temporary media routes are
disabled outside review mode.

References: [Render Free limitations](https://render.com/docs/free),
[Phoenix deployments](https://render.com/docs/deploy-phoenix).
