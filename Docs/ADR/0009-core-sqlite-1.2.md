# ADR-0009: Qualify Swift-SQLite 1.2.0 on the unified Core graph

- Status: **Proposed for review** (2026-11-24)
- Scope: Core and its local stdio example and fixture.

The A1.5 receipt added Swift-SQLite 1.2.0 to both fixture lockfiles while Core selected 1.0.0. [Version 1.2.0](https://github.com/ThorFuchs/Swift-SQLite/releases/tag/1.2.0) is a stable release; tag commit `df12fe55265de81e2fc4bca91cb85704343b528f` matches both observed additions. Its package dependency minima are satisfied by the existing lock graph.

Set the compatible minimum to 1.2.0 and pin the exact release in all three workspaces. Retain every other selected revision. Recompute v3 origin hashes using the root-manifest SHA-256 algorithm of [SwiftPM 6.4.2](https://github.com/swiftlang/swift-package-manager/blob/swift-6.4.2-RELEASE/Sources/Workspace/Workspace%2BDependencies.swift); verify with native SwiftPM before merge. No new traits, task schema, migrations or SQL changes.

Research Explorer depends on URL-based Core and HTTP branches and is independently versioned. Do not silently repin its remote branch revisions. Its final graph belongs to cross-package consumer qualification.

Native qualification must include the existing SQLite task-store conformance and reopen/durability tests, full macOS/Linux tests, optimized builds and a clean lockfile diff. The historical stdio proof does not establish SQLite 1.2.0 task-store behavior.
