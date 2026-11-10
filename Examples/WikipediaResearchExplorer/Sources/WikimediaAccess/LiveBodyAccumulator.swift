// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Used by the real AsyncBytes collector. Content-Length is only a preflight
/// hint; every application-delivered byte must be admitted before retention.
struct LiveBodyAccumulator {
    private(set) var data = Data()
    let maximum: Int
    init(maximum: Int) throws {
        guard (1...4_194_304).contains(maximum) else { throw LiveFailure.bodyLimit }
        self.maximum = maximum
    }
    mutating func append(_ byte: UInt8) throws {
        guard data.count < maximum else { throw LiveFailure.bodyLimit }
        data.append(byte)
    }
}
