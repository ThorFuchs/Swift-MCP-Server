# Changelog

## Unreleased

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
