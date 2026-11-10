// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct RecordedExchange: Sendable {
    public enum Outcome: Sendable { case completed, failed }
    public let sequence: Int
    public let request: Data
    public let response: Data?
    public let outcome: Outcome
}
actor ExchangeRecorder {
    struct Ticket: Sendable { let sequence: Int }
    private let countLimit: Int, byteLimit: Int
    private var entries: [Int: RecordedExchange] = [:]
    private var pending: [Int: Data] = [:]
    private var next = 0, bytes = 0
    init(countLimit: Int, byteLimit: Int) throws {
        guard countLimit > 0, countLimit <= 10_000, byteLimit > 0, byteLimit <= 268_435_456 else { throw RecordingFailure.limit }
        self.countLimit = countLimit; self.byteLimit = byteLimit
    }
    func begin(_ request: Data) throws -> Ticket {
        guard next < countLimit, request.count <= byteLimit - bytes else { throw RecordingFailure.limit }
        let ticket = Ticket(sequence: next); next += 1; bytes += request.count; pending[ticket.sequence] = request
        return ticket
    }
    func finish(_ ticket: Ticket, response: Data?, outcome: RecordedExchange.Outcome) throws {
        guard let request = pending.removeValue(forKey: ticket.sequence) else { throw RecordingFailure.invalidTicket }
        let responseBytes = response?.count ?? 0
        guard responseBytes <= byteLimit - bytes else {
            entries[ticket.sequence] = .init(sequence: ticket.sequence, request: request, response: nil, outcome: .failed)
            throw RecordingFailure.limit
        }
        bytes += responseBytes
        entries[ticket.sequence] = .init(sequence: ticket.sequence, request: request, response: response, outcome: outcome)
    }
    var snapshot: [RecordedExchange] { entries.keys.sorted().map { entries[$0]! } }
}
public enum RecordingFailure: Error, Sendable { case limit, invalidTicket }
