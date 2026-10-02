# Future work

## Contribution payload

The current `new_entry` payload is intentionally a flat, single-language shape so the complete contribution and moderation loop can be built now. It supports one optional example sentence in the entry's language; multiple examples and translated examples belong in the final payload design. Before public launch, settle the full multi-language form and payload, then update submission validation, approval mapping, and tests together. Because there will be no durable public submissions before that decision, the payload may be reshaped in place without preserving a compatibility contract.

## Foolproof so we don't need observability

Limit every input, test every weird combination, and make sure it is *done*.

## Ratelimiting

Perhaps.

## Total

1. **Pilot deployment**
   - Standard Mix release
   - Production secrets and persistent data paths
   - Caddy/TLS and service management
   - Health/readiness endpoint
   - Migration, deployment, rollback, and fresh-host smoke tests

2. **Automated backup operations**
   - Schedule [bin/skad-data](/Users/aayushmau5/Documents/my-projects/kadh/bin/skad-data)
   - Copy backups off-host
   - Retention policy
   - Failure alerts
   - Periodic restore drills

3. **Browser resilience**
   - Locally retained contribution drafts
   - Visible retry states
   - Resumable/multipart media uploads

4. **Media hardening**
   - Clean abandoned quarantined uploads
   - Server-side checksum verification
   - Detect and decode actual file types
   - Image dimensions/audio duration limits
   - Normalized renditions
   - Introduce Oban only when these jobs require durable retries

5. **Operational validation**
   - Representative 100k-entry performance test
   - Query-plan and latency checks
   - Slow/interrupted-network testing
   - Structured logging, telemetry, and alerting

6. **Import/export**
   - Reviewed dataset imports
   - Provenance metadata
   - Stable public/export identifiers
   - Restore-compatible exports

7. **Later product work**
   - Public licensing, attribution, retention, and takedown policies
   - Show identical written forms with different meanings more clearly
   - Burrito packaging after a standard release is proven
   - Offline dictionary packs in v1
