# Multi-round requests and protected state

tools/call, resources/read and prompts/get may return input_required. Model `inputRequests` and
`requestState` according to the frozen union: at least one must be present, including state-only rounds.
Multiple input requests and multiple rounds are first-class. Elicitation, sampling/createMessage and
roots/list are input forms in the result, not standalone server-to-client JSON-RPC requests.
Validate client support before issuing inputs and again on retry. Missing responses permit the normative
retry behavior; unrelated extra params/responses are ignored as required. Enforce finite rounds/input count.

Elicitation includes form and URL modes and accept/decline/cancel outcomes with current schema restrictions.
Sampling includes all modern message/content/tool forms; roots has its exact URI/list shape. This package
represents and validates them; host/client provides the UI, model and root semantics. Deprecated fields
still present in the frozen schema are documented wire fields, not extra legacy protocol support.

Continuations carry host-injected AEAD protection using platform CryptoKit. Version the token format,
include key ID, purpose/domain, principal binding, method, parameter digest, issue/expiry time and bounded
opaque handler state. Authenticate every field influencing resumption; reject wrong resource/identity,
unsupported version, corrupt length, unknown key, expiry and modified input. Rotation supports a finite
verify keyring and one active issuing key. Keys and clocks are host-owned; no automatic persistence.

Canonical binding is a documented, versioned bounded semantic projection. Object order and equivalent
number lexemes must follow the chosen semantic binding; string scalars remain distinct. Hash input is
domain-separated and unambiguous. Neither Swift Hashable nor a casually sorted JSON output is a qualified
cross-process binding scheme. Native golden/differential cases must prove it.

Integrity does not prevent replay. Optional atomic consumption stores specify claim/commit/release/expiry
semantics and finite storage; they are separate from cryptographic protection. Define idempotency and
side-effect boundaries under concurrent retry, crash-after-effect and cancellation. Exactly-once effects
cannot be promised without host transactional support. Redact all state tokens from logs/metrics/errors.

## Implemented v0.5 contract

MultiRoundProvider registrations for tools, resources (including templates) and prompts separate
complete JSON from InputInstruction. Existing synchronous/typed handlers remain complete-only.
Intermediate results use InputRequiredResult; complete results use their own frozen schema,
outputSchema/binary/cache checks. Provider version, definition, required scopes/features, descriptors,
replay mode and no-state reconstruction form a stable plan binding. The host must change version
for relevant implementation or effect-policy changes.

Descriptor IDs use ScalarText and exact JSONObject lookup. Registration prepares accepted form
schemas and sampling tool input schemas. Form accept requires valid content; decline/cancel and
URL outcomes cannot carry form content. Sampling validates tools, toolChoice, IDs, inputs, strict
binary and immediately paired tool histories. Roots uses the dated file-URI overlay. The host/client
owns UI, model, tool execution and filesystem semantics.

Retries have fresh admission/authority and a different wire ID. Binding-v1 preserves equivalent
decimal lexemes/object order while distinguishing scalar strings and absent/null values. Original
input/name/URI remain bound; metadata, ID, state, responses and permitted extra params do not.
Literal frozen InputResponses union admission precedes correlation: unrelated schema-valid keys
are ignored, malformed unknown values reject. Partial tokenized retries retain validated responses
and request only the missing subset, without a resume effect or consumption claim.

Every round closes its account/permit/catalog lease/buffers; no task waits for user interaction.
State-only rounds need no responses. Explicit inputOnlyReconstruction is a trusted static descriptor
set and allows integrity-only policy. Without state there is no parameter authentication, chain
counter, retained partial data or global replay guarantee; partial retries re-request the full set.

### Continuation token v1

Format: c1.<ASCII-key-id>.<canonical-unpadded-base64url-AES-GCM-combined-bytes>.
CryptoKit supplies nonce/ciphertext/tag. Associated data is UTF-8 Swift-MCP/continuation, NUL,
version=1, NUL, binding=1, NUL, key ID. This purpose differs from catalog-cursor v1.
Authentication precedes plaintext JSON parsing. Host-owned 32-byte keys, active key, finite ring
(maximum four), clock and namespace/epoch have no automatic persistence or credential installation.

Authenticated claims include format/binding versions, stable namespace/epoch, issuer/subject/resource
digest, method, salient parameter digest, stable prepared plan digest, issue/expiry, attempt/work
limits and spent counters, logical chain/round identity, prior wire-ID digest, expected IDs, validated
responses and handler-state presence/value. Current scopes/capabilities/extensions are independently
checked. Compatible independent Server values resume with the same keys/namespace/epoch/plans;
generation, random instance, origin and connection are excluded. Epoch changes invalidate tokens.
Ciphertext/private state are not reflected in SDK errors or automatically logged.

Defaults:16 attempts/inputs,32KiB token,16KiB encoded state,10-minute original lifetime and
1,024,000,000 chain work units. Checked maxima:64 attempts/inputs,128KiB token,state at most half
token capacity,one-hour lifetime,32,768,000,000 chain units. Plaintext has a half-token ceiling,
so claims overhead can reduce usable state. Each attempt conservatively spends the full configured
requestWork in sealed counters; native reports settle separately in the cumulative request account
with independent subsystem ceilings. Reissuing never renews expiry or counters. Crypto/base64/copy
work prepays32 units per encoded byte plus4096; no upstream report is invented.

### Consumption and host effects

Replay policy is explicitly integrityOnly or consuming(hostStore). Integrity-only replays may
execute; branching token replay does not establish global chain work or invocation bounds.
Consumption hashes a separate purpose, namespace, epoch, authenticated chain and logical round.
New IDs, rotation or refreshed ciphertext cannot bypass the same claim. Validation/current authority
precede claims; missing inputs do not consume a completed effect.

ContinuationConsumption exposes atomic claim/commit/release and finite settlement work. The main
request prepays a separate decreasing cleanup account (maximum16MiB) before claim. The bounded
StateConsumptionStore adapter charges purge/key/storage work before mutation, owns opaque receipts
and rejects contention/expiry, full capacity and duplicate/foreign settlement. Its guarantee is
process-local; stronger cross-process/crash guarantees need a durable transactional host store.

After resume invocation begins, success/error/cancellation conservatively commits. An explicit
ContinuationEffect.releaseForSafeRetry host assertion is allowed only when no effect occurred;
returning success after release rejects. Before provider invocation the SDK releases its known claim.
Host claim callbacks must not throw after leaving an unreturned claim. SDK cancellation cannot
make external effects and store settlement exactly-once; host transactions/idempotency remain required.

The consumption adapter's byte quota conservatively includes receipt/key retention as well as entries;
committed entries may retain that reservation until expiry. Settlement failure is terminal for that
invocation even if a provider catches it. Ordinary public Codable claim failures are invalid state,
while resource/accounting/cancellation failures retain operational behavior.
