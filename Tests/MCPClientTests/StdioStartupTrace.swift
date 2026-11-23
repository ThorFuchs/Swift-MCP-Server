// SPDX-License-Identifier: Apache-2.0
import Foundation
#if CORE53_DIAGNOSTICS
import Dispatch
#endif
import Synchronization
import MCPClientStdio

/// Per-test instrumentation for Core #53. No production transport changes and no
/// process-global mutable state. Sequence numbers order events within one test.
/// Cross-test lines from different tasks/processes must not be treated as causally ordered.
final class StdioStartupTrace: Sendable {
    private struct State: Sendable {
        var sequence = 0
        var notRunningAttempts = 0
    }

    private let state = Mutex(State())
    private let started = ContinuousClock.now
    private let testName: String

    init(_ testName: String) { self.testName = testName }

    func mark(_ event: String) {
        let line = state.withLock { state -> String in
            state.sequence += 1
            let elapsed = started.duration(to: ContinuousClock.now)
            #if CORE53_DIAGNOSTICS
            let tick = "tick_ns=\(DispatchTime.now().uptimeNanoseconds) "
            #else
            let tick = ""
            #endif
            return "[core53] \(tick)pid=\(ProcessInfo.processInfo.processIdentifier) test=\(testName) seq=\(state.sequence) elapsed=\(elapsed) event=\(event)\n"
        }
        FileHandle.standardError.write(Data(line.utf8))
    }

    func notRunning() {
        let attempts = state.withLock { state -> Int in
            state.notRunningAttempts += 1
            return state.notRunningAttempts
        }
        // Deliberately bounded output: do not turn a readiness race into a log storm.
        if attempts == 1 || attempts == 10 || attempts == 100 || attempts % 500 == 0 {
            mark("discover.notRunning attempts=\(attempts)")
        }
    }

    func ready() {
        let attempts = state.withLock { $0.notRunningAttempts }
        mark("discover.ready priorNotRunning=\(attempts)")
    }

    func fixtureLine(_ line: String) {
        if line.hasPrefix("READY") || line.hasPrefix("CLEAN") || line.hasPrefix("STOP") || line.hasPrefix("FAIL") {
            mark("fixture.stderr \(line)")
        }
    }

    func run(_ transport: StdioClientTransport) async throws {
        #if CORE53_DIAGNOSTICS
        mark("transport.id=\(ObjectIdentifier(transport))")
        #endif
        mark("run.enter")
        do {
            try await transport.run()
            mark("run.return")
        } catch {
            mark("run.throw \(String(reflecting: error))")
            throw error
        }
    }
}
