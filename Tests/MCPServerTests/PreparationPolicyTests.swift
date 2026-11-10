// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import Testing
import MCPProtocol
import MCPServer

@Test func finitePreparationCeilingsFailRatherThanResetAtHelperBoundaries() async throws {
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerPreparationPolicy(work: UInt64.max) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerPreparationPolicy(evaluation: 0) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerPreparationPolicy(evaluation: 256_000_001) }
    let tiny = try ServerPreparationPolicy(work: 4096, numeric: 1, compilation: 1, evaluation: 1, regexCompilation: 1, regexAggregate: 1)
    let info = try WireCodec.parse(Array(#"{"name":"finite-preparation","version":"1"}"#.utf8), limits: .balanced).result
    let cursors = try CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 1, count: 32))], active: ScalarText("test"), clock: { 1000 })
    await #expect(throws: (any Error).self) {
        _ = try await Server.make(info: info, catalog: ServerCatalog(), cursors: cursors, configuration: ServerConfiguration(preparation: tiny))
    }
}
