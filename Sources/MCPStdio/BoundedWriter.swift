// SPDX-License-Identifier: Apache-2.0
/// An owned writer loop serializes whole byte frames. The host calls run in a
/// structured child task and supplies cancellation-aware I/O. In-flight bytes
/// remain charged until the sink completes. Overflow is terminal to the producer.
public actor BoundedWriter {
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit, frameTooLarge, overflow, closed, alreadyRunning
    }
    private let frameLimit: Int
    private let byteLimit: Int
    private let frameCountLimit: Int
    private var queue: [[UInt8]] = []
    private var chargedBytes = 0
    private var chargedFrames = 0
    private var finishing = false
    private var running = false
    private var waiting: CheckedContinuation<Void, any Error>?

    public init(frameLimit: Int = 4_194_304, byteLimit: Int = 1_048_576,
                frameCountLimit: Int = 64) throws {
        guard frameLimit > 0, byteLimit > 0, frameCountLimit > 0 else { throw Failure.invalidLimit }
        self.frameLimit = frameLimit
        self.byteLimit = byteLimit
        self.frameCountLimit = frameCountLimit
    }
    public var retainedBytes: Int { chargedBytes }
    public var retainedFrames: Int { chargedFrames }

    public func enqueue(_ frame: [UInt8]) throws {
        guard !finishing else { throw Failure.closed }
        guard !frame.isEmpty, frame.count <= frameLimit else { throw Failure.frameTooLarge }
        guard chargedFrames < frameCountLimit, frame.count <= byteLimit - chargedBytes else {
            throw Failure.overflow
        }
        queue.append(frame)
        chargedBytes += frame.count
        chargedFrames += 1
        wake()
    }
    /// Stop producers, then drain accepted frames. Cancelling the owned run task
    /// aborts the queue; its sink must cooperate or the host must close owned I/O.
    public func finish() { finishing = true; wake() }

    public func run(sink: @Sendable ([UInt8]) async throws -> Void) async throws {
        guard !running else { throw Failure.alreadyRunning }
        running = true
        do {
            while true {
                try Task.checkCancellation()
                if queue.isEmpty {
                    if finishing { break }
                    try await waitForFrame()
                    continue
                }
                let frame = queue.removeFirst()
                try await sink(frame)
                chargedBytes -= frame.count
                chargedFrames -= 1
            }
        } catch {
            finishing = true
            queue = []
            chargedBytes = 0
            chargedFrames = 0
            wake()
            throw error
        }
    }
    private func waitForFrame() async throws {
        // The cancellation bridge owns only this actor's waiting continuation;
        // no detached I/O or background lifetime is introduced.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }
    private func wake() {
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
    private func cancelWait() {
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: CancellationError())
    }
}
