# A2.2c.2a — JSON-RPC envelope integrity (#29)

Status 2026-11-28: test-only preparation; native RED/control run NOT_RUN.

## Immutable baseline

A2.2c.1 native GREEN: [accepted receipt](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7230377078).
Commit `ca6c86b0ddddc16a3f49c7d1424818e61adc105e`, tree `d0d9c9ad121f4ccf82e5d991855f8cf8f76a805f`.
Original GREEN archive `core-a22c1-green-RiHnHUDM.tar.gz`,
57,548 bytes, SHA-256
`56caa90be5017524f7bc2da71cd593e4a4d1d33a7ef5b23be75220f2a07623ce`.
24 focused Debug + 24 focused Release + 392 full Debug = 440 accepted
cumulative executions. Archive hash, stage ledger and the two original
source blobs were independently rechecked before this test preparation.
Client.swift `eaf5b91a37c582a13f845cda856c0246a9a1d617` and
ClientMRTRContractTests.swift `1b62d295e3065090dc8eed79092f46ab757599ca`
remain unchanged. Keep the six archived dependency hashes identical.

## Authority and boundary

Frozen [base protocol](../../Reference/Protocol/docs/specification/2026-07-28/basic/index.mdx)
(blob `ca66326493885137571aedb98b29737f7b1708a8`),
[message patterns](../../Reference/Protocol/docs/specification/2026-07-28/basic/patterns/index.mdx),
[progress](../../Reference/Protocol/docs/specification/2026-07-28/basic/patterns/progress.mdx),
[MRTR](../../Reference/Protocol/docs/specification/2026-07-28/basic/patterns/mrtr.mdx),
[schema](../../Reference/Protocol/schema/2026-07-28/schema.json)
(blob `213c58f6d9a1c2ce6ad055afe90bbdb095a29ee8`),
[CS3](../Plans/CS3-CLIENT-API-REVIEW.md), and
[ClientTransport](../../Sources/MCPClient/ClientTransport.swift).
The base protocol incorporates JSON-RPC 2.0. Response result/error are
mutually exclusive, errors have integer code and string message, a
correlatable response must have the request's ID, notifications have
no ID and optional object params. Servers cannot initiate JSON-RPC
requests. Missing resultType alone means legacy complete; explicit
non-string resultType is not that case. Notifications precede the
terminal response. In MRTR even input_required terminates its individual
exchange, although the logical operation may have another round.

The frozen generated schema uses open object shapes and anyOf unions,
so membership alone is not a proof of exclusive message kind. The
client's fail-closed error category (ClientError.invalidResponse) is
SDK policy, not a mandated JSON-RPC error emitted to a server. Reject
unrepresentable error codes rather than inventing an Int code; this is
a local public type boundary, not a normative 64-bit protocol limit.
An error without an ID can be a valid protocol error for a malformed
request, but cannot be admitted as the correlated terminal of the
normal, already identified exchange in these tests. Do not require an
error's optional data to be an object; preserve absent versus null.
Preserve legacy -32002 and ordinary version retry; unknown extension
notification methods with valid envelope and optional object params
are still compatible. Do not impose a closed-world list of extension
payload fields or a new extension resultType policy in this slice.

Source audit of Client.perform/dispatch/serverError at qualified base:
- JSON-RPC version and ID checks are already present; second response
  is rejected. However result/error presence is not checked as XOR;
  the error branch wins even if a result is also present.
- serverError uses code 0 and empty message as fallback for malformed
  values. A malformed -32022 envelope may consequently enter retry.
- Generic request has no method-specific definition in the complete
  branch. A present non-string resultType can fall back to complete.
- Dispatch checks the typed schemas of known notifications; a mixed
  notification/response or malformed params of an unknown method may
  evade kind/shape checks. A subscription already guards against
  notifications after its final response, ordinary calls do not.
- These are source hypotheses; no new production changes without
  actual named native RED witnesses.

## New finite transport-neutral suite

[ClientEnvelopeContractTests.swift](../../Tests/MCPClientTests/ClientEnvelopeContractTests.swift),
test commit `5275ef59904c6d98c93071141ad39252e5790132`, blob `58fb0e6706dc51c700304c935acb9da8b8c2720b`.
24 functions, some with finite subcases. Predicted 13 PASS controls,
11 RED functions; predictions are not observations.

| Test function | Contract | Static prediction |
| --- | --- | --- |
| validProgressAndLogPrecedeTerminal | ordered valid callbacks and terminal | PASS |
| legacyMissingResultTypeRemainsComplete | omitted discriminator compatibility | PASS |
| rawExtensionResultPreservesFields | generic result raw fields | PASS |
| validServerErrorsPreserveCodeMessageAndOptionalData | typed error, legacy code, absent/null/array data | PASS |
| validVersionRetryRemainsSingleAndUsesFreshID | one permitted retry, new ID, repeated error stops | PASS |
| responseIDMustCorrelateExactly | foreign/string/fraction/null/bool/missing ID; uncorrelatable error | PASS |
| missingResultAndErrorIsInvalid | neither terminal field | PASS |
| resultAndErrorCannotCoexist | both fields, including explicit null error | RED |
| mixedVersionErrorCannotTriggerRetryOrHost | input_required plus retryable error, no host/retry | RED |
| errorMustBeAnObjectWithRequiredMembers | null/array/string/empty/missing code or message | RED |
| errorCodeMustBeRepresentableInteger | wrong type/fraction/overflow; no fabricated code | RED |
| errorMessageMustBeString | numeric/null/object | RED |
| malformedVersionErrorCannotTriggerRetry | -32022 with missing message | RED |
| resultMustBeObjectEvenForGenericRequest | scalar/null/array results, typed and raw | PASS |
| explicitNonStringResultTypeIsNotLegacyAbsence | generic explicit null/number/object/array | RED |
| notificationCannotContainResultOrError | mixed envelope must not reach progress callback | RED |
| malformedNotificationParamsCannotBeIgnoredAsExtension | explicit null/array/scalar params | RED |
| unknownNotificationWithOptionalObjectParamsRemainsCompatible | unknown method, absent/object params | PASS |
| serverInitiatedRequestDoesNotInvokeSampling | no standalone server request | PASS |
| duplicateTerminalCannotStartInputHandler | two terminals, no host or retry | PASS |
| progressAfterTerminalCannotInvokeCallbackOrContinueMRTR | complete and input-required boundaries | RED |
| logAfterTerminalCannotInvokeCallback | no post-terminal log callback | RED |
| emptyExchangeIsNoResponseNotServerError | exact noResponse | PASS |
| foreignProgressTokenIsNotDelivered | unmatched progress ignored, valid progress received | PASS |

The script uses actual outgoing ID and progress-token bytes, bounded
plans and explicit exchange/delivery receipts. It awaits receive and
propagates errors; some adversarial sequences intentionally violate
ClientTransport's terminal-delivery contract. They prove only defense
at Client's admission boundary, not physical transport delivery.
A separate valid second exchange permits observing an erroneous
retry rather than masking it with fixture exhaustion. Negative probes
require the correct local error category, expected exchange count and
zero host callbacks; where applicable valid controls verify ordered
progress/log callbacks. No sleeps, detached tasks, private inspection,
network, model or process. No production changes.

Authoring: exact local test blob and remote readback match, Swift
6.2.1 Linux x86_64 parse and Swift language-mode-6 typecheck with stub
public JSON/MCP API types passed. 56 representative fixture rendering
and JSON parsing controls passed (includes repeated literal checks,
not 56 distinct SDK tests). These are not actual frozen validator
or native SDK compilation results.

## Native acceptance

On reserved Studio, exact detached candidate with unchanged dependency
files, native Apple Swift 6.4.2, macOS 27+ ARM64:
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter ClientEnvelopeContractCases

Archive exact source/commit/tree, actual log, command and tee exits,
all 24 named outcomes and case receipts, static pin inventory, six
before/after dependency hashes and original archived dependency bytes.
Confirm the native SDK build succeeds. A nonzero exit alone is not RED:
require intact inventory, successful controls, named assertion and
exchange/callback receipts. Record deviations from predictions; a
fixture error, compile failure or timeout is unresolved. Keep original
24 MRTR tests and new tests byte-identical when correcting reproduced
defects. Full Debug expected 416 functions if only these 24 tests are
added to 392. Do not count subcases as separate test functions.

A2.2c.2b batch-wide admission, 2c cooperative cancellation, 2d sampling
semantics and 2e exact input key/round-limit/version-retry interaction
remain separate. A2.2b owns physical routing/teardown, A2.2d retained
state, A2.3 consumer APIs; coordinate before modifying shared
Client.swift and integrate serially. No production fix, transport/API/
dependency/Reference/CI change, PR, merge or release decision in this
test-only batch. release_gate NOT_EVALUATED.
