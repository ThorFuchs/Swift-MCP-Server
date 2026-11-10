# Live Wikipedia contract

The selected subset is public per-wiki REST v1 on https://en.wikipedia.org.
Routes are search/page and page/{single-encoded-returned-key}/with_html. The
captured 21 October 2026 response has HTML profile 2.8.0. Unknown profiles are
typed errors, never beta-shape guesses.

Swift-JSON owns JSON parsing/decoding. Positive page/revision Int64 values become
decimal strings without Double conversion; overflow and duplicate keys are denied.
SwiftSoup is example-only, MIT-licensed, and isolated in MediaWikiNormalizer. No DOM crosses actors.

Each provider operation has a 15-second total deadline, at most two attempts,
and only a fitting <=2-second Retry-After on429/503 permits the second attempt.
Two provider operations are admitted at once. Cancellation keeps permits until
their invocation settles. The URLSession iterator has a checked4MiB delivered
cap independent of Content-Length and an actual delegate-completion join.
Redirects are capped at three and revalidate exact HTTPS origin/REST routes.
No ambient cookies, credentials, cache, image or citation fetch is used.

Candidate mappings:128 entries/1MiB logical/300seconds. Snapshots retain the
five-field provider/project/page/revision/normalizer identity, same-key content
guard,16 entries/32MiB logical and300second TTL. Expiry is an explicit absent
snapshot, never a latest-page substitution. Normalization permits4096parts,
depth32,4096references,64citations/part,8192associations and4MiB owned content.
DOM node100000/depth128 checks are **postparse**, not parser allocation/RSS or
preemptive CPU guarantees. Section32KiB, outline128rows, refs20/64associations
and tool128KiB ceilings retain conservative response admission.

Nested sections contribute own prose only. Pseudo/raw IDs receive ordinal safe
IDs; duplicate citation targets remain unresolved. Citation labels are explicit
512-byte excerpts; their source URLs are metadata and are never fetched. Missing
reference metadata remains distinct from an admitted empty list. Tables/media/
math/active elements are omitted and that scope is visible in the reader.

Separate Live-v1 definitions
use enwiki/openWorldHint=true and the same four names. App, catalogs and HTTP host
share the same service instance for a selected profile. No legacy MCP is added.
