# Future work

This is the single backlog for deliberately deferred work. Current behavior is
documented in the README and architecture; completed implementation plans do
not belong here.

## Archive stewardship

- Decide public licenses, attribution, retention, and takedown policies for
  text, recordings, images, and exports.
- Capture source/citation, contributor or collector, language variety/place,
  speaker or photographer attribution, and permission/consent where the
  workflow requires them.
- Carry reviewed provenance into `revisions.source` and public media
  attribution without exposing private submission data.
- Settle the full multi-language contribution payload, including multiple and
  translated examples, before durable public submissions make compatibility
  expensive.

## Media lifecycle and abuse controls

- Expire unclaimed quarantine uploads and delete their stored objects.
- Delete objects after records enter `pending_deletion`, subject to the final
  retention policy.
- Verify uploaded checksums and actual file types; decode media to enforce
  image dimensions and audio duration limits.
- Add rate limits to anonymous uploads and contributions, and to moderator
  login attempts.
- Produce normalized renditions only when real devices or file sizes justify
  them.
- Introduce durable background jobs only when processing latency or retry needs
  can no longer be handled safely in the bounded synchronous path.

## Browser resilience

- Retain contribution fields, client submission UUIDs, and selected media IDs
  locally until the server acknowledges the submission.
- Keep failed sends visible with an explicit retry action.
- Add multipart/resumable uploads only if real file sizes and interrupted
  connections justify the extra protocol state.

## Operational safeguards

- Run `mix precommit` in CI.
- Schedule encrypted, off-host backup copies with retention, failure alerts,
  and periodic restore drills.
- Document and exercise production deploy, migration, rollback, and fresh-host
  smoke-test procedures.

## Data portability

- Add reviewed dataset imports with provenance metadata.
- Define stable, restore-compatible public exports.

## Later product work

- Present identical written forms with different meanings more clearly.
- Revisit Burrito packaging after a standard release is proven.
- Consider versioned offline dictionary packs for v1.
