// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import WikimediaAccess

@Suite struct LiveAccountingTests {
    @Test func deliveredBodyAtCapAndOneOverNeverReplenishes() throws {
        var body = try LiveBodyAccumulator(maximum: 4_194_304)
        for _ in 0..<4_194_304 { try body.append(65) }
        #expect(body.data.count == 4_194_304)
        #expect(throws: LiveFailure.bodyLimit) { try body.append(66) }
        #expect(body.data.count == 4_194_304 && body.data.last == 65)
        #expect(throws: LiveFailure.bodyLimit) { try body.append(67) }
    }
}
