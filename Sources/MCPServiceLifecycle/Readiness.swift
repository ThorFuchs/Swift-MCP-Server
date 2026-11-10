// SPDX-License-Identifier: Apache-2.0
/// Local readiness, never a protocol capability or a process-global health server.
public actor Readiness {
    public enum State: Sendable, Equatable { case starting, ready, draining, stopped, failed }
    public enum Failure: Error, Sendable, Equatable { case invalidTransition }
    public private(set) var state: State = .starting
    public init() {}
    public func markReady() throws {
        guard state == .starting else { throw Failure.invalidTransition }
        state = .ready
    }
    public func beginDrain() {
        if state == .starting || state == .ready { state = .draining }
    }
    public func stop() {
        if state != .failed { state = .stopped }
    }
    public func fail() { state = .failed }
}

/// Observation of a runtime-owned state. Only ServerService can transition it;
/// retaining this value never lets a host announce binding or reopen readiness.
public struct RuntimeReadiness: Sendable {
    private let owner: Readiness
    init(_ owner: Readiness) { self.owner = owner }
    public var state: Readiness.State { get async { await owner.state } }
}
