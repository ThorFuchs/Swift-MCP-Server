# Changelog

## Unreleased

- Client frozen wire preparation: share only immutable, hash-verified protocol plans
  within finite retention limits; validate each response independently. No change to
  the public client API or the original idle deadlines (ADR-0007).
- Stdio client: settle exchanges at stdout EOF, retain stderr until the child has
  completed cleanup, join owned tasks and propagate exact unsuccessful child
  termination. The additive `unsuccessfulTermination` error case affects exhaustive
  switches; caller cancellation remains cancellation (ADR-0008).
- Align Core and the local stdio example/fixture to Swift-SQLite 1.2.0; preserve the
  other resolved revisions (ADR-0009). Native task-store qualification is required.
- Add public-product DocC landing pages and toolchain-native documentation builds;
  retire temporary #53 diagnostics while retaining the regression tests and
  historical qualification snapshot.

- New `MCPClient` product: client for 2026-07-28 with MRTR, listen streams, schema
  validation and `x-mcp-header` mirroring (ADR-0005, Docs/CLIENT.md). `MCPServerTesting`
  gains `LoopbackTransport`; `MCPClientStdio` launches stdio servers with swift-subprocess.

- New `MCPSkills` product: Skills over MCP (`io.modelcontextprotocol/skills`, SEP-2640) with
  `skills/list`, `skills/get`, `resources/directory/read`, SHA-256 manifests and a strict
  frontmatter parser (Docs/SKILLS.md). Official extensions can be server-declared only.

- New `MCPTasks` product: server-side runtime for the Tasks extension
  (`io.modelcontextprotocol/tasks`, 2026-07-28) with task-backed tools, `tasks/get`,
  `tasks/update` and `tasks/cancel` (ADR-0003, Docs/TASKS.md).
- `MCPTasks`: `notifications/tasks` over `subscriptions/listen` (`notifications.taskIds`),
  owner-filtered, initial state after the acknowledgement, latest-state coalescing.
  Official extensions can now contribute `subscriptions/listen` filters (package API).

- Platforms: macOS 15+, iOS 18+ and Linux (was macOS 27 only); see ADR-0002. Linux
  uses swift-crypto and blocks SIGPIPE on the transport's own writer thread.

- Initial import of the consolidated core: `MCPProtocol`, `MCPServer`, `MCPStdio`,
  `MCPServiceLifecycle`, `MCPObservability`, `MCPServerTesting` (MCP 2026-07-28, macOS 27+).
- HTTP transport and authorization moved to the separate Swift-MCP-Server-HTTP package.
- Swift-JSON 1.8.0; dependencies use version ranges.
- `ServerPreparationPolicy` defaults raised to 512M work, 256M compilation and 64M evaluation.
  The previous defaults were too small for a cold preparation of the frozen schema, so
  `Server.make` failed in every fresh process (e.g. stdio servers).
- Server-initiated subscription teardown sends `notifications/cancelled` for the
  `subscriptions/listen` request on every transport, then the complete result.
