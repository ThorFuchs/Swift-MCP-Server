// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import SystemPackage
import MCPProtocol
import MCPServer

private final class IngressCancellation: Sendable {
    private let value = Mutex(false)
    var cancelled: Bool { value.withLock { $0 } }
    func cancel() { value.withLock { $0 = true } }
}
private struct IngressFrame: Sendable {
    let ticket = UUID()
    let admission: AdmittedIngress
    var correlation: RequestCorrelation? { admission.correlation }
    let cancellation = IngressCancellation()
}
private actor StdioInbox {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<IngressFrame?, any Error> }
    private var queue: [IngressFrame] = [], waiters: [Waiter] = []
    private var active: [UUID:IngressFrame] = [:]
    private var bytes = 0, finished = false
    private let policy: StdioPolicy
    private(set) var peakBytes = 0, peakFrames = 0
    init(_ policy: StdioPolicy) { self.policy = policy }
    func put(_ admission: AdmittedIngress) throws {
        guard !finished else { throw StdioFailure.closed }
        if !waiters.isEmpty {
            let entry = IngressFrame(admission:admission); active[entry.ticket] = entry
            waiters.removeFirst().continuation.resume(returning:entry); return
        }
        guard queue.count < policy.queuedFrames, admission.retainedBytes <= policy.queuedBytes - bytes else { throw StdioFailure.ingressOverflow }
        bytes += admission.retainedBytes; queue.append(.init(admission:admission))
        peakBytes = max(peakBytes,bytes); peakFrames = max(peakFrames,queue.count)
    }
    func next() async throws -> IngressFrame? {
        try Task.checkCancellation()
        if !queue.isEmpty {
            let entry = queue.removeFirst(); bytes -= entry.admission.retainedBytes
            active[entry.ticket] = entry; return entry
        }
        if finished { return nil }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(.init(id:id,continuation:continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    func complete(_ entry: IngressFrame) { active.removeValue(forKey:entry.ticket) }
    func cancel(_ identity: RequestCorrelation) async {
        // No unknown-ID memoization and no future/reused-ID cancellation.
        for entry in active.values where entry.correlation == identity { entry.cancellation.cancel() }
        let removed = queue.filter { $0.correlation == identity }
        queue.removeAll { $0.correlation == identity }
        for entry in removed { bytes -= entry.admission.retainedBytes; await entry.admission.discard() }
    }
    func finish(discard: Bool = false) async {
        finished = true
        if discard {
            let pending = queue; queue.removeAll(); bytes = 0
            for entry in active.values { entry.cancellation.cancel() }
            for entry in pending { await entry.admission.discard() }
        }
        for waiter in waiters { waiter.continuation.resume(returning:nil) }; waiters.removeAll()
    }
    private func cancelWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) { waiters.remove(at:i).continuation.resume(throwing:CancellationError()) }
    }
}

private final class StdioOutput: Sendable {
    private struct State {
        var tickets: [UUID:Int] = [:], bytes = 0, peakBytes = 0, peakFrames = 0
        var failed = false, delivered = 0
    }
    private let state = Mutex(State())
    private let io: FileDescriptorIO
    private let serial: AdmissionController
    private let policy: StdioPolicy
    init(io: FileDescriptorIO, policy: StdioPolicy) throws {
        self.io = io; self.policy = policy
        serial = try AdmissionController(activeLimit:1,queueLimit:policy.writerFrames)
    }
    var failed: Bool { state.withLock { $0.failed } }
    var statistics: (Int,Int,Int,Int) { state.withLock { ($0.bytes,$0.peakBytes,$0.peakFrames,$0.delivered) } }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= policy.outputFrameBytes,
            !data.contains(10), !data.contains(13) else { throw StdioFailure.invalidOutputFrame }
        let id = UUID()
        try state.withLock { value in
            guard !value.failed else { throw StdioFailure.closed }
            guard value.tickets.count < policy.writerFrames, data.count + 1 <= policy.writerBytes - value.bytes else { value.failed = true; throw StdioFailure.outputOverflow }
            value.tickets[id] = data.count + 1; value.bytes += data.count + 1
            value.peakBytes = max(value.peakBytes,value.bytes); value.peakFrames = max(value.peakFrames,value.tickets.count)
        }
        defer { state.withLock { value in if let count = value.tickets.removeValue(forKey:id) { value.bytes -= count } } }
        let permit = try await serial.acquire()
        do {
            try Task.checkCancellation()
            var frame = Array(data); frame.append(10)
            try await io.write(frame,idleMilliseconds:policy.writeIdleMilliseconds)
            state.withLock { if $0.delivered < Int.max { $0.delivered += 1 } }
        } catch {
            try await serial.release(permit)
            if !(error is CancellationError) {
                state.withLock { $0.failed = true }; io.stop(); await serial.stop()
            }
            throw error
        }
        try await serial.release(permit)
    }
}

private actor StdioDrain {
    private var draining = false, workers: Int
    private var waiter: CheckedContinuation<Void, any Error>?
    init(workers: Int) { self.workers = workers }
    func begin() { draining = true; waiter?.resume(); waiter = nil }
    func completed() { workers -= 1 }
    var remaining: Int { workers }
    func wait() async throws {
        try Task.checkCancellation()
        if draining { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing:CancellationError()) } else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    private func cancel() { waiter?.resume(throwing:CancellationError()); waiter = nil }
}

/// Single-use stdio connection. Host supplies verified authority/origin and owns
/// the run task. No signals, credentials, logging bootstrap or subprocess launch.
/// Supports pipes and stream sockets; stdout bytes are production MCP frames only.
public final class StdioTransport: Sendable {
    public enum Phase: String, Sendable { case ready, running, draining, stopped }
    public struct Statistics: Sendable {
        public let phase: Phase
        public let queuedBytesPeak: Int, queuedFramesPeak: Int
        public let writerBytes: Int, writerBytesPeak: Int, writerFramesPeak: Int, deliveredFrames: Int
    }
    private struct State: Sendable { var phase = Phase.ready; var shutdown = false; var inputBytes = 0, inputFrames = 0 }
    private let state = Mutex(State())
    private let input: FileDescriptorIO, output: FileDescriptorIO
    private let writer: StdioOutput
    public let policy: StdioPolicy
    private let preparationIssues: [StdioLifecycleIssue]

    public convenience init(input: FileDescriptor, output: FileDescriptor,
        inputOwnership: DescriptorOwnership = .borrowed, outputOwnership: DescriptorOwnership = .borrowed,
        policy: StdioPolicy? = nil) throws {
        try self.init(input:input,output:output,inputOwnership:inputOwnership,
            outputOwnership:outputOwnership,policy:policy,lifecycle:.none)
    }
    // Internal test injection only; the public construction contract is unchanged.
    init(input: FileDescriptor, output: FileDescriptor,
        inputOwnership: DescriptorOwnership, outputOwnership: DescriptorOwnership,
        policy: StdioPolicy?, lifecycle: StdioLifecycleProbe) throws {
        let policy = try policy ?? StdioPolicy()
        guard input.rawValue != output.rawValue else { throw StdioFailure.invalidDescriptor }
        try FileDescriptorIO.validate(input.rawValue,writing:false,ownership:inputOwnership)
        try FileDescriptorIO.validate(output.rawValue,writing:true,ownership:outputOwnership)
        try lifecycle.checkpoint("validated")
        let originalInputFlags = fcntl(input.rawValue,F_GETFL), originalOutputFlags = fcntl(output.rawValue,F_GETFL)
        let originalNoSigPipe = noSigPipeFlag(output.rawValue)
        guard originalInputFlags >= 0, originalOutputFlags >= 0, originalNoSigPipe >= 0 else { throw StdioFailure.system(errno) }
        let readCopy = try FileDescriptorIO.duplicate(input.rawValue)
        let readIO: FileDescriptorIO
        do { readIO = try FileDescriptorIO(raw:readCopy,writing:false,activateImmediately:false,probe:lifecycle) }
        catch { throw Self.closePreparedCopy(readCopy,primary:error,stage:"prepare.input",probe:lifecycle) }
        let writeIO: FileDescriptorIO
        do {
            try lifecycle.checkpoint("prepared.input")
            let copy = try FileDescriptorIO.duplicate(output.rawValue)
            do { writeIO = try FileDescriptorIO(raw:copy,writing:true,activateImmediately:false,probe:lifecycle) }
            catch { throw Self.closePreparedCopy(copy,primary:error,stage:"prepare.output",probe:lifecycle) }
        } catch {
            readIO.stop()
            throw Self.failure(error,cleanup:readIO.cleanupIssues)
        }
        var inputFlagsTouched = false, outputFlagsTouched = false, noSigPipeTouched = false
        let preparedWriter: StdioOutput
        do {
            try lifecycle.checkpoint("prepared.output")
            if inputOwnership == .owned {
                inputFlagsTouched = true; try FileDescriptorIO.nonblocking(input.rawValue)
            }
            if outputOwnership == .owned {
                outputFlagsTouched = true; try FileDescriptorIO.nonblocking(output.rawValue)
                noSigPipeTouched = true
                guard setNoSigPipeFlag(output.rawValue,1) == 0 else { throw StdioFailure.system(errno) }
            }
            try lifecycle.checkpoint("flags.applied")
            preparedWriter = try StdioOutput(io:writeIO,policy:policy)
            try lifecycle.checkpoint("before.transfer")
        } catch {
            var cleanup: [StdioLifecycleIssue] = []
            if inputFlagsTouched, fcntl(input.rawValue,F_SETFL,originalInputFlags) != 0 { cleanup.append(.init(stage:"restore.input.flags",code:errno)) }
            if outputFlagsTouched, fcntl(output.rawValue,F_SETFL,originalOutputFlags) != 0 { cleanup.append(.init(stage:"restore.output.flags",code:errno)) }
            if noSigPipeTouched, setNoSigPipeFlag(output.rawValue,originalNoSigPipe) != 0 { cleanup.append(.init(stage:"restore.output.nosigpipe",code:errno)) }
            readIO.stop(); writeIO.stop()
            cleanup += readIO.cleanupIssues; cleanup += writeIO.cleanupIssues
            throw Self.failure(error,cleanup:cleanup)
        }
        // Commit: no further throwing setup. Each transferred original is closed
        // once; an ambiguous close is retained, never retried or handed back.
        var committedIssues: [StdioLifecycleIssue] = []
        for (fd, ownership, label) in [(input,inputOwnership,"input"),(output,outputOwnership,"output")] where ownership == .owned {
            do { try fd.close(); lifecycle.observe("transferred." + label) }
            catch { committedIssues.append(.init(stage:"transfer.close." + label,code:(error as? Errno)?.rawValue)) }
        }
        self.input = readIO; self.output = writeIO; self.writer = preparedWriter
        self.policy = policy; self.preparationIssues = committedIssues
    }
    private static func closePreparedCopy(_ raw: Int32, primary: any Error, stage: String, probe: StdioLifecycleProbe) -> any Error {
        do { try FileDescriptor(rawValue:raw).close(); probe.observe("closed." + stage + ".copy"); return primary }
        catch { return failure(primary,cleanup:[.init(stage:stage,code:(error as? Errno)?.rawValue)]) }
    }
    private static func failure(_ operation: any Error, cleanup: [StdioLifecycleIssue]) -> any Error {
        guard !cleanup.isEmpty else { return operation }
        // Keep an already wrapped primary and its earlier ordered cleanup records.
        if let prior = operation as? StdioLifecycleFailure {
            return StdioLifecycleFailure(operation:prior.operation,cleanup:Array((prior.cleanup + cleanup).prefix(16)))
        }
        return StdioLifecycleFailure(operation:operation,cleanup:Array(cleanup.prefix(16)))
    }
    private func settleEndpoints() async -> [StdioLifecycleIssue] {
        input.stop(); output.stop()
        var cleanup = preparationIssues
        do { try await input.join() }
        catch { cleanup.append(.init(stage:"join.input",code:(error as? Errno)?.rawValue)) }
        do { try await output.join() }
        catch { cleanup.append(.init(stage:"join.output",code:(error as? Errno)?.rawValue)) }
        cleanup += input.cleanupIssues; cleanup += output.cleanupIssues
        return Array(cleanup.prefix(16))
    }
    deinit { input.stop(); output.stop() }
    /// Stop new input, drain already accepted requests/streams until deadline.
    /// Safe before run and idempotent. Cancelling run instead aborts both directions.
    public func shutdown() {
        let dormant = state.withLock { value in value.shutdown = true; return value.phase == .ready }
        input.stop()
        if dormant { output.stop() }
    }
    public var statistics: Statistics {
        let s = state.withLock { $0 }; let w = writer.statistics
        return .init(phase:s.phase,queuedBytesPeak:s.inputBytes,queuedFramesPeak:s.inputFrames,
            writerBytes:w.0,writerBytesPeak:w.1,writerFramesPeak:w.2,deliveredFrames:w.3)
    }
    public func run(server: Server, principal: VerifiedPrincipal, origin: ScalarText) async throws {
        try state.withLock { value in
            guard value.phase == .ready else { throw StdioFailure.alreadyRunning }; value.phase = .running
        }
        let inbox = StdioInbox(policy), drain = StdioDrain(workers:policy.workers)
        defer { input.stop(); output.stop(); state.withLock { $0.phase = .stopped } }
        do {
        try await withTaskCancellationHandler {
            let activated = try state.withLock { value in
                try Task.checkCancellation()
                guard !value.shutdown else { return false }
                try input.activate()
                try Task.checkCancellation()
                try output.activate()
                return true
            }
            guard activated else { return }
            try await withThrowingTaskGroup(of:Void.self) { group in
                group.addTask { [self] in
                    var framer = try LineFramer(maximumFrameBytes:policy.frameBytes,maximumChunkBytes:policy.chunkBytes)
                    var frameStart: ContinuousClock.Instant?
                    do {
                        while true {
                            let idle = ContinuousClock.now.advanced(by:.milliseconds(policy.readIdleMilliseconds))
                            let frameEnd = frameStart?.advanced(by:.milliseconds(policy.frameMilliseconds)) ?? idle
                            let chunk: [UInt8]
                            do { chunk = try await input.read(maximum:policy.chunkBytes,deadline:min(idle,frameEnd)) }
                            catch StdioFailure.closed where state.withLock({ $0.shutdown }) { break }
                            if chunk.isEmpty { try framer.finish(); break }
                            let frames = try framer.append(chunk)
                            frameStart = framer.bufferedBytes == 0 ? nil : (frames.isEmpty ? frameStart ?? ContinuousClock.now : ContinuousClock.now)
                            for frame in frames {
                                let data = Data(frame)
                                switch try await server.inspectIngress(data,principal:principal,origin:origin) {
                                case .notification(let identity):
                                    if let identity { await inbox.cancel(identity) }
                                case .request(let admission):
                                    do { try await inbox.put(admission) }
                                    catch { await admission.discard(); throw error }
                                }
                            }
                        }
                        await inbox.finish(); state.withLock { $0.phase = .draining }; await drain.begin()
                    } catch { await inbox.finish(discard:true); throw error }
                }
                for _ in 0..<policy.workers {
                    group.addTask { [self] in
                        while let frame = try await inbox.next() {
                            do {
                                if frame.cancellation.cancelled || ContinuousClock.now >= frame.admission.deadline {
                                    await frame.admission.discard(); await inbox.complete(frame); continue
                                }
                                try await withThrowingTaskGroup(of:Void.self) { request in
                                    request.addTask { [writer] in
                                        try await server.dispatchEvents(frame.admission,mode:.stdio) { data in try await writer.send(data) }
                                    }
                                    request.addTask {
                                        // Finite connection-owned cancellation observer. It has
                                        // no access to/replenishment of the main/terminal account.
                                        var left = server.configuration.deadlineMilliseconds / 5 + 2
                                        while left > 0 {
                                            if frame.cancellation.cancelled { throw CancellationError() }
                                            try await Task.sleep(for:.milliseconds(5)); left -= 1
                                        }
                                        throw CoreFailure.deadline
                                    }
                                    defer { request.cancelAll() }
                                    _ = try await request.next()
                                }
                            } catch is CancellationError { /* authoritative client cancellation: silent */ }
                            catch CoreFailure.deadline { /* core terminal owner suppresses expired work */ }
                            catch { await inbox.complete(frame); throw error }
                            await inbox.complete(frame)
                            if writer.failed { throw StdioFailure.closed }
                        }
                        await drain.completed()
                    }
                }
                group.addTask { [self] in
                    try await drain.wait()
                    let end = ContinuousClock.now.advanced(by:.milliseconds(policy.drainMilliseconds))
                    while await drain.remaining > 0 {
                        guard ContinuousClock.now < end else { throw StdioFailure.drainDeadline }
                        // Also closes listens accepted just before EOF but not yet registered.
                        await server.closeSubscriptions(for:principal,origin:origin)
                        try await Task.sleep(for:.milliseconds(10))
                    }
                }
                do { while try await group.next() != nil {} }
                catch {
                    group.cancelAll(); input.stop(); output.stop(); await inbox.finish(discard:true)
                    throw error
                }
            }
        } onCancel: { self.input.stop(); self.output.stop() }
        } catch {
            let cleanup = await settleEndpoints()
            let peaks = await (inbox.peakBytes,inbox.peakFrames)
            state.withLock { $0.inputBytes = peaks.0; $0.inputFrames = peaks.1 }
            throw Self.failure(error,cleanup:cleanup)
        }
        let cleanup = await settleEndpoints()
        let peaks = await (inbox.peakBytes,inbox.peakFrames)
        state.withLock { $0.inputBytes = peaks.0; $0.inputFrames = peaks.1 }
        if !cleanup.isEmpty { throw StdioLifecycleFailure(operation:nil,cleanup:cleanup) }
    }
}

// Darwin's per-open-file SIGPIPE suppression. Linux has no such flag (see
// blockSIGPIPEOnCurrentThread); reads report 0 and writes succeed without effect.
private func noSigPipeFlag(_ raw: Int32) -> Int32 {
    #if canImport(Darwin)
    return fcntl(raw, F_GETNOSIGPIPE)
    #else
    return 0
    #endif
}
private func setNoSigPipeFlag(_ raw: Int32, _ value: Int32) -> Int32 {
    #if canImport(Darwin)
    return fcntl(raw, F_SETNOSIGPIPE, value)
    #else
    return 0
    #endif
}
