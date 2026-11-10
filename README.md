# Swift-MCP-Server

A Swift server SDK for the [Model Context Protocol](https://modelcontextprotocol.io)
(protocol revision **2026-07-28**), with a stdio transport for local assistants.

> **Status: pre-release (working towards 1.0.0-rc.1).** The API can still change.
> See [Known issues](#known-issues).

## Requirements

- macOS 27 or later
- Swift 6.4 (Xcode 27), Swift 6 language mode

## Products

| Product | Purpose |
|---|---|
| `MCPProtocol` | Dated wire model, frozen schema validation, JSON-RPC envelopes |
| `MCPServer` | Server runtime: tools, resources, prompts, subscriptions, bounded request budgets |
| `MCPStdio` | Newline-delimited stdio transport with owned descriptors, backpressure and cancellation |
| `MCPServiceLifecycle` | Integration with [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) |
| `MCPObservability` | swift-log / swift-metrics / service-context hooks; no global bootstrap |
| `MCPServerTesting` | Test helpers for servers built on `MCPServer` |

HTTP (Streamable HTTP and authorization) ships separately as **Swift-MCP-Server-HTTP**.
It waits for a SwiftNIO release with macOS 27 early-EOF support
([apple/swift-nio#3783](https://github.com/apple/swift-nio/pull/3783)).

## Installation

```swift
.package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", from: "1.0.0")
```

then add `MCPServer` and `MCPStdio` (and optionally `MCPServiceLifecycle`) to your target.

## Quick start

A complete stdio server lives in [`Examples/StdioServer`](Examples/StdioServer):

```bash
swift run --package-path Examples/StdioServer ExampleStdioServer
```

## Development

```bash
Scripts/test.sh
```

builds the stdio fixture and example binaries that the subprocess tests need, then runs
`swift test`. Plain `swift test` also works, but the subprocess and example tests then
fail on purpose because their binaries are missing. They are never skipped silently.

Process: [ADR-0001](Docs/ADR/0001-lean-process.md) (pull requests, CI, short ADRs).
Design notes are in [`Docs/`](Docs).

## Known issues

Both regressions below are carried over from the pre-1.0 line and must be fixed before RC1:

- With default limits, `Server.make` fails at startup: compiling the frozen schema exceeds the
  `evaluationWorkUnits` budget by one unit (294,660 vs 294,659). Every subprocess and example
  test therefore fails (15 tests). This is independent of the Swift-JSON version (1.7.0 and 1.8.0).
- `StateEventsTests.replaceableEventsCoalesceBehindAcknowledgementAndLateTokenCannotEmit`
  fails deterministically.
- Some design documents still refer to the retired gate process (Q01–Q11, P00–P12).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
