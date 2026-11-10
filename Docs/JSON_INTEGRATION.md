# Swift-JSON integration contract

Swift-JSON is the standalone upstream foundation. P00 verifies its implemented API before the MCP public
facade is frozen. Its approved contracts are represented by hash in Contracts/planning-authority.json;
those planning documents are not copied as private reports into this public repo.

| Need | Upstream ownership | MCP responsibility |
|---|---|---|
| Values/objects/keys/numbers | JSON, JSONObject, JSONKey, JSONNumber | Exact wire projections; scalar-sensitive IDs/names |
| Presence | JSONPresence absent/null/value | Preserve protocol-defined distinctions |
| Parse/write/native coding | JSONParser/JSONWriter/value coder | Finite ingress/egress; reject invalid UTF-8 and lossy conversion |
| Semantic comparisons | Bounded throwing comparison | Use exact documented semantics, never Swift String canonical equality |
| JSON Schema 2020-12 | Compiler/validator, offline registry, immutable plans | Tool/MRTR schemas, generation, errors and policy |
| Regex schema keywords | Upstream qualified ECMA-compatible engine | No secondary MCP regex validator |
| Operation reports/work | Public reports and finite limits | One cumulative request account across stages |

API spellings are proposals until integration proves them. For JSON objects and IDs, test composed versus
decomposed Unicode, duplicate exact keys versus canonically equivalent distinct keys, large integer IDs,
exponent integer forms and lexeme/semantic numeric distinction. Never bridge through `[String: Any]`,
Foundation JSONSerialization, Double fallback or ordinary canonically-equating String dictionary keys.
Request IDs are exact mathematical integers or exact scalar strings; resource URI normalization must not
accidentally collapse protocol-significant identity. Treat scalar name registration consistently.

The schema adapter accepts raw boolean/object JSON schemas, produces immutable compiled generations and
validates offline using an explicit bounded registry. No automatic HTTP/file dereferencing. A catalog
update atomically replaces the generation; an admitted request retains its generation through input,
custom-header extraction and output validation. Validate supported required vocabulary/metaschema;
unsupported assertions must fail registration clearly, not behave as true. JSONSchema suite qualification
belongs to upstream, with MCP integration cases here for input/output/MRTR and x-mcp-header.

**Cross-package work budgeting:** Swift-JSON's package-internal meter cannot be imported here. Sequential
JSON/schema stages receive the remaining finite request allowance, report consumed work through public
operation reports, and debit the server account exactly once. Non-JSON dispatch/encoding operations also
debit that account. Enforce stage-specific byte/depth/reference/cache limits as well as shared work.
A failed bounded operation terminates the request; it cannot restart a fresh full allowance in a helper.
For parallel suboperations reserve finite disjoint allowances before launch, settle reports once and never
share a mutable unprotected counter. Prove cancellation and overflow behavior with native tests.

P00 must demonstrate that public reports exist for successful parse/write/compile/evaluate paths and
that failure paths cannot consume unbounded work. If reports or finite inputs are absent, issue a minimal
upstream interface requirement in Docs/PROGRESS.md. Continue independent wire/runtime work without
modifying the concurrently developed JSON repo or installing a permissive MCP fallback validator.

State parameter binding needs a documented, versioned semantic encoding with scalar-exact keys, stable
ordering and exact normalized numeric meaning. Qualify the upstream writer's relevant modes or write a
small bounded projection encoder over JSON values. It is not a second JSON parser/general writer and
must not be called RFC 8785/JCS without meeting that standard. Never use randomized Hashable hashes as a
cross-process digest. Cache keys include schema generation, resolver registry and semantic options.

M01–M06 integration now consumes the verified frozen RC2 implementation. See
[admission evidence](Evidence/JSONAdmission/README.md) for the real source path,
public API probe, cumulative settlement, conservative unreported reservations,
opaque immutable generation and versioned binding. The historical sibling scaffold
receipt is preserved; local source contents and full-product consumption are
separate qualifications. Q01 remains blocked on the complete SDK consumer.
