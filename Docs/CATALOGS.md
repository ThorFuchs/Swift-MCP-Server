# Catalogs, providers and caching

Tools expose exact names, descriptions, schemas and annotations; the compiled input/output schema and
custom header plan share one immutable generation. Preserve every core content form and structured
content; check output schema when advertised. Typed coder ergonomics must retain strict bounded JSON.
Provider host failures map deliberately to JSON-RPC error or tool isError according to the operation.

Resources include direct text/binary representations and RFC 6570 URI templates. Qualify a template
implementation against actual level/features required; do not assume string substitution covers it.
Resource-not-found semantics follow the pinned spec/scenario. Binary base64 handling is strict and bounded.
Prompts support argument schemas/modern metadata and all frozen content forms. Completion resolves the
relevant resource/prompt argument context and returns at most 100 values with accurate total/hasMore.

A catalog update atomically replaces schemas and cursor generation. Opaque finite cursors bind principal,
method, salient params and generation with expiry; cursors are not array offsets supplied unvalidated by
a client. Sort/order is deterministic and stable within a generation. Test empty cursor, end-of-list,
wrong principal/method, tampering and expired/replaced generation. Explicit host policy may expose private
catalog views; global caching must never accidentally reuse them across principals.

ttlMs/cacheScope are mandatory for the six complete cacheable methods. Host cache hints are validated,
nonnegative and finite; privacy-sensitive defaults are 0/private. A cache is optional: headers/hints do
not require storing results. If storage exists it has byte/count/TTL bounds and semantic/generation keys.
List pages retain a consistent cacheScope. Intermediate MRTR outcomes are not cached as complete content.
