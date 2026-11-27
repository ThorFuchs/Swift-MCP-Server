// SPDX-License-Identifier: Apache-2.0
import Foundation
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

/// Failures of the exchange channel or its owning child-process lifetime.
public enum StdioClientTransportError: Error, Sendable, Equatable {
    /// `exchange` was called while `run()` is not active.
    case notRunning
    /// `run()` was called while it is already running or a previous exchange
    /// is still unwinding its caller-owned receiver.
    case alreadyRunning
    /// More concurrent requests than `maximumPendingRequests`, or an exchange
    /// whose bounded delivery inbox cannot accept another frame.
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
    /// Host-selected child process, exchange bounds and diagnostic sink.
    public struct Configuration: Sendable {
        /// Child executable selected by the host.
        public var executable: Executable
        /// Arguments passed directly to the executable.
        public var arguments: [String]
        /// Overrides applied to the inherited process environment. Do not log secrets.
        public var environment: [String: String]
        /// Optional working directory for the child.
        public var workingDirectory: String?
        /// Maximum concurrent admitted exchanges; the initializer clamps this to at least one.
        public var maximumPendingRequests: Int
        /// Maximum bytes accepted in a framed input line.
        public var maximumMessageBytes: Int
        /// Grace interval before forced child termination during cancellation; not an idle deadline.
        public var terminationGrace: Duration
        /// Receives the server's standard error, line by line (ignored when nil).
        public var standardError: (@Sendable (String) -> Void)?
        /// Creates a child configuration; the host chooses the executable and owns its trust boundary.
        public init(executable: Executable, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil,
                    maximumPendingRequests: Int = 64, maximumMessageBytes: Int = 16 * 1024 * 1024, terminationGrace: Duration = .seconds(2),
                    standardError: (@Sendable (String) -> Void)? = nil) {
            self.executable = executable; self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
            self.maximumPendingRequests = max(1, maximumPendingRequests); self.maximumMessageBytes = maximumMessageBytes
            self.terminationGrace = terminationGrace; self.standardError = standardError
        }
    }

    // Per-route bound, in addition to the existing per-line byte limit. A
    // blocked receiver must not block demultiplexing other admitted routes.
    // Overload fails that exchange explicitly rather than silently losing data.
    private static let maximumBufferedFrames = 16

    private struct Frame: Sendable {
        let bytes: Data
        let terminal: Bool
    }
    private struct Route: Sendable {
        let identity: UUID
        let inbox: AsyncStream<Frame>.Continuation
        let progressToken: String?
        let cancellationLine: [UInt8]
        var queuedFrames = 0
        var queuedBytes = 0
        var terminalReceived = false
        var stopped = false
        var failure: StdioClientTransportError?
    }
    private struct State: Sendable {
        var outgoing: AsyncStream<[UInt8]>.Continuation?
        var routes: [String: Route] = [:]
        var running = false
    }

    /// Configuration used for each caller-owned run.
    public let configuration: Configuration
    private let state = Mutex(State())

    /// Constructs the transport without launching a process.
    public init(configuration: Configuration) { self.configuration = configuration }


    // MARK: Lifetime

    /// Launches the server and serves exchanges until it exits, `shutdown()` closes its
    /// input, or the calling task is cancelled. Outstanding requests fail with
    /// `serverExited` when stdout ends without a terminal response (after
    /// admitted frames are delivered). The run owner joins the input writer and
    /// stderr reader and observes the reaped child's termination status. A
    /// nonzero or signal exit throws `unsuccessfulTermination`; caller
    /// cancellation is reported as `CancellationError`.
    public func run() async throws {
        // Outgoing queue accounting is a separate transport-bound audit.
        let (lines, outgoing) = AsyncStream.makeStream(of: [UInt8].self)
        try state.withLock { state in
            guard !state.running, state.routes.isEmpty else { throw StdioClientTransportError.alreadyRunning }
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
                                self.route(Data(line))
                            }
                        }
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

    /// Sends a request on the active child. The caller executes its own ordered
    /// receiver; the shared reader never awaits host code. At most 16 queued
    /// frames and `maximumMessageBytes` queued payload bytes per exchange are
    /// retained, in addition to the frame being delivered. Overflow fails the
    /// exchange with `busy` and cancels a still-active wire request. The slot
    /// stays owned until the caller's receiver has unwound.
    public func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        let identity = UUID()
        let key = Self.key(request.id.value)
        let token = (try? WireCodec.parse(Array(request.body), limits: .balanced).result)?
            .objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["progressToken"]?.stringValue
        guard !request.body.contains(0x0A) else { throw StdioClientTransportError.messageTooLarge }
        let cancellationLine = try Self.cancellation(request.id)
        let (frames, inbox) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingOldest(Self.maximumBufferedFrames))
        try await withTaskCancellationHandler {
            try state.withLock { state in
                try Task.checkCancellation()
                guard state.running, let outgoing = state.outgoing else { throw StdioClientTransportError.notRunning }
                guard state.routes.count < configuration.maximumPendingRequests, state.routes[key] == nil else { throw StdioClientTransportError.busy }
                state.routes[key] = Route(identity: identity, inbox: inbox, progressToken: token,
                    cancellationLine: cancellationLine)
                if case .terminated = outgoing.yield(Array(request.body) + [0x0A]) {
                    state.routes[key] = nil
                    throw StdioClientTransportError.serverExited
                }
            }
            // Only the exchange owner releases capacity. Its receiver is an
            // ordinary awaited call on this task, not a spawned task.
            defer {
                state.withLock { state in
                    if state.routes[key]?.identity == identity { state.routes[key] = nil }
                }
                inbox.finish()
            }
            do {
                for await frame in frames {
                    try state.withLock { state in
                        try Task.checkCancellation()
                        guard var route = state.routes[key], route.identity == identity else { throw StdioClientTransportError.serverExited }
                        if let failure = route.failure { throw failure }
                        route.queuedFrames -= 1
                        route.queuedBytes -= frame.bytes.count
                        state.routes[key] = route
                    }
                    try await receive(frame.bytes)
                    try checkExchange(key, identity: identity)
                    if frame.terminal { return }
                }
                try checkExchange(key, identity: identity)
                // EOF without an admitted terminal response is not success.
                throw StdioClientTransportError.serverExited
            } catch {
                stopExchange(key, identity: identity)
                // Caller cancellation is authoritative when it races failure.
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            // Stop further admission and send at most one active-wire cancel.
            // Do not retire the slot or resume an independent continuation:
            // cooperative host code must unwind on the cancelled caller task.
            self.stopExchange(key, identity: identity)
        }
    }

    private func checkExchange(_ key: String, identity: UUID) throws {
        try state.withLock { state in
            try Task.checkCancellation()
            guard let route = state.routes[key], route.identity == identity else { throw StdioClientTransportError.serverExited }
            if let failure = route.failure { throw failure }
        }
    }

    /// Demultiplexes under one lock, including progress-token lookup. The
    /// reader cannot suspend on a receiver or a full route inbox.
    private func route(_ line: Data) {
        guard let message = try? WireCodec.parse(Array(line), limits: .balanced).result, let object = message.objectValue else { return }
        let params = object["params"]?.objectValue
        let terminal = object["method"] == nil && object["id"] != nil
        let directKey: String?
        let progress: String?
        if terminal, let id = object["id"] {
            directKey = Self.key(id); progress = nil
        } else if let subscription = params?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] {
            directKey = Self.key(subscription); progress = nil
        } else if object["method"]?.stringValue == "notifications/progress", let token = params?["progressToken"]?.stringValue {
            directKey = nil; progress = token
        } else { return }
        state.withLock { state in
            let key = directKey ?? state.routes.first { progress != nil && $0.value.progressToken == progress }?.key
            guard let key, var route = state.routes[key], !route.stopped, !route.terminalReceived else { return }
            // Terminal receipt ends wire ownership, even if the local receiver
            // is suspended or the terminal frame exceeds inbox capacity.
            if terminal { route.terminalReceived = true }
            if route.queuedFrames >= Self.maximumBufferedFrames || line.count > configuration.maximumMessageBytes - route.queuedBytes {
                route.failure = .busy
                Self.stop(&route, outgoing: state.outgoing)
            } else {
                switch route.inbox.yield(Frame(bytes: line, terminal: terminal)) {
                case .enqueued:
                    route.queuedFrames += 1
                    route.queuedBytes += line.count
                    if terminal { route.inbox.finish() }
                case .dropped:
                    // Defensive: explicit accounting must prevent a drop.
                    route.failure = .busy
                    Self.stop(&route, outgoing: state.outgoing)
                case .terminated:
                    route.failure = .serverExited
                    Self.stop(&route, outgoing: state.outgoing)
                @unknown default:
                    route.failure = .serverExited
                    Self.stop(&route, outgoing: state.outgoing)
                }
            }
            state.routes[key] = route
        }
    }

    private static func stop(_ route: inout Route, outgoing: AsyncStream<[UInt8]>.Continuation?) {
        guard !route.stopped else { return }
        route.stopped = true
        if !route.terminalReceived { outgoing?.yield(route.cancellationLine) }
        route.inbox.finish()
    }

    private func stopExchange(_ key: String, identity: UUID) {
        state.withLock { state in
            guard var route = state.routes[key], route.identity == identity else { return }
            Self.stop(&route, outgoing: state.outgoing)
            state.routes[key] = route
        }
    }

    private func finishAll(resetLifetime: Bool = true) {
        state.withLock { state in
            state.outgoing?.finish()
            // Drain already admitted frames in order, including a terminal
            // received before EOF. An unterminated exchange throws serverExited
            // after draining. Do not remove routes owned by unwinding callers.
            for route in state.routes.values { route.inbox.finish() }
            // The process owner joins its I/O tasks and child. A new run is
            // refused while any prior caller still owns an exchange slot.
            if resetLifetime {
                state.running = false
                state.outgoing = nil
            }
        }
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
