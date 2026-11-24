// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

// Local child programs, not MCP schema or network fixtures. No host signal
// changes, shared file paths or timing-dependent startup probes.
private func shell(_ script: String, arguments: [String] = [],
                   onStderr: (@Sendable (String) -> Void)? = nil) -> StdioClientTransport {
    StdioClientTransport(configuration: .init(
        executable: .path("/bin/sh"),
        arguments: ["-c", script, "stdio-lifecycle"] + arguments,
        standardError: onStderr))
}

private final class CapturedStderr: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var snapshot: [String] { lines.withLock { $0 } }
}

// These tests are bounded by a test-only guard. The production termination
// grace, readiness and idle policies are not changed.
@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioChildLifecycleCases {
    @Test func stdoutEOFStillDrainsLateStderrAndJoinsCleanly() async throws {
        let stderr = CapturedStderr()
        let transport = shell("""
            trap - PIPE
            printf '%s\\n' START >&2
            exec 1>&-
            while IFS= read -r line; do :; done
            # Simulate legitimate child cleanup *after* stdout closes and stdin
            # reaches EOF. The EOF handshake, not the delay, orders the streams.
            sleep 0.2
            printf '%s\\n' CLEAN >&2
            exit 0
            """, onStderr: { stderr.append($0) })
        try await transport.run()
        #expect(stderr.snapshot == ["START", "CLEAN"])
        await #expect(throws: StdioClientTransportError.notRunning) {
            _ = try await Client(transport: transport).discover()
        }
    }

    @Test func nonzeroExitMustNotReturnSuccess() async {
        let transport = shell("exit 23")
        await #expect(throws: StdioClientTransportError.unsuccessfulTermination(.exited(23))) {
            try await transport.run()
        }
    }

    @Test func signaledChildMustNotReturnSuccess() async {
        // Only the controlled test child signals itself.
        let transport = shell("kill -KILL $")
        await #expect(throws: StdioClientTransportError.unsuccessfulTermination(.signaled(9))) {
            try await transport.run()
        }
    }

    @Test func abnormalExitDoesNotLeaveTransportRunning() async {
        let transport = shell("exit 23")
        for _ in 0..<2 {
            await #expect(throws: StdioClientTransportError.unsuccessfulTermination(.exited(23))) {
                try await transport.run()
            }
            await #expect(throws: StdioClientTransportError.notRunning) {
                _ = try await Client(transport: transport).discover()
            }
        }
    }

    @Test func hostCancellationIsNotReportedAsChildFailureOrSuccess() async throws {
        let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let transport = shell("""
            printf '%s\\n' READY >&2
            while IFS= read -r line; do :; done
            exit 0
            """, onStderr: { line in
                if line == "READY" {
                    signal.yield(())
                    signal.finish()
                }
            })
        defer { signal.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.run() }
            var iterator = ready.makeAsyncIterator()
            let started = await iterator.next()
            try #require(started != nil)
            group.cancelAll()
            do {
                _ = try await group.next()
                Issue.record("cancelled run returned success")
            } catch is CancellationError {
                // The caller's cancellation is authoritative.
            } catch {
                Issue.record("unexpected cancellation error: \(error)")
            }
        }
        await #expect(throws: StdioClientTransportError.notRunning) {
            _ = try await Client(transport: transport).discover()
        }
    }

    @Test func pendingRequestFailsAtStdoutEOFBeforeChildFinishesStderr() async throws {
        // A per-test file is an explicit acknowledgement from the caller.
        // The child closes stdout after accepting a request, then waits for
        // that acknowledgement before writing its final diagnostic.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-stdio-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let acknowledgement = directory.appendingPathComponent("exchange-ended")
        let stderr = CapturedStderr()
        let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish() }
        let transport = shell("""
            trap - PIPE
            printf '%s\\n' READY >&2
            IFS= read -r request || exit 41
            exec 1>&-
            # Finite safety guard only: success depends on the explicit
            # acknowledgement, not on a guessed scheduling delay.
            i=0
            while [ ! -f "$1" ]; do
                i=$((i+1))
                [ "$i" -lt 200 ] || exit 42
                sleep 0.05
            done
            printf '%s\\n' CLEAN >&2
            exit 0
            """, arguments: [acknowledgement.path], onStderr: { line in
                stderr.append(line)
                if line == "READY" {
                    signal.yield(())
                    signal.finish()
                }
            })

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.run() }
            var iterator = ready.makeAsyncIterator()
            let started = await iterator.next()
            try #require(started != nil)
            let request = OutgoingRequest(id: .integer(JSONNumber(integer: 1)),
                method: "server/discover", name: nil,
                body: Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover"}"#.utf8))
            await #expect(throws: StdioClientTransportError.serverExited) {
                try await transport.exchange(request) { _ in
                    Issue.record("child sent an unexpected response")
                }
            }
            // The previous run still owns a live child and stderr reader.
            await #expect(throws: StdioClientTransportError.alreadyRunning) {
                try await transport.run()
            }
            try Data().write(to: acknowledgement, options: .atomic)
            try await group.waitForAll()
        }
        #expect(stderr.snapshot == ["READY", "CLEAN"])
    }
}
