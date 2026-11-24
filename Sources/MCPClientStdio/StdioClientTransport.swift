// SPDX-License-Identifier: Apache-2.0
import Foundation
#if CORE53_DIAGNOSTICS
import Dispatch
#endif
import JSON
import MCPClient
import MCPProtocol
import Subprocess
import Synchronization
#if canImport(System)
import System
#else
import SystemPackage
#endif

public enum StdioClientTransportError: Error, Sendable, Equatable {
    /// `exchange` was called while `run()` is not active.
    case notRunning
    /// `run()` was called while it is already running.
    case alreadyRunning
    /// More concurrent requests than `maximumPendingRequests`.
    case busy
    /// The server closed its output or exited; in-flight requests are lost.
    case serverExited
    /// A line longer than `maximumMessageBytes`.
    case messageTooLarge
    /// The child was reaped, but did not exit successfully. The exact exit
    /// code or signal is preserved. Cancellation and primary I/O errors take
    /// precedence; outstanding exchanges still fail with `serverExited`.
    case unsuccessfulTermination(TerminationStatus)
}

/// The stdio transport for MCP 2026-07-28: launches the server as a child process and
/// exchanges newline-delimited JSON-RPC messages over its standard input and output.
///
/// The host owns the lifetime: run `run()` in its own child task, then call `shutdown()`
/// (closes the server's input, the graceful signal) or cancel `run()` (SIGTERM, then
/// SIGKILL after `terminationGrace`). Everything happens inside `run()`; nothing is
/// detached. All requests share the one channel: responses are routed by JSON-RPC `id`,
/// progress by its `progressToken`, listen-stream events by `subscriptionId`. Log messages
/// cannot be correlated on stdio and are dropped. Cancelling a call sends
/// `notifications/cancelled` for its ID.
public final class StdioClientTransport: ClientTransport, Sendable {
    public struct Configuration: Sendable {
        public var executable: Executable
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?
        public var maximumPendingRequests: Int
        public var maximumMessageBytes: Int
        public var terminationGrace: Duration
        /// Receives the server's standard error, line by line (ignored when nil).
        public var standardError: (@Sendable (String) -> Void)?
        public init(executable: Executable, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil,
                    maximumPendingRequests: Int = 64, maximumMessageBytes: Int = 16 * 1024 * 1024, terminationGrace: Duration = .seconds(2),
                    standardError: (@Sendable (String) -> Void)? = nil) {
            self.executable = executable; self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
            self.maximumPendingRequests = max(1, maximumPendingRequests); self.maximumMessageBytes = maximumMessageBytes
            self.terminationGrace = terminationGrace; self.standardError = standardError
        }
    }

    private struct Route: Sendable {
        let receive: @Sendable (Data) async throws -> Void
        let done: CheckedContinuation<Void, any Error>
        let progressToken: String?
    }
    private struct State: Sendable {
        var outgoing: AsyncStream<[UInt8]>.Continuation?
        var routes: [String: Route] = [:]
        var running = false
    }

    public let configuration: Configuration
    private let state = Mutex(State())

    public init(configuration: Configuration) { self.configuration = configuration }

    #if CORE53_DIAGNOSTICS
    private func core53ProcessTrace(_ event: String) {
        let line = "[core53-process] pid=\(ProcessInfo.processInfo.processIdentifier) tick_ns=\(DispatchTime.now().uptimeNanoseconds) transport=\(ObjectIdentifier(self)) \(event)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    #endif

    // MARK: Lifetime

    /// Launches the server and serves exchanges until it exits, `shutdown()` closes its
    /// input, or the calling task is cancelled. Outstanding requests fail with
    /// `serverExited` when stdout ends. The run owner joins the input writer and
    /// stderr reader and observes the reaped child's termination status. A
    /// nonzero or signal exit throws `unsuccessfulTermination`; caller
    /// cancellation is reported as `CancellationError`.
    public func run() async throws {
        // Outgoing lines are bounded by the pending-request limit plus one cancellation each.
        let (lines, outgoing) = AsyncStream.makeStream(of: [UInt8].self)
        try state.withLock { state in
            guard !state.running else { throw StdioClientTransportError.alreadyRunning }
            state.running = true; state.outgoing = outgoing
        }
        defer { finishAll() }
        var options = PlatformOptions()
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: configuration.terminationGrace)]
        let environment = Environment.inherit.updating(configuration.environment.mapValues { Optional($0) }.reduce(into: [:]) { $0[.init(rawValue: $1.key)!] = $1.value })
        let setup = Subprocess.Configuration(executable: configuration.executable, arguments: Arguments(configuration.arguments),
            environment: environment, workingDirectory: configuration.workingDirectory.map { FilePath($0) }, platformOptions: options)
        let limit = configuration.maximumMessageBytes, errors = configuration.standardError
        do {
            let result = try await Subprocess.run(setup, input: .inputWriter, output: .sequence, error: .sequence) { execution in
                #if CORE53_DIAGNOSTICS
                self.core53ProcessTrace("event=child.launched child_pid=\(execution.processIdentifier.value)")
                #endif
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await line in lines {
                            _ = try await execution.standardInputWriter.write(line)
                        }
                        try await execution.standardInputWriter.finish()
                    }
                    group.addTask {
                        var reader = LineReader(limit: limit)
                        for try await chunk in execution.standardError {
                            for line in try chunk.withUnsafeBytes({ try reader.feed(Array($0)) }) {
                                errors?(String(decoding: line, as: UTF8.self))
                            }
                        }
                    }
                    group.addTask {
                        var reader = LineReader(limit: limit)
                        for try await chunk in execution.standardOutput {
                            for line in try chunk.withUnsafeBytes({ try reader.feed(Array($0)) }) where !line.isEmpty {
                                try await self.route(Data(line))
                            }
                        }
                        #if CORE53_DIAGNOSTICS
                        self.core53ProcessTrace("event=stdout.eof child_pid=\(execution.processIdentifier.value)")
                        #endif
                        // No further response is possible. End exchanges and
                        // finish stdin, but keep the run lifetime and stderr
                        // reader alive until the child has finished its cleanup.
                        self.finishAll(resetLifetime: false)
                    }

                    // Observe every task result. Normal stdout EOF does not
                    // cancel stderr. On a real failure, structured task-group
                    // teardown cancels siblings and swift-subprocess owns the
                    // process termination and descriptor cleanup.
                    while try await group.next() != nil {}
                }
            }
            #if CORE53_DIAGNOSTICS
            core53ProcessTrace("event=child.terminated child_pid=\(result.processIdentifier.value) status=\(String(reflecting: result.terminationStatus))")
            #endif
            try Task.checkCancellation()
            guard result.terminationStatus.isSuccess else {
                throw StdioClientTransportError.unsuccessfulTermination(result.terminationStatus)
            }
        } catch {
            // Cancellation is the caller's decision, not an unexpected child
            // signal/exit. Otherwise preserve the original operation failure.
            try Task.checkCancellation()
            throw error
        }
    }

    /// Closes the server's standard input, the graceful shutdown signal; `run()` returns
    /// once the server exits.
    public func shutdown() { state.withLock { $0.outgoing }?.finish() }

    // MARK: Exchanges

    public func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let key = Self.key(request.id.value)
        let token = (try? WireCodec.parse(Array(request.body), limits: .balanced).result)?
            .objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["progressToken"]?.stringValue
        guard !request.body.contains(0x0A) else { throw StdioClientTransportError.messageTooLarge }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                let refused: (any Error)? = state.withLock { state in
                    guard state.running, let outgoing = state.outgoing else { return StdioClientTransportError.notRunning }
                    guard state.routes.count < configuration.maximumPendingRequests, state.routes[key] == nil else { return StdioClientTransportError.busy }
                    state.routes[key] = Route(receive: receive, done: done, progressToken: token)
                    if case .terminated = outgoing.yield(Array(request.body) + [0x0A]) {
                        state.routes[key] = nil
                        return StdioClientTransportError.serverExited
                    }
                    return nil
                }
                if let refused { done.resume(throwing: refused) }
            }
        } onCancel: {
            // Stop waiting at once and tell the server; later messages for this ID are dropped.
            let (route, outgoing) = state.withLock { state in (state.routes.removeValue(forKey: key), state.outgoing) }
            guard let route else { return }
            route.done.resume(throwing: CancellationError())
            if let line = try? Self.cancellation(request.id) { outgoing?.yield(line) }
        }
    }

    /// Delivers one server line to its request. Awaiting the receiver is the backpressure.
    private func route(_ line: Data) async throws {
        guard let message = try? WireCodec.parse(Array(line), limits: .balanced).result, let object = message.objectValue else { return }
        let params = object["params"]?.objectValue
        let key: String?
        let terminal: Bool
        if object["method"] == nil, let id = object["id"] {
            key = Self.key(id); terminal = true
        } else if let subscription = params?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] {
            key = Self.key(subscription); terminal = false
        } else if object["method"]?.stringValue == "notifications/progress", let token = params?["progressToken"]?.stringValue {
            key = state.withLock { state in state.routes.first { $0.value.progressToken == token }?.key }; terminal = false
        } else { return }
        guard let key, let route = state.withLock({ $0.routes[key] }) else { return }
        do { try await route.receive(line) }
        catch {
            if let failed = state.withLock({ $0.routes.removeValue(forKey: key) }) { failed.done.resume(throwing: error) }
            return
        }
        if terminal, let finished = state.withLock({ $0.routes.removeValue(forKey: key) }) { finished.done.resume() }
    }

    private func finishAll(resetLifetime: Bool = true) {
        let routes = state.withLock { state -> [Route] in
            state.outgoing?.finish()
            // stdout EOF closes exchanges immediately, but a second run must
            // not acquire this transport until the first child has been joined.
            if resetLifetime {
                state.running = false
                state.outgoing = nil
            }
            defer { state.routes = [:] }
            return Array(state.routes.values)
        }
        for route in routes { route.done.resume(throwing: StdioClientTransportError.serverExited) }
    }

    private static func key(_ id: JSON) -> String {
        switch id {
        case .string(let text): "s:" + text
        case .number(let number): "n:" + ((try? number.integer(as: Int64.self)).map(String.init) ?? "\(number)")
        default: "x"
        }
    }

    private static func cancellation(_ id: RequestID) throws -> [UInt8] {
        let params = JSON.object(try JSONObject(members: [JSONMember("requestId", value: id.value)]))
        let message = JSON.object(try JSONObject(members: [JSONMember("jsonrpc", value: .string("2.0")),
            JSONMember("method", value: .string("notifications/cancelled")), JSONMember("params", value: params)]))
        return Array(try WireCodec.write(message, limits: .balanced).result) + [0x0A]
    }
}

/// Splits a byte stream into lines (`\n`, optional preceding `\r`), bounded per line.
struct LineReader {
    let limit: Int
    private var pending: [UInt8] = []
    init(limit: Int) { self.limit = limit }
    mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var lines: [[UInt8]] = []
        for byte in bytes {
            if byte == 0x0A {
                if pending.last == 0x0D { pending.removeLast() }
                lines.append(pending); pending = []
            } else {
                pending.append(byte)
                guard pending.count <= limit else { throw StdioClientTransportError.messageTooLarge }
            }
        }
        return lines
    }
}
