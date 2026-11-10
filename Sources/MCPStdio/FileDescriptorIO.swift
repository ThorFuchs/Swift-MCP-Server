// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import SystemPackage


// Internal deterministic source-test seam. Public init always uses .none.
struct StdioLifecycleProbe: Sendable {
    let checkpoint: @Sendable (String) throws -> Void
    let observe: @Sendable (String) -> Void
    static let none = Self(checkpoint: { _ in }, observe: { _ in })
}

/// A bounded cleanup observation. A failed close is never retried.
public struct StdioLifecycleIssue: Sendable {
    public let stage: String
    public let code: Int32?
}

/// Operation failure and cleanup observations remain separate. A nil operation
/// means ordinary execution completed but cleanup reported a failure.
public struct StdioLifecycleFailure: Error, Sendable {
    public let operation: (any Error)?
    public let cleanup: [StdioLifecycleIssue]
}

/// A fixed worker thread with one pending operation, retained by the endpoint.
/// The callback captures storage, never its Thread/endpoint. Stop drains its one
/// cancelled operation, exits the thread, then resumes the sole owned joiner.
private final class IOThread: Sendable {
    private final class Storage: Sendable {
        struct State {
            var pending: (@Sendable () -> Void)?
            var started = false, stopped = false, exited = false
            var joiner: CheckedContinuation<Void,any Error>?
        }
        let condition = NSCondition()
        let state = Mutex(State())
        func loop() {
            while true {
                condition.lock()
                while state.withLock({ $0.pending == nil && !$0.stopped }) { condition.wait() }
                let action = state.withLock { value -> (@Sendable () -> Void)? in
                    let action = value.pending; value.pending = nil; return action
                }
                let stopped = state.withLock { $0.stopped }
                condition.unlock()
                if let action { action() }
                else if stopped { break }
            }
            let joiner = state.withLock { value in
                value.exited = true; let waiter = value.joiner; value.joiner = nil; return waiter
            }
            joiner?.resume()
        }
    }
    private let storage = Storage()
    // Foundation Thread is deliberately non-Sendable. Its creation/start and
    // owning reference stay inside this mutex; no Thread value escapes.
    private let thread = Mutex<Thread?>(nil)
    private let name: String
    init(name: String) { self.name = name }
    func start() -> Bool {
        storage.condition.lock(); defer { storage.condition.unlock() }
        let allowed = storage.state.withLock { value in
            guard !value.stopped else { return false }
            if value.started { return false }
            value.started = true; return true
        }
        guard allowed else { return false }
        let storage = self.storage
        thread.withLock { value in
            let worker = Thread { storage.loop() }; worker.name = name
            value = worker; worker.start()
        }
        return true
    }
    func submit(_ action: @escaping @Sendable () -> Void) -> Bool {
        storage.condition.lock(); defer { storage.condition.unlock() }
        let accepted = storage.state.withLock { value in
            guard !value.stopped, value.pending == nil else { return false }
            value.pending = action; return true
        }
        if accepted { storage.condition.signal() }; return accepted
    }
    func stop() {
        storage.condition.lock()
        storage.state.withLock { value in
            value.stopped = true
            if !value.started { value.exited = true }
        }
        storage.condition.broadcast(); storage.condition.unlock()
    }
    func join() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,any Error>) in
            storage.state.withLock { value in
                if value.exited { continuation.resume() }
                else if !value.started { continuation.resume(throwing:StdioFailure.ioBusy) }
                else if value.joiner != nil { continuation.resume(throwing:StdioFailure.ioBusy) }
                else { value.joiner = continuation }
            }
        }
    }
    deinit { stop() }
}

/// One owned operation per endpoint on a fixed worker thread.
/// FileDescriptor is not Sendable: owned raw handles cross this boundary.
/// Mutex protects cancellation/close/busy and wake-pipe use; nonblocking syscalls
/// plus poll/private wake pipe never block Swift cooperative executor threads.
private final class IOCancellation: Sendable {
    let flag = Mutex(false)
    var cancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}
final class FileDescriptorIO: Sendable {
    private struct State { var busy = false, started = false, stopped = false, releaseAttempted = false; var worker: UInt = 0; var interruptions = 0; var issues: [StdioLifecycleIssue] = [] }
    private let state = Mutex(State())
    private let descriptor: Int32, wakeRead: Int32, wakeWrite: Int32
    private let queue: IOThread
    private let writing: Bool

    private let probe: StdioLifecycleProbe
    private var label: String { writing ? "output" : "input" }
    // Preserve the existing internal direct-IO consumers' eager behavior.
    // StdioTransport ALWAYS selects false; no public constructor activates IO.
    init(raw: Int32, writing: Bool, activateImmediately: Bool = true,
        probe: StdioLifecycleProbe = .none) throws {
        try probe.checkpoint(writing ? "prepare.output.wake" : "prepare.input.wake")
        let wake = try FileDescriptor.pipe(options: [.nonBlocking, .closeOnExec])
        descriptor = raw; wakeRead = wake.readEnd.rawValue; wakeWrite = wake.writeEnd.rawValue
        self.writing = writing; self.probe = probe
        queue = IOThread(name: writing ? "org.swift-mcp.stdio.write" : "org.swift-mcp.stdio.read")
        if activateImmediately { try activate() }
    }
    func activate() throws {
        let didStart = try state.withLock { value in
            guard !value.stopped else { throw StdioFailure.closed }
            guard !value.started else { return false }
            try probe.checkpoint("activate." + label)
            guard queue.start() else { throw StdioFailure.closed }
            value.started = true; return true
        }
        if didStart { probe.observe("activated." + label) }
    }
    var cleanupIssues: [StdioLifecycleIssue] { state.withLock { $0.issues } }

    deinit { stop() }
    // Internal ownership diagnostics for native boundary qualification. Raw
    // pthread identity is valid only while the awaited operation owns this worker.
    var workerIdentity: UInt { state.withLock { $0.worker } }
    var interruptions: Int { state.withLock { $0.interruptions } }
    private func interrupted() { state.withLock { if $0.interruptions < Int.max { $0.interruptions += 1 } } }
    static func validate(_ raw: Int32, writing: Bool, ownership: DescriptorOwnership) throws {
        let flags = fcntl(raw, F_GETFL)
        guard flags >= 0 else { throw StdioFailure.invalidDescriptor }
        guard writing ? flags & O_ACCMODE != O_RDONLY : flags & O_ACCMODE != O_WRONLY else { throw StdioFailure.invalidDescriptor }
        var info = stat()
        guard fstat(raw, &info) == 0 else { throw StdioFailure.system(errno) }
        guard info.st_mode & S_IFMT == S_IFIFO || info.st_mode & S_IFMT == S_IFSOCK else { throw StdioFailure.unsupportedDescriptor }
        if info.st_mode & S_IFMT == S_IFSOCK {
            var kind: Int32 = 0, count = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(raw,SOL_SOCKET,SO_TYPE,&kind,&count) == 0, kind == SOCK_STREAM else { throw StdioFailure.unsupportedDescriptor }
            // SO_LINGER can make close block despite O_NONBLOCK. Never move
            // that host-configured blocking close onto a cooperative executor.
            var option = linger(), size = socklen_t(MemoryLayout<linger>.size)
            guard getsockopt(raw,SOL_SOCKET,SO_LINGER,&option,&size) == 0,
                option.l_onoff == 0 || option.l_linger == 0 else { throw StdioFailure.unsupportedDescriptor }
        }
        if ownership == .borrowed, flags & O_NONBLOCK == 0 { throw StdioFailure.borrowedDescriptorMustBeNonblocking }
        if writing, ownership == .borrowed, fcntl(raw,F_GETNOSIGPIPE) != 1 { throw StdioFailure.borrowedDescriptorMustSuppressSIGPIPE }
    }
    static func duplicate(_ raw: Int32) throws -> Int32 {
        let copy = fcntl(raw, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw StdioFailure.system(errno) }; return copy
    }
    static func nonblocking(_ raw: Int32) throws {
        let flags = fcntl(raw, F_GETFL)
        guard flags >= 0, fcntl(raw, F_SETFL, flags | O_NONBLOCK) == 0 else { throw StdioFailure.system(errno) }
    }
    func stop() {
        state.withLock { value in
            value.stopped = true
            if value.busy { signal() } else { release(&value) }
        }
        queue.stop()
    }
    func join() async throws {
        try await queue.join()
        probe.observe("joined." + label)
        try probe.checkpoint("join." + label)
    }
    private func release(_ value: inout State) {
        guard !value.releaseAttempted else { return }; value.releaseAttempted = true
        // Never retry close after EINTR; the descriptor number may be reused.
        for (raw, part) in [(descriptor,"descriptor"),(wakeRead,"wakeRead"),(wakeWrite,"wakeWrite")] {
            do {
                try FileDescriptor(rawValue: raw).close()
                probe.observe("closed." + label + "." + part)
            } catch {
                if value.issues.count < 3 {
                    value.issues.append(.init(stage:"close." + label + "." + part,code:(error as? Errno)?.rawValue))
                }
            }
        }
    }
    private func signal() {
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { try? FileDescriptor(rawValue: wakeWrite).write($0, retryOnInterrupt: false) }
        // A full nonblocking wake pipe is already readable.
    }
    private func wake() { state.withLock { value in if !value.releaseAttempted { signal() } } }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable (IOCancellation) throws -> T) async throws -> T {
        let cancelled = IOCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try state.withLock { value in
                        guard value.started && !value.stopped else { throw StdioFailure.closed }
                        guard !value.busy else { throw StdioFailure.ioBusy }; value.busy = true
                    }
                    let accepted = queue.submit { [self] in
                        state.withLock { $0.worker = UInt(bitPattern:pthread_self()) }
                        let result: Result<T, any Error>
                        do { result = .success(try operation(cancelled)) } catch { result = .failure(error) }
                        state.withLock { value in value.busy = false; value.worker = 0; if value.stopped { release(&value) } }
                        continuation.resume(with: result)
                    }
                    if !accepted {
                        state.withLock { value in value.busy = false; if value.stopped { release(&value) } }
                        continuation.resume(throwing:StdioFailure.closed)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { cancelled.cancel(); self.wake() }
    }
    private func check(_ cancellation: IOCancellation) throws {
        if cancellation.cancelled { throw CancellationError() }
        if state.withLock({ $0.stopped }) { throw StdioFailure.closed }
    }
    private func ready(deadline: ContinuousClock.Instant, cancellation: IOCancellation) throws {
        while true {
            try check(cancellation)
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { throw writing ? StdioFailure.writeDeadline : StdioFailure.readDeadline }
            let c = left.components
            let milliseconds = min(Int64(1000), max(1, c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000))
            var descriptors = [pollfd(fd: descriptor, events: Int16(writing ? POLLOUT : POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let n = poll(&descriptors, 2, Int32(milliseconds))
            if n < 0 { if errno == EINTR { interrupted(); continue }; throw StdioFailure.system(errno) }
            if n == 0 { continue }
            if descriptors[1].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                while ((try? bytes.withUnsafeMutableBytes { try FileDescriptor(rawValue: wakeRead).read(into: $0, retryOnInterrupt: false) }) ?? 0) > 0 {}
                try check(cancellation)
            }
            if descriptors[0].revents & Int16(POLLNVAL) != 0 { throw StdioFailure.invalidDescriptor }
            if descriptors[0].revents & Int16(POLLIN | POLLOUT | POLLHUP | POLLERR) != 0 { return }
        }
    }
    func read(maximum: Int, deadline: ContinuousClock.Instant) async throws -> [UInt8] {
        try await perform { [self] cancellation in
            var bytes = [UInt8](repeating: 0, count: maximum)
            while true {
                try ready(deadline: deadline, cancellation: cancellation)
                do {
                    let n = try bytes.withUnsafeMutableBytes { try FileDescriptor(rawValue: descriptor).read(into: $0, retryOnInterrupt: false) }
                    bytes.removeLast(bytes.count - n); return bytes
                } catch let error as Errno where error == .interrupted || error == .wouldBlock { if error == .interrupted { interrupted() }; continue }
            }
        }
    }
    func write(_ bytes: [UInt8], idleMilliseconds: Int64) async throws {
        try await perform { [self] cancellation in
            // F_SETNOSIGPIPE/SO_NOSIGPIPE is configured by the exclusive owner,
            // never through a process signal handler. Its open-file/socket flag
            // is shared by duplicates, so borrowed outputs must already set it.
            guard fcntl(descriptor,F_GETNOSIGPIPE) == 1 else { throw StdioFailure.invalidDescriptor }
            var offset = 0
            var deadline = ContinuousClock.now.advanced(by: .milliseconds(idleMilliseconds))
            do {
                while offset < bytes.count {
                    try ready(deadline: deadline, cancellation: cancellation)
                    do {
                        let count = try bytes.withUnsafeBytes { buffer in
                            try FileDescriptor(rawValue: descriptor).write(UnsafeRawBufferPointer(rebasing: buffer[offset..<min(bytes.count,offset+65_536)]), retryOnInterrupt: false)
                        }
                        guard count > 0 else { throw StdioFailure.brokenPipe }
                        offset += count; deadline = ContinuousClock.now.advanced(by: .milliseconds(idleMilliseconds))
                    } catch let error as Errno where error == .interrupted || error == .wouldBlock { if error == .interrupted { interrupted() }; continue }
                    catch let error as Errno where error == .brokenPipe { throw StdioFailure.brokenPipe }
                }
            } catch {
                // No following frame can safely repair a partial frame.
                if offset > 0 { stop(); throw StdioFailure.partialWrite }
                throw error
            }
        }
    }
}
