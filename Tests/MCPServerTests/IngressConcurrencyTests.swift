// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import MCPProtocol
import MCPServer

@Test func concurrentIngressInspectionDoesNotUseCancellationControlCapacity() async throws {
    let server = try await Server.make(info: WireCodec.parse(Array(#"{"name":"inspection","version":"1"}"#.utf8), limits: .balanced).result,
        catalog: ServerCatalog(), cursors: CursorProtector(keys: [.init(identifier: ScalarText("key"), material: Data(repeating: 8, count: 32))], active: ScalarText("key"), clock: { 1000 }))
    let principal = VerifiedPrincipal(subject: ScalarText("test"), issuer: ScalarText("test"), resource: ScalarText("mcp"), scopes: [])
    // Three simultaneous inspections fit configured request capacity but exceed
    // the two-slot cancellation control lane. Discard every owned ticket.
    for round in 0..<4 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    let bytes = Data("""
                    {"jsonrpc":"2.0","id":\(round * 3 + index),"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
                    """.utf8)
                    guard case .request(let ticket) = try await server.inspectIngress(bytes, principal: principal, origin: ScalarText("test")) else {
                        Issue.record("Request inspection lost its request disposition"); return
                    }
                    #expect(await ticket.discard())
                }
            }
            try await group.waitForAll()
        }
    }
    let activity = await server.activity
    #expect(activity.active == 0 && activity.queued == 0 && activity.requests == 0 && activity.bufferedBytes == 0)
    #expect(activity.inspections == 0 && activity.queuedInspections == 0)
    await server.stopAdmission()
    await #expect(throws: AdmissionController.Failure.stopped) {
        _ = try await server.inspectIngress(Data("{}".utf8), principal: principal, origin: ScalarText("test"))
    }
    // Stopping new envelopes does not take away active-request cancellation.
    try await server.cancel(id: .string(ScalarText("absent")), principal: principal, origin: ScalarText("test"))
}
