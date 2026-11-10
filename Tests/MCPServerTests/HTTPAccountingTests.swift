// SPDX-License-Identifier: Apache-2.0
import Testing
import MCPProtocol
@testable import MCPServer

@Test func HTTPResponseCopiesRemainInTheOriginalTerminalReserve() async throws {
    let parent = try RequestBudget(workUnits:8192)
    let directParent = try RequestBudget(workUnits:8192)
    let http = try await TerminalResponse.reserve(from:parent,work:4096,maximumBytes:1024,copyMultiplier:4,fixedWork:64)
    let direct = try await TerminalResponse.reserve(from:directParent,work:4096,maximumBytes:1024)
    // The main operation can fail; neither reserve replenishes its parent.
    await parent.terminate(); await directParent.terminate()
    let first = try await http.encode(id:nil,result:nil,error:.standard(.parse))
    let second = try await direct.encode(id:nil,result:nil,error:.standard(.parse))
    #expect(first == second)
    let paid = await http.account.snapshot, base = await direct.account.snapshot
    #expect(paid.settledWork == base.settledWork + UInt64(first.count) * 3 + 64)
    #expect(await parent.snapshot.settledWork == 4096)
    #expect(await parent.snapshot.remaining == 0)
    await #expect(throws:CoreFailure.limit) { _ = try await http.encode(id:nil,result:nil,error:.standard(.parse)) }
    // Oversized declared transport overhead fails inside the prepaid account.
    let exhaustedParent = try RequestBudget(workUnits:8192)
    let exhausted = try await TerminalResponse.reserve(from:exhaustedParent,work:4096,maximumBytes:1024,fixedWork:4096)
    await #expect(throws:(any Error).self) { _ = try await exhausted.encode(id:nil,result:nil,error:.standard(.parse)) }
    #expect(await exhausted.account.snapshot.isTerminal)
    await #expect(throws:CoreFailure.limit) { _ = try await exhausted.encode(id:nil,result:nil,error:.standard(.parse)) }
}
