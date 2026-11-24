# Swift-MCP-Server

A Swift server and client SDK for the [Model Context Protocol](https://modelcontextprotocol.io)
(protocol revision **2026-07-28**), with local stdio transports, bounded runtime ownership and offline wire validation.

> **Status: pre-release (working towards 1.0.0-rc.1).** The API can still change.
> See [Known issues](#known-issues).

## Requirements

- macOS 15 or later, iOS 18 or later, or Linux
- Swift 6.4 (on macOS: Xcode 27), Swift 6 language mode

## Products

| Product | Purpose |
|---|---|
| `MCPProtocol` | Dated wire model, frozen schema validation, JSON-RPC envelopes |
| `MCPServer` | Server runtime: tools, resources, prompts, subscriptions, bounded request budgets |
| `MCPStdio` | Newline-delimited stdio transport with owned descriptors, backpressure and cancellation |
| `MCPServiceLifecycle` | Integration with [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) |
| `MCPObservability` | swift-log / swift-metrics / service-context hooks; no global bootstrap |
| `MCPServerTesting` | Test helpers for servers built on `MCPServer` |
| `MCPClient` | Client for 2026-07-28: MRTR, listen streams, response validation, tool header mirroring ([Docs/CLIENT.md](Docs/CLIENT.md)) |
| `MCPTasks` | Server-side Tasks extension: durable task handles, polling, input and cancellation ([Docs/TASKS.md](Docs/TASKS.md)) |
| `MCPSkills` | Skills over MCP: `skill://` resources, `skills/list` / `skills/get` manifests with digests, directory reads ([Docs/SKILLS.md](Docs/SKILLS.md)) |
| `MCPClientStdio` | Host-owned local subprocess transport for MCP clients (macOS and Linux) |
| `MCPTasksTesting` | Common task-store conformance kit |
| `MCPTasksSQLite` | Durable task-store backend based on Swift-SQLite |
| `MCPTasksClient` | Task-aware client calls, polling and subscriptions |
| `MCPSkillsClient` | On-demand manifest and digest-verified skill loading |
| `MCPApps` | Server-side MCP Apps resource and tool metadata |

HTTP (Streamable HTTP and authorization) ships separately as **Swift-MCP-Server-HTTP**.
It waits for a SwiftNIO release with macOS 27 early-EOF support
([apple/swift-nio#3783](https://github.com/apple/swift-nio/pull/3783)).

## Installation

```swift
.package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", branch: "main")
```

> Pre-release example only. For reproducible builds use a reviewed immutable commit revision;
> the stable 1.0.0 version constraint applies only once that release exists.

Then add `MCPServer` and `MCPStdio` (and optionally `MCPServiceLifecycle`) to your target.

## Quick start

A minimal stdio server lives in [`Examples/StdioServer`](Examples/StdioServer); the full example
app is the [Research Explorer](Examples/ResearchExplorer) (stdio CLI + macOS app):

```bash
swift run --package-path Examples/StdioServer ExampleStdioServer
```

## Documentation

The SDK has a DocC catalog for each public SwiftPM product. Start with
[MCPServer](Sources/MCPServer/MCPServer.docc/MCPServer.md),
[MCPClient](Sources/MCPClient/MCPClient.docc/MCPClient.md) and
[MCPClientStdio](Sources/MCPClientStdio/MCPClientStdio.docc/MCPClientStdio.md).
The detailed [client guide](Docs/CLIENT.md), [Tasks guide](Docs/TASKS.md) and
[Skills guide](Docs/SKILLS.md) describe consumer workflows.

On the supported Swift 6.4 / Xcode 27 development host, build local DocC archives:

```bash
bash Scripts/build-docs.sh
```

This builds all 15 modules under `.build/docs/` with warnings treated as errors.
An optional module-name argument limits the conversion (for example
`bash Scripts/build-docs.sh MCPClient MCPClientStdio`). Symbol coverage and
generated documentation must be qualified with the same source and dependency graph.

The [Core #53 qualification record](Docs/Release/CORE_53_INTEGRATED_QUALIFICATION.md)
documents the shared frozen plan cache and the child-process lifetime correction
with reproducible historical evidence. It is not a release approval.

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

- Some design documents still refer to the retired gate process (Q01–Q11, P00–P12).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
