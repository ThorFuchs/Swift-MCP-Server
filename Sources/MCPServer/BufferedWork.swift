// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Conservative logical weights; neither a physical RSS nor CPU guarantee.
actor BufferedWork {
    struct Ticket: Sendable { let id: UUID }
    let limit: Int
    private var used = 0
    private var entries: [UUID: Int] = [:]
    init(limit: Int) { self.limit = limit }
    func reserve(_ bytes: Int) throws -> Ticket {
        guard bytes > 0, bytes <= limit - used else { throw CoreFailure.limit }
        let id = UUID(); entries[id] = bytes; used += bytes
        return .init(id: id)
    }
    func release(_ ticket: Ticket) throws {
        guard let bytes = entries.removeValue(forKey: ticket.id) else { throw CoreFailure.limit }
        used -= bytes
    }
    var retainedBytes: Int { used }
}
