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
    /// More concurrent requests than `maximumPendingRequests`, a reserved
    /// request ID or progress token, exhausted identity retirement budget,
    /// or an exchange with a full delivery inbox.
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
    // Shared by active and unresolved retired identities for one child run.
    // These are logical key charges, not allocator/RSS or aggregate I/O bounds.
    private static let maximumReservedIdentities = 256
    private static let maximumReservedIdentityBytes = 256 * 1024
    private static let identityOverhead = 64

    // Wire identities are scalar strings or exact mathematical integers.
    // Swift String canonical equivalence and machine-width numeric narrowing
    // cannot represent this distinction. JSONNumber hashes mathematical value.
    private enum WireIdentity: Sendable, Hashable {
        case string(ScalarText)
        case integer(JSONNumber)

        init?(_ value: JSON?) {
            guard let value else { return nil }
            switch value {
            case .string(let text): self = .string(ScalarText(text))
            case .number(let number) where number.isInteger: self = .integer(number)
            default: return nil
            }
        }
    }

    // Charge the actual stored key. Parsed integer digits are no longer than
    // their retained lexeme; charge both. Constructed integer spelling is
    // bounded by the same codec (no exponent-sized dense expansion).
    private static func identityCharge(_ value: JSON) throws -> Int {
        switch value {
        case .string(let text):
            let bytes = text.utf8.count
            guard bytes <= maximumReservedIdentityBytes - identityOverhead else { throw StdioClientTransportError.busy }
            return identityOverhead + bytes
        case .number(let number) where number.isInteger:
            let bytes = try WireCodec.write(value, limits: .balanced).result.count
            let length = max(bytes, number.originalLexeme?.utf8.count ?? 0)
            guard length <= (maximumReservedIdentityBytes - identityOverhead) / 2 else { throw StdioClientTransportError.busy }
            return identityOverhead + 2 * length
        default: throw WireFailure.invalidRequest
        }
    }

    private struct Frame: Sendable {
        let bytes: Data
        let terminal: Bool
    }
    private struct Route: Sendable {
        let identity: UUID
        let inbox: AsyncStream<Frame>.Continuation
        let progressToken: WireIdentity?
        let isListen: Bool
        let reservationCharge: Int
        let cancellationLine: [UInt8]
        var queuedFrames = 0
        var queuedBytes = 0
        var terminalReceived = false
        var identitiesReusable = false
        var stopped = false
        var failure: StdioClientTransportError?
    }
    private struct State: Sendable {
        var outgoing: AsyncStream<[UInt8]>.Continuation?
        var routes: [WireIdentity: Route] = [:]
        // A reservation belongs either to a live local route or to an
        // unresolved retired request. No insertion is needed on cancellation.
        // ID and token namespaces remain independent.
        var reservedIDs: Set<WireIdentity> = []
        var reservedTokens: Set<WireIdentity> = []
        var reservedBytes = 0
        var running = false

        mutating func reserve(_ key: WireIdentity, token: WireIdentity?, charge: Int) throws {
            let count = token == nil ? 1 : 2
            guard !reservedIDs.contains(key),
                  token.map({ !reservedTokens.contains($0) }) ?? true,
                  reservedIDs.count + reservedTokens.count <= maximumReservedIdentities - count,
                  charge <= maximumReservedIdentityBytes - reservedBytes else {
                throw StdioClientTransportError.busy
            }
            reservedIDs.insert(key)
            if let token { reservedTokens.insert(token) }
            reservedBytes += charge
        }

        mutating func release(_ key: WireIdentity, token: WireIdentity?, charge: Int) {
            reservedIDs.remove(key)
            if let token { reservedTokens.remove(token) }
            reservedBytes -= charge
        }

        mutating func resetReservationsIfIdle() {
            // EOF alone is not process teardown; nor may a new run overtake
            // a prior caller still executing its receiver.
            guard !running, routes.isEmpty else { return }
            reservedIDs.removeAll()
            reservedTokens.removeAll()
            reservedBytes = 0
        }
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
            state.resetReservationsIfIdle()
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
    /// stays owned until the caller's receiver has unwound. Request IDs and
    /// progress tokens reserve one of 256 keys and a shared 256 KiB logical
    /// identity budget before wire admission. Unanswered or unproven-terminal
    /// identities stay reserved until the child run and its routes have ended.
    public func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        let identity = UUID()
        guard !request.body.contains(0x0A) else { throw StdioClientTransportError.messageTooLarge }
        // Reserve the actual wire identity, not a potentially inconsistent
        // metadata ID or token lost through a failed best-effort parse.
        let message = try WireCodec.parse(Array(request.body), limits: .balanced).result
        guard let object = message.objectValue,
              object["jsonrpc"]?.stringValue == "2.0",
              let rawID = object["id"], let key = WireIdentity(rawID),
              WireIdentity(request.id.value) == key,
              let method = object["method"]?.stringValue,
              ScalarText(method) == ScalarText(request.method),
              object["result"] == nil, object["error"] == nil else { throw WireFailure.invalidRequest }
        let rawToken = object["params"]?.objectValue?["_meta"]?.objectValue?["progressToken"]
        let token = WireIdentity(rawToken)
        if rawToken != nil, token == nil { throw WireFailure.invalidRequest }
        let charge = try Self.identityCharge(rawID) + (rawToken.map { try Self.identityCharge($0) } ?? 0)
        guard charge <= Self.maximumReservedIdentityBytes else { throw StdioClientTransportError.busy }
        let cancellationLine = try Self.cancellation(request.id)
        let (frames, inbox) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingOldest(Self.maximumBufferedFrames))
        try await withTaskCancellationHandler {
            try state.withLock { state in
                try Task.checkCancellation()
                guard state.running, let outgoing = state.outgoing else { throw StdioClientTransportError.notRunning }
                guard state.routes.count < configuration.maximumPendingRequests, state.routes[key] == nil else { throw StdioClientTransportError.busy }
                // Admission and reservation are atomic with respect to the
                // reader and cancellation. Refusal emits no request or cancel.
                try state.reserve(key, token: token, charge: charge)
                state.routes[key] = Route(identity: identity, inbox: inbox, progressToken: token,
                    isListen: method == "subscriptions/listen", reservationCharge: charge, cancellationLine: cancellationLine)
                if case .terminated = outgoing.yield(Array(request.body) + [0x0A]) {
                    state.routes[key] = nil
                    state.release(key, token: token, charge: charge)
                    throw StdioClientTransportError.serverExited
                }
            }
            // Only the exchange owner releases capacity. Its receiver is an
            // ordinary awaited call on this task, not a spawned task.
            defer {
                state.withLock { state in
                    if let route = state.routes[key], route.identity == identity {
                        state.routes[key] = nil
                        // Unanswered and malformed-terminal routes leave the
                        // pre-reserved keys in place. No eviction or late-frame
                        // reconciliation can accidentally reopen an identity.
                        if route.identitiesReusable {
                            state.release(key, token: route.progressToken, charge: route.reservationCharge)
                        }
                        state.resetReservationsIfIdle()
                    }
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

    private func checkExchange(_ key: WireIdentity, identity: UUID) throws {
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
        let terminal = object["method"] == nil
        let subscription = params?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"]
        let directKey: WireIdentity?
        let progress: WireIdentity?
        if terminal {
            guard let key = WireIdentity(object["id"]) else { return }
            directKey = key; progress = nil
        } else {
            // Only notifications (not server requests) may carry these
            // routing fields. Do not use subscription metadata to override
            // a progress token or a conflicting cancellation requestId.
            guard object["id"] == nil, let method = object["method"]?.stringValue else { return }
            if method == "notifications/progress" {
                guard subscription == nil, let token = WireIdentity(params?["progressToken"]) else { return }
                directKey = nil; progress = token
            } else {
                guard let key = WireIdentity(subscription) else { return }
                if method == "notifications/cancelled" {
                    guard WireIdentity(params?["requestId"]) == key else { return }
                }
                directKey = key; progress = nil
            }
        }
        state.withLock { state in
            let key = directKey ?? state.routes.first { progress != nil && $0.value.progressToken == progress }?.key
            guard let key, var route = state.routes[key], !route.stopped, !route.terminalReceived else { return }
            // Subscription notifications belong only to a listen request.
            // A matching cancellation remains a notification; the subsequent
            // terminal response (or EOF) decides the exchange outcome.
            if !terminal, directKey != nil, !route.isListen { return }
            // Terminal receipt ends wire ownership, even if the local receiver
            // is suspended or the terminal frame exceeds inbox capacity.
            if terminal {
                route.terminalReceived = true
                // Preserve raw delivery for higher-level response validation,
                // but a malformed envelope is not proof of reusable identity.
                route.identitiesReusable = Self.provesTerminal(object, key: key, isListen: route.isListen)
            }
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

    // A structural JSON-RPC terminal, not method-specific schema validation.
    // A successful listen also has to identify the exact subscription.
    // Never release a reservation because of a late frame on a retired route.
    private static func provesTerminal(_ object: JSONObject, key: WireIdentity, isListen: Bool) -> Bool {
        guard object["jsonrpc"]?.stringValue == "2.0", object["method"] == nil,
              WireIdentity(object["id"]) == key else { return false }
        if let result = object["result"] {
            guard object["error"] == nil, let value = result.objectValue else { return false }
            if isListen {
                return WireIdentity(value["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"]) == key
            }
            return true
        }
        guard let error = object["error"]?.objectValue,
              error["code"]?.numberValue?.isInteger == true,
              error["message"]?.stringValue != nil else { return false }
        return true
    }

    private static func stop(_ route: inout Route, outgoing: AsyncStream<[UInt8]>.Continuation?) {
        guard !route.stopped else { return }
        route.stopped = true
        if !route.terminalReceived { outgoing?.yield(route.cancellationLine) }
        route.inbox.finish()
    }

    private func stopExchange(_ key: WireIdentity, identity: UUID) {
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
                state.resetReservationsIfIdle()
            }
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
