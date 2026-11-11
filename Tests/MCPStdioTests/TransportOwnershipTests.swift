// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
import JSON
import MCPProtocol
@testable import MCPServer
import SystemPackage
import Synchronization
@testable import MCPStdio

private func ownershipServer() async throws -> Server {
    let info = try JSONParser().parseWithReport(Array(#"{"name":"ownership","version":"1"}"#.utf8)).result
    let cursor = try CursorProtector(keys:[.init(identifier:ScalarText("k"),material:Data(repeating:1,count:32))],active:ScalarText("k"),clock:{1000})
    return try await Server.make(info:info,catalog:ServerCatalog(),cursors:cursor)
}
private let ownershipPrincipal = VerifiedPrincipal(subject:ScalarText("test"),issuer:ScalarText("host"),resource:ScalarText("stdio"),scopes:[])
private func openFDCount() throws -> Int { try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count }
private func awaitWorker(_ io: FileDescriptorIO) async throws -> UInt {
    let end = ContinuousClock.now.advanced(by:.seconds(5))
    while io.workerIdentity == 0 {
        guard ContinuousClock.now < end else { throw StdioFailure.readDeadline }; await Task.yield()
    }
    return io.workerIdentity
}

@Suite(.serialized) struct StdioOwnership {
    @Test func nonblockingReadCancellationWakesAndJoins() async throws {
        let p = try testPipe()
        defer { try? p.writeEnd.close() }
        #expect(setNoSigPipe(p.writeEnd.rawValue) == 0)
        let io = try FileDescriptorIO(raw:p.readEnd.rawValue,writing:false)
        let task = Task { try await io.read(maximum:7,deadline:ContinuousClock.now.advanced(by:.seconds(30))) }
        _ = try await awaitWorker(io)
        task.cancel()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(io.workerIdentity == 0)
        io.stop()
        try await io.join()
        // A closed integer can already identify a different descriptor in a
        // parallel test. EPIPE on this still-owned pipe description proves its
        // reader closed; it also verifies the fixed worker actually joined.
        // As in the lifecycle EOF observation tests, macOS can make the peer close
        // visible slightly after the close syscall under heavy parallel load, so
        // EPIPE is awaited under a separate 100 ms kernel observation bound. A
        // successful write only means the close is not yet observable; any other
        // error, or no EPIPE within the bound, fails.
        var byte: UInt8 = 1
        let observation = ContinuousClock.now.advanced(by:.milliseconds(100))
        var observedBrokenPipe = false
        while !observedBrokenPipe && ContinuousClock.now < observation {
            do {
                _ = try withUnsafeBytes(of:&byte) { try p.writeEnd.write($0,retryOnInterrupt:false) }
                try await Task.sleep(for:.milliseconds(1))
            } catch Errno.brokenPipe {
                observedBrokenPipe = true
            }
        }
        #expect(observedBrokenPipe)
    }
    @Test func interruptedPollRetriesWithoutLosingBytes() async throws {
        let p = try testPipe()
        defer { try? p.writeEnd.close() }
        // Create the owned worker with the test host's explicitly unblocked
        // signal mask, restoring the creator's mask synchronously before await.
        var mask = sigset_t(), previous = sigset_t()
        sigemptyset(&mask); sigaddset(&mask,SIGUSR1)
        #expect(pthread_sigmask(SIG_UNBLOCK,&mask,&previous) == 0)
        let io: FileDescriptorIO
        do { io = try FileDescriptorIO(raw:p.readEnd.rawValue,writing:false) }
        catch { _ = pthread_sigmask(SIG_SETMASK,&previous,nil); throw error }
        #expect(pthread_sigmask(SIG_SETMASK,&previous,nil) == 0)
        // Test-host disposition only; SDK never installs process handlers.
        let restoreHandler = try installNoopSignalHandler(SIGUSR1)
        defer { restoreHandler(); io.stop() }
        let task = Task { try await io.read(maximum:3,deadline:ContinuousClock.now.advanced(by:.seconds(5))) }
        let thread = try await awaitWorker(io)
        for _ in 0..<100 where io.interruptions == 0 {
            // Native pthread identity is observed while this read owns its worker.
            #expect(pthread_kill(threadHandle(thread),SIGUSR1) == 0)
            try await Task.sleep(for:.milliseconds(1))
        }
        _ = try [UInt8](arrayLiteral:1,2,3).withUnsafeBytes { try p.writeEnd.write($0) }
        #expect(try await task.value == [1,2,3])
        #expect(io.interruptions > 0)
        #expect(io.workerIdentity == 0)
    }
    @Test func borrowedFlagsUnchangedOwnedDescriptorsClosedAndSingleUse() async throws {
        let server = try await ownershipServer()
        let incoming = try testPipe()
        let outgoing = try testPipe()
        defer {
            for fd in [incoming.readEnd,incoming.writeEnd,outgoing.readEnd,outgoing.writeEnd] { try? fd.close() }
        }
        #expect(setNoSigPipe(outgoing.writeEnd.rawValue) == 0)
        let noSigPipe = getNoSigPipe(outgoing.writeEnd.rawValue)
        let inputFlags = fcntl(incoming.readEnd.rawValue,F_GETFL), outputFlags = fcntl(outgoing.writeEnd.rawValue,F_GETFL)
        let transport = try StdioTransport(input:incoming.readEnd,output:outgoing.writeEnd)
        let task = Task { try await transport.run(server:server,principal:ownershipPrincipal,origin:ScalarText("borrowed")) }
        while transport.statistics.phase == .ready { await Task.yield() }
        transport.shutdown(); transport.shutdown()
        try await task.value
        #expect(transport.statistics.phase == .stopped)
        #expect(fcntl(incoming.readEnd.rawValue,F_GETFL) == inputFlags)
        #expect(fcntl(outgoing.writeEnd.rawValue,F_GETFL) == outputFlags)
        #expect(getNoSigPipe(outgoing.writeEnd.rawValue) == noSigPipe)
        await #expect(throws:StdioFailure.alreadyRunning) { try await transport.run(server:server,principal:ownershipPrincipal,origin:ScalarText("borrowed")) }
        let ownedInput = try FileDescriptor.pipe(), ownedOutput = try FileDescriptor.pipe()
        defer { try? ownedInput.writeEnd.close(); try? ownedOutput.readEnd.close() }
        let owned = try StdioTransport(input:ownedInput.readEnd,output:ownedOutput.writeEnd,inputOwnership:.owned,outputOwnership:.owned)
        #expect(fcntl(ownedInput.readEnd.rawValue,F_GETFD) == -1)
        #expect(fcntl(ownedOutput.writeEnd.rawValue,F_GETFD) == -1)
        owned.shutdown()
        try await owned.run(server:server,principal:ownershipPrincipal,origin:ScalarText("owned"))
        #expect(owned.statistics.writerBytes == 0)
        let a = await server.activity
        #expect(a.active == 0 && a.requests == 0 && a.bufferedBytes == 0)
    }
    @Test func parentCancellationAndRepeatedNeverStartedCleanup() async throws {
        let server = try await ownershipServer()
        // /dev/fd counts the whole test process, and other suites open descriptors in
        // parallel. A leak of even one descriptor per iteration adds at least `iterations`;
        // the tolerance only absorbs concurrent tests and stays far below that signal.
        let iterations = 512, tolerance = 64
        let before = try openFDCount()
        for _ in 0..<iterations {
            let p = try testPipe(), q = try testPipe()
            do {
                let t = try StdioTransport(input:p.readEnd,output:q.writeEnd,inputOwnership:.owned,outputOwnership:.owned)
                t.shutdown()
            }
            try p.writeEnd.close(); try q.readEnd.close()
        }
        let after = try openFDCount()
        #expect(after - before < tolerance, "\(after - before) descriptors more after \(iterations) never-started transports")
        let p = try testPipe(), q = try testPipe()
        defer { try? p.writeEnd.close(); try? q.readEnd.close() }
        let t = try StdioTransport(input:p.readEnd,output:q.writeEnd,inputOwnership:.owned,outputOwnership:.owned)
        let task = Task { try await t.run(server:server,principal:ownershipPrincipal,origin:ScalarText("cancel")) }
        while t.statistics.phase == .ready { await Task.yield() }
        task.cancel()
        await #expect(throws:(any Error).self) { try await task.value }
        #expect(t.statistics.phase == .stopped && t.statistics.writerBytes == 0)
    }
    @Test func constructorRejectionsLeaveHostDescriptorsIntact() throws {
        let p = try FileDescriptor.pipe(), q = try FileDescriptor.pipe()
        defer { for fd in [p.readEnd,p.writeEnd,q.readEnd,q.writeEnd] { try? fd.close() } }
        #expect(throws:StdioFailure.borrowedDescriptorMustBeNonblocking) { _ = try StdioTransport(input:p.readEnd,output:q.writeEnd) }
        #expect(fcntl(p.readEnd.rawValue,F_GETFD) >= 0 && fcntl(q.writeEnd.rawValue,F_GETFD) >= 0)
        #expect(throws:StdioFailure.invalidDescriptor) { _ = try StdioTransport(input:p.writeEnd,output:q.writeEnd,inputOwnership:.owned,outputOwnership:.owned) }
        #expect(throws:StdioFailure.invalidPolicy) { _ = try StdioPolicy(workers:0) }
        #expect(throws:StdioFailure.invalidPolicy) { _ = try StdioPolicy(writerBytes:Int.max) }
        #expect(throws:StdioFailure.invalidPolicy) { _ = try StdioPolicy(drainMilliseconds:Int64.max) }
        #expect(fcntl(p.readEnd.rawValue,F_GETFD) >= 0)
        #expect(fcntl(p.readEnd.rawValue,F_SETFL,O_NONBLOCK) == 0)
        #expect(fcntl(q.writeEnd.rawValue,F_SETFL,O_NONBLOCK) == 0)
        #if canImport(Darwin)
        // Only Darwin has the per-open-file SIGPIPE flag a borrowed output must carry.
        #expect(throws:StdioFailure.borrowedDescriptorMustSuppressSIGPIPE) { _ = try StdioTransport(input:p.readEnd,output:q.writeEnd) }
        #expect(getNoSigPipe(q.writeEnd.rawValue) == 0)
        #endif
        var sockets: [Int32] = [-1,-1]
        #expect(socketpair(AF_UNIX, testStreamSocketType, 0,&sockets) == 0)
        defer { for fd in sockets { _ = SystemCall.close(fd) } }
        var option = linger(l_onoff:1,l_linger:2)
        #expect(setsockopt(sockets[0],SOL_SOCKET,SO_LINGER,&option,socklen_t(MemoryLayout<linger>.size)) == 0)
        #expect(throws:StdioFailure.unsupportedDescriptor) { _ = try StdioTransport(input:.init(rawValue:sockets[0]),output:q.writeEnd,inputOwnership:.owned,outputOwnership:.owned) }
        #expect(fcntl(sockets[0],F_GETFD) >= 0)
        option.l_onoff = 0
        #expect(setsockopt(sockets[0],SOL_SOCKET,SO_LINGER,&option,socklen_t(MemoryLayout<linger>.size)) == 0)
    }
}

@Suite(.serialized) struct StdioIngressAccounts {
    @Test func admittedBudgetIsSharedAndForeignOrRepeatedDispatchCannotExecute() async throws {
        let server = try await ownershipServer(), foreign = try await ownershipServer()
        let input = Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
        guard case .request(let ingress) = try await server.inspectIngress(input,principal:ownershipPrincipal,origin:ScalarText("ticket")) else { Issue.record("request expected"); return }
        let before = await ingress.budget.snapshot
        #expect(before.settledWork > server.configuration.terminalWork && before.remaining < server.configuration.requestWork - server.configuration.terminalWork)
        #expect(ingress.retainedBytes >= ingress.byteCount && ingress.raw != nil)
        await #expect(throws:CoreFailure.invalidInput) { try await foreign.dispatchEvents(ingress,mode:.stdio) { _ in Issue.record("foreign write") } }
        let calls = Synchronization.Mutex(0)
        try await server.dispatchEvents(ingress,mode:.stdio) { _ in calls.withLock { $0 += 1 } }
        #expect(calls.withLock { $0 } == 1)
        let after = await ingress.budget.snapshot
        #expect(after.isTerminal && after.terminalTransitions == 1 && after.activeReservations == 0 && after.settledWork <= server.configuration.requestWork)
        await #expect(throws:CoreFailure.duplicate) { try await server.dispatchEvents(ingress,mode:.stdio) { _ in Issue.record("duplicate write") } }
        #expect(await ingress.discard() == false)
        guard case .request(let dropped) = try await server.inspectIngress(input,principal:ownershipPrincipal,origin:ScalarText("drop")) else { Issue.record("request expected"); return }
        #expect(await dropped.discard()); #expect(await dropped.discard() == false)
        #expect(await dropped.budget.snapshot.isTerminal)
        await #expect(throws:CoreFailure.duplicate) { try await server.dispatchEvents(dropped,mode:.stdio) { _ in Issue.record("discarded write") } }
    }
    @Test func nativeSocketHalfCloseDrainsOneModernResponse() async throws {
        let server = try await ownershipServer()
        var pair: [Int32] = [-1,-1]
        #expect(socketpair(AF_UNIX, testStreamSocketType, 0,&pair) == 0)
        let serverOutput = fcntl(pair[0],F_DUPFD_CLOEXEC,0)
        let peer = pair[1]
        defer { _ = SystemCall.close(peer) }
        let transport = try StdioTransport(input:.init(rawValue:pair[0]),output:.init(rawValue:serverOutput),inputOwnership:.owned,outputOwnership:.owned)
        let readCopy = try FileDescriptorIO.duplicate(peer)
        try FileDescriptorIO.nonblocking(peer)
        let reader = try FileDescriptorIO(raw:readCopy,writing:false)
        defer { reader.stop() }
        let task = Task { try await transport.run(server:server,principal:ownershipPrincipal,origin:ScalarText("socket")) }
        let request = Array(#"{"jsonrpc":"2.0","id":44,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8) + [10]
        #expect(try request.withUnsafeBytes { try FileDescriptor(rawValue:peer).write($0) } == request.count)
        #expect(SystemCall.shutdown(peer,SHUT_WR) == 0)
        var bytes: [UInt8] = []
        let end = ContinuousClock.now.advanced(by:.seconds(5))
        while !bytes.contains(10) {
            let chunk = try await reader.read(maximum:4096,deadline:end)
            guard !chunk.isEmpty, bytes.count + chunk.count <= 8192 else { throw StdioFailure.invalidOutputFrame }
            bytes += chunk
        }
        try await task.value
        let response = try JSONParser().parseWithReport(Array(bytes.dropLast())).result
        #expect(try response.objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 44)
        #expect(response.objectValue?["result"] != nil && transport.statistics.phase == .stopped)
        reader.stop(); try await reader.join()
    }
}

private actor OriginFrames {
    private var frames: [Data] = []
    func record(_ data: Data) throws {
        guard frames.count < 8, data.count < 1_048_576 else { throw CoreFailure.limit }
        frames.append(data)
    }
    var count: Int { frames.count }
}
@Suite(.serialized) struct StdioOriginIsolation {
    @Test func connectionDrainClosesOnlyMatchingPrincipalAndOrigin() async throws {
        let server = try await ownershipServer()
        let other = VerifiedPrincipal(subject:ScalarText("other"),issuer:ScalarText("host"),resource:ScalarText("stdio"),scopes:[])
        let a = OriginFrames(), b = OriginFrames(), c = OriginFrames()
        let input = Data(#"{"jsonrpc":"2.0","id":8,"method":"subscriptions/listen","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}},"notifications":{}}}"#.utf8)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for (principal,origin,frames) in [(ownershipPrincipal,"a",a),(ownershipPrincipal,"b",b),(other,"a",c)] {
                group.addTask { try await server.dispatchEvents(input,principal:principal,origin:ScalarText(origin),mode:.stdio) { try await frames.record($0) } }
            }
            let end = ContinuousClock.now.advanced(by:.seconds(5))
            while true {
                let counts = await (a.count,b.count,c.count)
                if counts == (1,1,1) { break }
                guard ContinuousClock.now < end else { throw StdioFailure.readDeadline }
                try await Task.sleep(for:.milliseconds(2))
            }
            await server.closeSubscriptions(for:ownershipPrincipal,origin:ScalarText("a"))
            await server.closeSubscriptions(for:ownershipPrincipal,origin:ScalarText("a"))
            while await a.count != 3 {
                guard ContinuousClock.now < end else { throw StdioFailure.drainDeadline }
                try await Task.sleep(for:.milliseconds(2))
            }
            let others = await (b.count,c.count)
            #expect(others == (1,1))
            #expect(await server.activity.subscriptions == 2)
            await server.closeSubscriptions(for:ownershipPrincipal,origin:ScalarText("b"))
            await server.closeSubscriptions(for:other,origin:ScalarText("a"))
            try await group.waitForAll()
        }
        let finalCounts = await (a.count,b.count,c.count)
        #expect(finalCounts == (3,3,3))
        let activity = await server.activity
        #expect(activity.subscriptions == 0 && activity.requests == 0 && activity.active == 0 && activity.bufferedBytes == 0)
    }
}
