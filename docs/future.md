# Future work

## Contribution payload

The current `new_entry` payload is intentionally a flat, single-language shape so the complete contribution and moderation loop can be built now. It supports one optional example sentence in the entry's language; multiple examples and translated examples belong in the final payload design. Before public launch, settle the full multi-language form and payload, then update submission validation, approval mapping, and tests together. Because there will be no durable public submissions before that decision, the payload may be reshaped in place without preserving a compatibility contract.

## Foolproof so we don't need observability

Limit every input, test every weird combination, and make sure it is *done*.

## Ratelimiting

Perhaps.
