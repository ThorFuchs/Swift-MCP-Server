// SPDX-License-Identifier: Apache-2.0
// D28 source tests only. NOT_COMPILED / NOT_RUN; native admission is separate.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Synchronization
import SystemPackage
import Testing
@testable import MCPStdio

enum ConstructionFault: Error, Equatable { case injected(String) }
final class ConstructionObservations: Sendable {
    private struct State { var events: [String] = []; var overflow = false }
    private let state = Mutex(State())
    let failures: Set<String>
    init(_ failures: Set<String> = []) { self.failures = failures }
    var probe: StdioLifecycleProbe {
        .init(checkpoint:{ [self] stage in
            if failures.contains(stage) { throw ConstructionFault.injected(stage) }
        },observe:{ [self] event in
            state.withLock { value in
                if value.events.count < 256 { value.events.append(event) }
                else { value.overflow = true }
            }
        })
    }
    func count(_ prefix: String) -> Int { state.withLock { $0.events.filter { $0.hasPrefix(prefix) }.count } }
    var overflow: Bool { state.withLock { $0.overflow } }
}

@MainActor final class ConstructionPipes {
    let incoming: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
    let outgoing: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
    private var inputOriginal = true, outputOriginal = true, inputPeer = true, outputPeer = true
    init(nonblocking: Bool = true) throws {
        incoming = try testPipe(nonBlocking: nonblocking)
        do { outgoing = try testPipe(nonBlocking: nonblocking) }
        catch { try? incoming.readEnd.close(); try? incoming.writeEnd.close(); throw error }
        if nonblocking { #expect(setNoSigPipe(outgoing.writeEnd.rawValue) == 0) }
    }
    func make(_ observations: ConstructionObservations, owned: Bool = false) throws -> StdioTransport {
        let transport = try StdioTransport(input:incoming.readEnd,output:outgoing.writeEnd,
            inputOwnership:owned ? .owned : .borrowed,outputOwnership:owned ? .owned : .borrowed,
            policy:nil,lifecycle:observations.probe)
        if owned { inputOriginal = false; outputOriginal = false }
        return transport
    }
    func closeInputPeer() throws { if inputPeer { inputPeer = false; try incoming.writeEnd.close() } }
    func closeOutputPeer() throws { if outputPeer { outputPeer = false; try outgoing.readEnd.close() } }
    func close() {
        if inputOriginal { inputOriginal = false; try? incoming.readEnd.close() }
        if outputOriginal { outputOriginal = false; try? outgoing.writeEnd.close() }
        try? closeInputPeer(); try? closeOutputPeer()
    }
}

@Suite(.serialized) @MainActor struct ConstructionLifecycle {
    @Test func synchronousConstructionStartsNoWorkers() throws { // G01-S01
        let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations(); let t = try p.make(events)
        #expect(events.count("activated.") == 0 && events.count("transferred.") == 0)
        #expect(t.statistics.phase == .ready)
        t.shutdown(); t.shutdown()
        #expect(events.count("closed.") == 6 && !events.overflow)
    }
    @Test(arguments:["validated","prepare.input.wake","prepared.input","prepare.output.wake","prepared.output"])
    func failuresPreserveOriginalOwnership(_ stage: String) throws { // G01-S02
        let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations([stage])
        #expect(throws:ConstructionFault.injected(stage)) { _ = try p.make(events,owned:true) }
        #expect(fcntl(p.incoming.readEnd.rawValue,F_GETFD) >= 0)
        #expect(fcntl(p.outgoing.writeEnd.rawValue,F_GETFD) >= 0)
        #expect(events.count("activated.") == 0 && events.count("transferred.") == 0)
        let invalid = try FileDescriptor.pipe(); defer { try? invalid.readEnd.close(); try? invalid.writeEnd.close() }
        #expect(throws:StdioFailure.invalidDescriptor) {
            _ = try StdioTransport(input:invalid.writeEnd,output:p.outgoing.writeEnd,inputOwnership:.owned,outputOwnership:.owned)
        }
    }
    @Test func outputPreparationFailureClosesPreparedInput() throws { // G01-S03
        let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations(["prepared.input"])
        #expect(throws:ConstructionFault.injected("prepared.input")) { _ = try p.make(events) }
        #expect(events.count("closed.input.") == 3 && events.count("closed.output.") == 0)
        #expect(events.count("activated.") == 0 && !events.overflow)
    }
    @Test func setupRollbackRestoresFlagsBeforeTransfer() throws { // G01-S04
        let p = try ConstructionPipes(nonblocking:false); defer { p.close() }
        let beforeInput = fcntl(p.incoming.readEnd.rawValue,F_GETFL)
        let beforeOutput = fcntl(p.outgoing.writeEnd.rawValue,F_GETFL)
        let beforeSignal = getNoSigPipe(p.outgoing.writeEnd.rawValue)
        let events = ConstructionObservations(["flags.applied"])
        #expect(throws:ConstructionFault.injected("flags.applied")) { _ = try p.make(events,owned:true) }
        #expect(fcntl(p.incoming.readEnd.rawValue,F_GETFL) == beforeInput)
        #expect(fcntl(p.outgoing.writeEnd.rawValue,F_GETFL) == beforeOutput)
        #expect(getNoSigPipe(p.outgoing.writeEnd.rawValue) == beforeSignal)
        #expect(events.count("closed.") == 6 && events.count("activated.") == 0)
    }
    @Test func neverRunDisposalHasOnlyPreparedResources() throws { // G01-S05
        let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations()
        var transport: StdioTransport? = try p.make(events,owned:true)
        #expect(transport?.statistics.phase == .ready)
        #expect(events.count("transferred.") == 2 && events.count("activated.") == 0)
        transport = nil
        #expect(events.count("closed.") == 6 && events.count("joined.") == 0)
        #expect(!events.overflow) // No worker existed; disposal is not a join claim.
    }
}
