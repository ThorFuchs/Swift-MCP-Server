// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting

@Test func manualClockRejectsBackwardsAndOverflow() throws {
    let clock = try ManualClock(milliseconds: Int64.max - 1)
    try clock.advance(milliseconds: 1)
    #expect(clock.milliseconds == Int64.max)
    #expect(throws: ManualClock.Failure.invalidTime) { try clock.advance(milliseconds: 1) }
    #expect(throws: ManualClock.Failure.invalidTime) { try clock.advance(milliseconds: -1) }
    #expect(clock.milliseconds == Int64.max)
}
@Test func harnessUsesRealDispatcherAndRejectsExhaustedRecording() async throws {
    let info = try JSONParser().parseWithReport(Array(#"{"name":"harness","version":"1"}"#.utf8)).result
    let clock = try ManualClock(milliseconds: 1000)
    let cursors = try CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 9, count: 32))], active: ScalarText("test"), clock: { clock.milliseconds })
    let server = try await Server.make(info: info, catalog: ServerCatalog(), cursors: cursors)
    let harness = try InProcessHarness(server: server, maximumExchanges: 1)
    let bytes = Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
    let identity = VerifiedPrincipal(subject: ScalarText("test"), issuer: ScalarText("test"), resource: ScalarText("test"), scopes: [])
    let response = try #require(await harness.exchange(bytes, principal: identity, origin: ScalarText("test")))
    #expect(try JSONParser().parseWithReport(Array(response)).result.objectValue?["result"]?.objectValue?["supportedVersions"]?.arrayValue?.first?.stringValue == "2026-07-28")
    #expect(await harness.exchanges.count == 1)
    await #expect(throws: RecordingFailure.limit) { _ = try await harness.exchange(bytes, principal: identity, origin: ScalarText("test")) }
    let state = await server.activity
    #expect(state.active == 0 && state.bufferedBytes == 0)
}
