// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

/// A disjoint finite reserve debited from the parent before any request work.
/// The reserve is conservatively consumed in full, including independent caps.
/// Its private account is used for one terminal encoding/write only, even after
/// the main account fails. It is never supplied to a provider or replenished.
actor TerminalResponse {
    let account: RequestBudget
    let maximumBytes: Int
    let copyMultiplier:UInt64, fixedWork:UInt64
    private var used = false
    static func reserve(from parent: RequestBudget, work: UInt64, maximumBytes: Int, copyMultiplier:UInt64 = 1, fixedWork:UInt64 = 0) async throws -> TerminalResponse {
        guard (1...8).contains(copyMultiplier),fixedWork <= 1_000_000 else { throw CoreFailure.invalidPolicy }
        let ticket = try await parent.reserve(work, library: true)
        try await parent.settle(ticket, report: .init(version: 1, workUnits: work, subsystems: ticket.subsystems))
        let caps = Dictionary(uniqueKeysWithValues: RequestBudget.Subsystem.allCases.map { ($0, ticket.subsystems[$0]!) })
        return try .init(account: RequestBudget(workUnits: work, subsystemLimits: caps), maximumBytes: maximumBytes,copyMultiplier:copyMultiplier,fixedWork:fixedWork)
    }
    private init(account: RequestBudget, maximumBytes: Int,copyMultiplier:UInt64,fixedWork:UInt64) { self.account = account; self.maximumBytes = maximumBytes; self.copyMultiplier = copyMultiplier; self.fixedWork = fixedWork }
    func encode(id: RequestID?, result: JSON?, error: ModernProtocolError?) async throws -> Data {
        guard !used else { throw CoreFailure.limit }; used = true
        var limits = JSONLimits.balanced
        limits[.outputBytes] = UInt64(maximumBytes)
        let value: JSON
        if let error {
            value = try await account.performJSON(limits: limits) { try ErrorEnvelope.make(error, id: id, limits: $0) }
        } else {
            guard let result, let id else { throw CoreFailure.invalidOutput }
            struct Response: Encodable { let jsonrpc = "2.0"; let id: JSON; let result: JSON }
            value = try await account.performJSON(limits: limits) {
                try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(Response(id: id.value, result: result))
            }
        }
        let bytes = try await account.performJSON(limits: limits) { try WireCodec.write(value, limits: $0) }
        guard bytes.count <= maximumBytes else { throw CoreFailure.limit }
        let copies = UInt64(bytes.count).multipliedReportingOverflow(by:copyMultiplier)
        let charge = copies.partialValue.addingReportingOverflow(fixedWork)
        guard !copies.overflow,!charge.overflow else { throw CoreFailure.limit }
        try await account.consume(charge.partialValue)
        return bytes
    }
}
