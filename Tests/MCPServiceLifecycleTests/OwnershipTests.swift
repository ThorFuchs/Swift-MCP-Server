// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import Logging
import ServiceLifecycle
import MCPServiceLifecycle
import MCPServer
import MCPProtocol
import MCPStdio
import SystemPackage
import JSON
import Darwin

private actor LifeLog {
    var entries: [String] = []
    func add(_ value: String) { entries.append(value) }
}
private final class LifeGate: Sendable {
    private struct State { var open = false; var waits: [UUID: CheckedContinuation<Void, Never>] = [:] }
    private let state = Mutex(State())
    var waiting: Int { state.withLock { $0.waits.count } }
    func release() {
        let all = state.withLock { s in s.open = true; let w = Array(s.waits.values); s.waits.removeAll(); return w }
        all.forEach { $0.resume() }
    }
    func wait(cooperative: Bool = true) async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                let immediate = state.withLock { s in
                    if s.open || (cooperative && Task.isCancelled) { return true }
                    s.waits[key] = c; return false
                }
                if immediate { c.resume() }
            }
        } onCancel: {
            if cooperative { self.state.withLock { $0.waits.removeValue(forKey: key) }?.resume() }
        }
    }
}
private final class LifeClock: LifecycleClock {
    private struct State { var now: Int64 = 0; var waits: [UUID: (Int64, CheckedContinuation<Void, any Error>)] = [:] }
    private let state = Mutex(State())
    func nowMilliseconds() -> Int64 { state.withLock { $0.now } }
    func advance(_ by: Int64) {
        let all = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.now += by
            let ready = s.waits.filter { $0.value.0 <= s.now }; ready.keys.forEach { s.waits.removeValue(forKey:$0) }
            return ready.values.map { $0.1 }
        }
        all.forEach { $0.resume() }
    }
    func sleep(untilMilliseconds end: Int64) async throws {
        let key = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let immediate = state.withLock { s -> Int in
                    if Task.isCancelled { return 2 }; if s.now >= end { return 1 }
                    s.waits[key] = (end,c); return 0
                }
                if immediate == 2 { c.resume(throwing:CancellationError()) }; if immediate == 1 { c.resume() }
            }
        } onCancel: { self.state.withLock { $0.waits.removeValue(forKey:key) }?.1.resume(throwing:CancellationError()) }
    }
}
// macOS can defer peer EOF visibility beyond close() even with no retained
// descriptor (see the independent Unix EOF kernel probe). Observe the actual
// event under a separate finite bound; never accept EAGAIN or unexpected bytes.
private func lifePeerEOF(_ descriptor: Int32, milliseconds: Int64 = 100) async throws {
    let end = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
    var byte: UInt8 = 0
    while true {
        try Task.checkCancellation()
        guard ContinuousClock.now < end else { throw StdioFailure.readDeadline }
        let count = Darwin.recv(descriptor, &byte, 1, MSG_DONTWAIT), failure = errno
        if count == 0 { return }
        guard count < 0 else { throw StdioFailure.invalidOutputFrame }
        guard failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func lifeUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by:.seconds(4))
    while !(await predicate()) {
        guard ContinuousClock.now < end else { throw LifecycleFailure.startupDeadline }
        try await Task.sleep(for:.milliseconds(2))
    }
}
private func component(_ name: String, dependencies: [String] = [], log: LifeLog, gate: LifeGate) throws -> TransportService {
    try .init(name:name,dependencies:dependencies,run: { ready in
        await log.add("start."+name); try await ready(); await gate.wait(); await log.add("end."+name)
    },shutdown: { await log.add("stop."+name); gate.release() })
}

@Suite struct NativeLifecycleOwnership {
    @Test func dependencyReadinessAndReverseDrainKeepProvidersAlive() async throws {
        let log = LifeLog(), provider = LifeGate(), transport = LifeGate()
        let service = try ServerService(components:[component("transport",dependencies:["provider"],log:log,gate:transport),component("provider",log:log,gate:provider)],stopAdmission: { await log.add("admission.stop") })
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { try await service.run() }
            group.addTask {
                try await lifeUntil { await service.readiness.state == .ready }
                #expect(await log.entries == ["start.provider","start.transport"])
                service.requestShutdown(); service.requestShutdown()
            }
            try await group.waitForAll()
        }
        #expect(await log.entries == ["start.provider","start.transport","admission.stop","stop.transport","end.transport","stop.provider","end.provider"])
        #expect(await service.report.joined == 2); #expect(await service.report.escalated == 0)
        #expect(await service.readiness.state == .stopped)
        await #expect(throws:LifecycleFailure.alreadyRun) { try await service.run() }
    }
    @Test func failedStartupCleansOnlyStartedDependenciesAndNeverReportsReady() async throws {
        let log = LifeLog(), provider = LifeGate()
        let broken = try TransportService(name:"broken",dependencies:["provider"],run: { _ in throw CoreFailure.invalidPolicy },shutdown:{ await log.add("stop.broken") })
        let never = try component("never",dependencies:["broken"],log:log,gate:LifeGate())
        let service = try ServerService(components:[component("provider",log:log,gate:provider),broken,never])
        await #expect(throws:LifecycleFailure.componentFailed(1)) { try await service.run() }
        #expect(await service.readiness.state == .failed)
        #expect(await service.report.started == 2); #expect(await service.report.joined == 2)
        #expect(await log.entries == ["start.provider","stop.broken","stop.provider","end.provider"])
    }
    @Test func invalidGraphsAndFinitePoliciesRejectBeforeAnyStartup() throws {
        let log = LifeLog(), gate = LifeGate()
        #expect(throws:LifecycleFailure.invalidConfiguration) { try ServerService(components:[]) }
        #expect(throws:LifecycleFailure.invalidConfiguration) { try ServerService(components:[component("a",dependencies:["b"],log:log,gate:gate),component("b",dependencies:["a"],log:log,gate:gate)]) }
        #expect(throws:LifecycleFailure.invalidConfiguration) { try ServerService(components:[component("a",dependencies:["missing"],log:log,gate:gate)]) }
        #expect(throws:LifecycleFailure.invalidConfiguration) { try ServerService(components:[component("a",log:log,gate:gate),component("a",log:log,gate:gate)]) }
        #expect(throws:LifecycleFailure.invalidConfiguration) { try DrainCoordinator(startupMilliseconds:0) }
        #expect(throws:LifecycleFailure.invalidConfiguration) { try DrainCoordinator(drainMilliseconds:Int64.max) }
        #expect(throws:LifecycleFailure.invalidConfiguration) { try component("private/uri",log:log,gate:gate) }
    }
    @Test func stopBeforeRunCannotBindOrReopen() async throws {
        let log = LifeLog(), service = try ServerService(components:[component("io",log:log,gate:LifeGate())])
        service.requestShutdown(); service.requestShutdown()
        await #expect(throws:LifecycleFailure.stopped) { try await service.run() }
        #expect(await log.entries.isEmpty); #expect(await service.readiness.state == .stopped)
    }
    @Test func injectedStartupDeadlineCancelsUnreadyChildAndSkipsDependants() async throws {
        let clock = LifeClock(), gate = LifeGate(), log = LifeLog()
        let slow = try TransportService(name:"slow",run:{ _ in await log.add("slow.start"); await gate.wait() },shutdown:{ gate.release() })
        let service = try ServerService(components:[slow,component("io",dependencies:["slow"],log:log,gate:LifeGate())],policy:DrainCoordinator(startupMilliseconds:100,drainMilliseconds:100,clock:clock))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await #expect(throws:LifecycleFailure.startupDeadline) { try await service.run() } }
            group.addTask { try await lifeUntil { await log.entries == ["slow.start"] }; clock.advance(100) }
            try await group.waitForAll()
        }
        #expect(await service.report.started == 1); #expect(await service.report.joined == 1)
        #expect(await service.readiness.state == .failed)
    }
    @Test func deadlineReportsEscalationWhileLateCallbackStillMustJoin() async throws {
        let clock = LifeClock(), late = LifeGate(), force = Mutex(0), completed = Mutex(false)
        defer { late.release() }
        let lifetime = try TransportService(name:"late",run:{ ready in try await ready(); await late.wait(cooperative:false) },shutdown:{},forceClose:{ force.withLock { $0 += 1 } })
        let service = try ServerService(components:[lifetime],policy:DrainCoordinator(startupMilliseconds:1000,drainMilliseconds:100,clock:clock))
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { late.release(); group.cancelAll() }
            group.addTask { await #expect(throws:LifecycleFailure.drainDeadline) { try await service.run() }; completed.withLock { $0 = true } }
            group.addTask {
                try await lifeUntil { await service.readiness.state == .ready }
                service.requestShutdown(); try await lifeUntil { await service.readiness.state == .draining }
                clock.advance(100)
                try await lifeUntil { await service.report.escalated == 1 }
                #expect(force.withLock { $0 } == 1 && !completed.withLock { $0 })
                #expect(await service.readiness.state == .draining)
                late.release()
            }
            try await group.waitForAll()
        }
        #expect(await service.report.joined == 1); #expect(await service.readiness.state == .failed)
    }
    @Test func stalledShutdownCallbackEscalatesBeforeJoiningAndKeepsDependencyAlive() async throws {
        let clock = LifeClock(), callback = LifeGate(), provider = LifeGate(), transport = LifeGate(), log = LifeLog(), forced = Mutex(0)
        let child = try TransportService(name:"transport",dependencies:["provider"],run:{ ready in
            try await ready(); await transport.wait(); await log.add("transport.joined")
        },shutdown:{ await callback.wait(cooperative:false) },forceClose:{ forced.withLock { $0 += 1 }; transport.release() })
        let service = try ServerService(components:[component("provider",log:log,gate:provider),child],policy:DrainCoordinator(startupMilliseconds:1000,drainMilliseconds:100,clock:clock))
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { callback.release(); provider.release(); transport.release(); group.cancelAll() }
            group.addTask { await #expect(throws:LifecycleFailure.drainDeadline) { try await service.run() } }
            try await lifeUntil { await service.readiness.state == .ready }
            service.requestShutdown()
            try await lifeUntil { callback.waiting == 1 }
            clock.advance(100)
            try await lifeUntil { await log.entries.contains("transport.joined") }
            #expect(forced.withLock { $0 } == 1)
            #expect(await log.entries == ["start.provider","transport.joined"])
            #expect(await service.report.escalated == 1)
            callback.release(); try await group.waitForAll()
        }
        #expect(await service.report.joined == 2)
        #expect(await log.entries.contains("end.provider"))
    }
    @Test func admissionStopCallbackUsesSameAbsoluteDeadlineAndCannotOrphanWork() async throws {
        let clock = LifeClock(), admission = LifeGate(), runtime = LifeGate(), forced = Mutex(0), completed = Mutex(false)
        let child = try TransportService(name:"runtime",run:{ ready in try await ready(); await runtime.wait() },shutdown:{ runtime.release() },forceClose:{ forced.withLock { $0 += 1 }; runtime.release() })
        let service = try ServerService(components:[child],policy:DrainCoordinator(startupMilliseconds:1000,drainMilliseconds:100,clock:clock),stopAdmission:{ await admission.wait(cooperative:false) })
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { admission.release(); runtime.release(); group.cancelAll() }
            group.addTask { await #expect(throws:LifecycleFailure.drainDeadline) { try await service.run() }; completed.withLock { $0 = true } }
            try await lifeUntil { await service.readiness.state == .ready }
            service.requestShutdown()
            try await lifeUntil { admission.waiting == 1 }
            clock.advance(100)
            try await lifeUntil { forced.withLock { $0 } == 1 }
            #expect(!completed.withLock { $0 })
            admission.release(); try await group.waitForAll()
        }
        #expect(await service.report.joined == 1); #expect(await service.report.escalated == 1)
    }
    @Test func runtimeReadinessViewAndDrainClockOverflowFailClosedWithJoinedChildren() async throws {
        let clock = LifeClock(), gate = LifeGate(), forced = Mutex(0)
        let component = try TransportService(name:"owned",run:{ ready in try await ready(); await gate.wait() },shutdown:{ gate.release() },forceClose:{ forced.withLock { $0 += 1 }; gate.release() })
        let service = try ServerService(components:[component],policy:DrainCoordinator(startupMilliseconds:1000,drainMilliseconds:100,clock:clock))
        let view: RuntimeReadiness = service.readiness
        #expect(await view.state == .starting)
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { gate.release(); group.cancelAll() }
            group.addTask { await #expect(throws:LifecycleFailure.invalidClock) { try await service.run() } }
            try await lifeUntil { await view.state == .ready }
            clock.advance(Int64.max); service.requestShutdown(); try await group.waitForAll()
        }
        #expect(await view.state == .failed); #expect(await service.report.joined == 1)
        #expect(forced.withLock { $0 } == 1)
    }
    @Test func embeddedGroupCancellationJoinsLateChildWithoutProcessAbort() async throws {
        let late = LifeGate(), forced = Mutex(0)
        defer { late.release() }
        let lifetime = try TransportService(name:"late",run:{ ready in try await ready(); await late.wait(cooperative:false) },shutdown:{},forceClose:{ forced.withLock { $0 += 1 } })
        let service = try ServerService(components:[lifetime],policy:DrainCoordinator(drainMilliseconds:5))
        let embedded = EmbeddedServerGroup(service:service,logger:Logger(label:"test",factory:{ _ in SwiftLogNoOpLogHandler() }))
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { late.release(); group.cancelAll() }
            group.addTask { do { try await embedded.run() } catch { #expect(error is CancellationError) } }
            try await lifeUntil { await service.readiness.state == .ready }
            group.cancelAll()
            // This task is not cancelled by group.cancelAll(); the owned child is.
            try await lifeUntil { forced.withLock { $0 } == 1 }
            try await Task.sleep(for:.milliseconds(30))
            #expect(await service.readiness.state == .draining)
            late.release(); try await group.waitForAll()
        }
        #expect(await service.report.joined == 1); #expect(await service.readiness.state == .stopped)
    }
    @Test func embeddedGracefulShutdownAndRepeatedCreationHaveZeroLiveChildren() async throws {
        for _ in 0..<8 {
            let gate = LifeGate(), log = LifeLog(), service = try ServerService(components:[component("owned",log:log,gate:gate)])
            let embedded = EmbeddedServerGroup(service:service,logger:Logger(label:"embedded",factory:{ _ in SwiftLogNoOpLogHandler() }))
            try await withThrowingTaskGroup(of:Void.self) { group in
                group.addTask { try await embedded.run() }
                group.addTask { try await lifeUntil { await service.readiness.state == .ready }; await embedded.requestShutdown() }
                try await group.waitForAll()
            }
            let report = await service.report; #expect(report.started == report.joined); #expect(await service.readiness.state == .stopped)
        }
    }
    @Test func unixPeerEOFRejectsRetainedDescriptionAndObservesClosedPeer() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { _ = Darwin.close(pair[1]) }
        var held = fcntl(pair[0], F_DUPFD_CLOEXEC, 0)
        try #require(held >= 0)
        defer { if held >= 0 { _ = Darwin.close(held) } }
        try #require(Darwin.close(pair[0]) == 0)
        // A real leaked/open description cannot satisfy the EOF observation.
        await #expect(throws: StdioFailure.readDeadline) {
            try await lifePeerEOF(pair[1], milliseconds: 20)
        }
        try #require(Darwin.close(held) == 0); held = -1
        try await lifePeerEOF(pair[1])
    }

    @Test func realStdioLifecycleShutdownClosesOwnedDescriptorsAndCoreAdmission() async throws {
        let server = try await Server.make(info:JSONParser().parseWithReport(Array(#"{"name":"lifecycle","version":"1"}"#.utf8)).result,
            catalog:ServerCatalog(),cursors:CursorProtector(keys:[.init(identifier:ScalarText("lifecycle"),material:Data(repeating:1,count:32))],active:ScalarText("lifecycle"),clock:{1000}))
        let principal = VerifiedPrincipal(subject:ScalarText("stdio"),issuer:ScalarText("host"),resource:ScalarText("mcp"),scopes:[])
        for _ in 0..<4 {
            var pair: [Int32] = [-1,-1]; #expect(socketpair(AF_UNIX,SOCK_STREAM,0,&pair) == 0)
            let output = fcntl(pair[0],F_DUPFD_CLOEXEC,0)
            // This caller-owned witness keeps the exact socket description alive.
            // Integer FD values may be reassigned by unrelated concurrent tests
            // immediately after close; fcntl on that integer is not identity proof.
            let witness = fcntl(pair[0],F_DUPFD_CLOEXEC,0)
            #expect(witness >= 0)
            let transport = try StdioTransport(input:.init(rawValue:pair[0]),output:.init(rawValue:output),inputOwnership:.owned,outputOwnership:.owned)
            let component = try TransportService(name:"stdio",run:{ ready in try await ready(); try await transport.run(server:server,principal:principal,origin:ScalarText("stdio")) },shutdown:{ transport.shutdown() })
            let service = try ServerService(components:[component])
            try await withThrowingTaskGroup(of:Void.self) { group in
                group.addTask { try await service.run() }
                group.addTask {
                    try await lifeUntil { let state = await service.readiness.state; return transport.statistics.phase == .running && state == .ready }
                    service.requestShutdown()
                }
                try await group.waitForAll()
            }
            #expect(transport.statistics.phase == .stopped)
            var byte: UInt8 = 0
            let stillOpen = Darwin.recv(pair[1],&byte,1,MSG_DONTWAIT), openError = errno
            #expect(stillOpen == -1 && (openError == EAGAIN || openError == EWOULDBLOCK))
            #expect(Darwin.close(witness) == 0)
            // The I/O boundary closes descriptors, without socket shutdown. EOF
            // after dropping the witness proves both originals and all internal
            // duplicates were closed; a leaked description keeps this peer open.
            try await lifePeerEOF(pair[1])
            _ = Darwin.close(pair[1])
        }
        let owned = try ServerService(server:server,components:[component("final",log:LifeLog(),gate:LifeGate())])
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { try await owned.run() }; group.addTask { try await lifeUntil { await owned.readiness.state == .ready }; owned.requestShutdown() }; try await group.waitForAll()
        }
        await #expect(throws:(any Error).self) { _ = try await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#.utf8),principal:principal,origin:ScalarText("closed")) }
        let activity = await server.activity; #expect(activity.active == 0 && activity.requests == 0)
    }
}
