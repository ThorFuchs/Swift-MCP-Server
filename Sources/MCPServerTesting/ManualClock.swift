// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// Explicit wall-time input for cursor tests. It installs no process clock.
public final class ManualClock: Sendable {
    public enum Failure: Error, Sendable { case invalidTime }
    private let time: Mutex<Int64>
    public init(milliseconds: Int64 = 0) throws {
        guard milliseconds >= 0 else { throw Failure.invalidTime }; time = Mutex(milliseconds)
    }
    public var milliseconds: Int64 { time.withLock { $0 } }
    public func advance(milliseconds: Int64) throws {
        try time.withLock { value in
            let sum = value.addingReportingOverflow(milliseconds)
            guard milliseconds >= 0, !sum.overflow else { throw Failure.invalidTime }
            value = sum.partialValue
        }
    }
}
