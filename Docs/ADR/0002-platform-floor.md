# ADR-0002: Platform floor macOS 15 / iOS 18 and Linux

- Status: **Accepted** (2026-11-10)

## Context

The package declared macOS 27 only. A review showed that nothing in the core requires it:
Swift-JSON's macOS/iOS 27 minimum was declared rather than needed, one swift-system API
(`FileDescriptor.pipe(options:)`) is macOS 27-only, and `Synchronization.Mutex` needs
macOS 15 / iOS 18. Linux was blocked by CryptoKit, Darwin imports and Darwin's
per-descriptor SIGPIPE flag. The official MCP Swift SDK supports macOS 13+, iOS 16+ and Linux.

## Decision

- Deployment minimums: **macOS 15, iOS 18, Linux**. Development stays on Swift 6.4 with
  the macOS 27 SDK; the toolchain floor does not move.
- Swift-JSON lowers its minimums to macOS 15 / iOS 18 (1.8.1).
- Crypto: CryptoKit on Apple platforms, the API-compatible `swift-crypto` on Linux only.
  Keys are stored as raw bytes and turned into `SymmetricKey` per operation (no
  `@unchecked Sendable`).
- SIGPIPE: Apple keeps the per-open-file `F_NOSIGPIPE` flag. On Linux every write runs on
  the transport's own worker thread, which blocks SIGPIPE in its thread signal mask, so a
  closed peer yields EPIPE. No process-wide signal disposition or handler is installed.
- CI: the self-hosted macOS 27 runner plus a GitHub-hosted Ubuntu 24.04 job in the official
  `swift:6.4.2` image.

## Consequences

- macOS 13/14 would additionally need a replacement for `Synchronization.Mutex`; deferred.
- Runtime behavior on macOS 15–26 and iOS is compiled but not exercised by CI.
- On Linux, a borrowed output descriptor no longer has to carry a SIGPIPE flag
  (`StdioFailure.borrowedDescriptorMustSuppressSIGPIPE` is Darwin-only).
