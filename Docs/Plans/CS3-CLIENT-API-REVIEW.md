# CS3: client API review before the first stable tag

Status: accepted 2026-11-15 (all of A1–A11); implemented on `feat/client-api-cs3`. Scope: the public API of `MCPClient`, `MCPClientStdio`,
`MCPTasksClient`, `MCPSkillsClient` (core) and `MCPHTTPClient`, `MCPClientAuthorization` (HTTP
repository) as on `main` after #25 and HTTP #9. Goal: decide what changes before the client's
first stable 0.x tag. Changes after the tag must be additive.

Principles used for each finding:
- Typed views for what the 2026-07-28 schema fixes. Every view keeps `raw`, so nothing the
  server sent is lost and extensions stay reachable.
- Errors are `Equatable` where their payload allows it. Callers and tests should be able to
  match them without string parsing.
- No tuples in public API (not `Equatable`, not extensible).
- Handlers stay `@Sendable` closures. The client owns no tasks; cancellation is the calling
  task's.

## A. Breaking changes, before the tag

| # | Today | Proposal | Why |
|---|---|---|---|
| A1 | `readResource(_:) -> [JSON]` | `-> [ResourceContents]`, an enum with `.text(uri:mimeType:text:)`, `.blob(uri:mimeType:data:)` and `raw` | The schema fixes both shapes; every caller decodes base64 by hand today |
| A2 | `getPrompt(_:arguments:) -> JSON` | `-> PromptResult` (`description`, `messages: [PromptMessage]` with `role` and `content: Content`, `raw`) | Same reason; prompts are the second most used primitive |
| A3 | `ToolResult.content: [JSON]` | `content: [Content]`, an enum with `.text`, `.image(data:mimeType:)`, `.audio`, `.resourceLink`, `.embeddedResource`, `.unknown(JSON)`; `text` keeps working | Shared with A2; `.unknown` keeps future content types |
| A4 | `complete(...) -> JSON` | `-> Completion` (`values`, `total`, `hasMore`, `raw`); `reference:` becomes `CompletionReference` (`.prompt(name)`, `.resourceTemplate(uri)`) | The reference is a fixed two-case union |
| A5 | `listResourceTemplates -> Page<JSON>` | `-> Page<ResourceTemplate>` (`uriTemplate`, `name`, `title`, `description`, `mimeType`, `raw`) | Consistent with `Resource` |
| A6 | `rejectedTools: [(name: String, reason: String)]` | `[RejectedTool]`, a struct that is `Sendable` and `Equatable` | No tuples in public API |
| A7 | `ClientConfiguration.logLevel: String?`, `LogMessage.level: String` | `LoggingLevel` enum (the eight RFC 5424 levels) | Invalid values are a programming error today |
| A8 | `ServerDescription.serverInfo: JSON?` | `serverInfo: Implementation?` (`name`, `version`, `title`, `raw`) | Every host shows it |
| A9 | `listen(_ notifications: JSON, ...)` | `listen(_ filter: SubscriptionFilter, ...)`; the struct has `toolsListChanged`, `promptsListChanged`, `resourcesListChanged`, `resourceSubscriptions` and `extensions: [String: JSON]` | Typos in filter keys are silently ignored by servers |
| A10 | `ClientError` is not `Equatable`; the `-32021` and well-known codes are magic numbers | `ClientError: Equatable` (`JSON` is `Hashable`); add `ClientError.Code` constants (`methodNotFound`, `invalidParams`, `missingRequiredCapabilities`, ...) | Matching errors without `case let` boilerplate |
| A11 | `InputHandler = (JSON) async throws -> JSON` for elicitation, sampling and roots | Typed handlers: `ElicitationRequest -> ElicitationResponse`, `SamplingRequest -> SamplingResponse`, `() -> [Root]`. A raw `(JSON) -> JSON` variant stays for extensions | The largest source of malformed responses; elicitation content is already schema-checked, so a typed `accept(content:)`/`decline`/`cancel` is natural |

## B. Additive, can follow the tag

| # | Proposal |
|---|---|
| B1 | Pagination helpers: `allTools()`, `allResources()`, `allPrompts()` as `AsyncThrowingStream` with a page limit |
| B2 | `Tool.annotations` and `Tool.execution` (task support) as typed optional fields |
| B3 | `HTTPClientTransportError` and `StdioClientTransportError` gain `Equatable` where missing, plus a shared `isRetryable` |
| B4 | `ToolResult.structuredContent` decoded through a caller-supplied Swift-JSON schema-validated type (`structured(as:)`) |
| B5 | `OAuthClient`: an `authorizationState` stream (unauthorized, authorizing, authorized) for host UI |

## C. Contracts to document (DocC), no code change

- **Cancellation.** Cancelling the calling task cancels the exchange: stdio sends
  `notifications/cancelled`, HTTP closes the stream. MRTR rounds stop between rounds, and
  handlers see cancellation through `Task.isCancelled`.
- **Concurrency.** `Client` is an actor; requests run concurrently on the callers' tasks. The
  only state is the latest `tools/list` metadata (headers, output schemas) and `rejectedTools`.
- **Validation.** Every response is checked against the frozen 2026-07-28 schema. With
  `validatesStructuredContent`, `structuredContent` is checked against `outputSchema`, and
  elicitation content against `requestedSchema`. `request(_:)` checks only the JSON-RPC shape.
- **Limits.** `ClientConfiguration.limits` bounds parsing; transports bound message size and
  pending requests.
- **Lifetimes.** The caller owns the transports' `HTTPClient` and stdio process lifetimes
  (`run()`/`shutdown()`).

## D. Documentation and example

- DocC catalogs for `MCPClient`, `MCPClientStdio`, `MCPTasksClient`, `MCPSkillsClient` (core)
  and `MCPHTTPClient`, `MCPClientAuthorization` (HTTP). Today only the server products have one.
- `Examples/ExampleClient`: a command-line client that connects over stdio to
  `Examples/StdioServer`, then:
  1. discovers;
  2. lists and calls tools (answering an elicitation);
  3. reads a resource;
  4. listens for list changes until interrupted.

## Order

1. A1–A5 and A3 (content types) together, since they share `Content`.
2. A6–A10.
3. A11 (typed handlers), the largest change; the conformance fixture is updated in the same PR.
4. C and D after the API settles, then the 0.x tag.

The B items go into the roadmap as post-tag work.
