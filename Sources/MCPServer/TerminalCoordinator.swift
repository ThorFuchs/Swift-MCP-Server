// SPDX-License-Identifier: Apache-2.0
/// Elects one owner before any terminal emission. The elected write must finish
/// or record failure; a failed write cannot be retried as a second result.
public actor TerminalCoordinator {
    public enum Outcome: Sendable, Equatable { case complete, failure, cancelled, disconnected }
    private var terminal: Outcome?
    public init() {}
    public var outcome: Outcome? { terminal }
    @discardableResult public func claim(_ outcome: Outcome) -> Bool {
        guard terminal == nil else { return false }
        terminal = outcome
        return true
    }
}
