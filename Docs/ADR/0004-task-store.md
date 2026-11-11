# ADR-0004: Durable task store protocol and backends

- Status: **Proposed** (2026-11-10)
- Builds on ADR-0003 (`MCPTasks`)

## Context

The Tasks specification requires that a task exists before its ID is returned, that
clients may resume polling after reconnects or restarts, and that unknown or expired IDs
fail with `-32602`. Stage 1 keeps tasks in memory, so a server restart loses every task.
Hosts differ: a local stdio helper wants a single file; a fleet of HTTP servers behind a
load balancer needs one shared task space.

Backends reviewed (2026-11-10):

| Backend | Swift access | Fit for a task store |
|---|---|---|
| **SQLite** | System library on Apple platforms; `libsqlite3` on Linux, or the public-domain amalgamation (as vendored by `vapor/sqlite-nio` 1.13.2, SQLite 3.54.1). Mature wrappers: GRDB 7.12 | **Best fit:** transactional point reads and writes, WAL, single file, every platform including iOS |
| **DuckDB** | `duckdb/duckdb-swift` compiles the C++ engine inside SwiftPM; only dev tags (`v2.1.0-dev…`) | **Poor fit:** analytical and columnar, optimized for bulk reads; many small concurrent updates are its weakest case; heavy build; no stable versions |
| **Turso** (new Rust engine) | No Swift binding (C, Go, Java, JS, Python, Rust, …); `libsql-swift` is a 2024 alpha, unmaintained since mid-2025 | Native embedding is not viable today |
| **libSQL / Turso Cloud (remote)** | HTTP protocol, implementable in pure Swift | **Good fit for shared stores** across server instances |
| **PostgreSQL** | PostgresNIO (NIO dependency) | Good for conventional multi-instance deployments; separate package |

## Decision

1. **`TaskStore` protocol in `MCPTasks`** (no dependencies), owned by the runtime. The
   runtime keeps execution; the store keeps state. Operations, all bounded and owner-scoped:
   - `create(_:)`: atomic insert; returns only once durable (the runtime replies after it).
   - `load(id:owner:)`: `nil` for unknown, expired or foreign (callers map to `-32602`).
   - `transition(id:from:to:)`: optimistic versioning (compare-and-set on a `version`
     counter); terminal states are immutable.
   - `appendInputRequest`, `answerInput(key:)`: exactly-once by key; answered keys stay
     answered.
   - `requestCancellation(id:)`: a durable flag, so another instance owning the work can
     observe it.
   - `expire(before:)`, `count(owner:)` and `recoverable()` (non-terminal tasks after a restart).
   Payloads (`result`, `error`, input requests) are stored as canonical JSON bytes within
   configured size limits.
2. **Backends as separate products**, so the core stays dependency-free:
   - `InMemoryTaskStore` (default, today's behavior);
   - **`MCPTasksSQLite` first**: WAL, `STRICT` tables, versioned migrations, all platforms;
   - libSQL/Turso remote and PostgreSQL later (Phase D of the roadmap), with lease-based
     ownership (`owner instance`, `lease expiry`) for multi-instance servers.
   - **DuckDB is not offered as a task store**; it may later serve as an analytics export.
3. **Store conformance test kit** in a testing module: one suite every backend must pass
   (durability before reply, CAS conflicts, exactly-once input, terminal immutability,
   expiry, owner isolation, recovery).
4. **Restart policy:** non-terminal tasks found at startup become `failed` with
   `statusMessage: "server restarted"`, unless the tool registered a resumer that can
   continue from a stored checkpoint.

## Consequences

- Durable, restart-safe tasks on every supported platform with one small dependency (SQLite).
- Multi-instance deployments get a clear path (remote libSQL, PostgreSQL) without
  burdening single-process hosts.
- Every backend is held to the same behavior by the shared conformance suite.
- Open choice for `MCPTasksSQLite`: system SQLite (smaller, OS-managed version) versus a
  vendored amalgamation (pinned version, identical behavior everywhere). Default
  proposal: system SQLite on Apple platforms, amalgamation on Linux.
