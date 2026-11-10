// SPDX-License-Identifier: Apache-2.0
/// Owned descriptors transfer on successful construction and close once.
/// Borrowed descriptors must already be nonblocking; only duplicates are closed.
public enum DescriptorOwnership: Sendable { case owned, borrowed }

public enum StdioFailure: Error, Sendable, Equatable {
    case invalidPolicy, invalidDescriptor, unsupportedDescriptor, borrowedDescriptorMustBeNonblocking
    case borrowedDescriptorMustSuppressSIGPIPE
    case alreadyRunning, closed, ioBusy, readDeadline, writeDeadline, drainDeadline
    case ingressOverflow, outputOverflow, invalidOutputFrame, partialWrite, brokenPipe
    case system(Int32)
}

/// Independent finite transport reservations, separate from core request work.
public struct StdioPolicy: Sendable {
    public let frameBytes: Int, outputFrameBytes: Int, chunkBytes: Int, workers: Int
    public let queuedFrames: Int, queuedBytes: Int, writerFrames: Int, writerBytes: Int
    public let readIdleMilliseconds: Int64, writeIdleMilliseconds: Int64
    public let frameMilliseconds: Int64, drainMilliseconds: Int64
    public init(frameBytes: Int = 1_048_576, outputFrameBytes: Int = 4_194_304,
        chunkBytes: Int = 65_536, workers: Int = 2, queuedFrames: Int = 64,
        queuedBytes: Int = 8_388_608, writerFrames: Int = 64, writerBytes: Int = 1_048_576,
        readIdleMilliseconds: Int64 = 30_000, writeIdleMilliseconds: Int64 = 30_000,
        frameMilliseconds: Int64 = 30_000, drainMilliseconds: Int64 = 10_000) throws {
        guard frameBytes > 0, frameBytes <= 8_388_608, outputFrameBytes > 0, outputFrameBytes <= 16_777_216,
            chunkBytes > 0, chunkBytes <= 262_144, workers > 0, workers <= 128,
            queuedFrames > 0, queuedFrames <= 4096, queuedBytes >= frameBytes, queuedBytes <= 268_435_456,
            writerFrames > 0, writerFrames <= 4096, writerBytes > 0, writerBytes <= 268_435_456,
            [readIdleMilliseconds,writeIdleMilliseconds,frameMilliseconds].allSatisfy({ $0 > 0 && $0 <= 3_600_000 }),
            drainMilliseconds > 0, drainMilliseconds <= 30_000 else { throw StdioFailure.invalidPolicy }
        self.frameBytes = frameBytes; self.outputFrameBytes = outputFrameBytes; self.chunkBytes = chunkBytes
        self.workers = workers; self.queuedFrames = queuedFrames; self.queuedBytes = queuedBytes
        self.writerFrames = writerFrames; self.writerBytes = writerBytes
        self.readIdleMilliseconds = readIdleMilliseconds; self.writeIdleMilliseconds = writeIdleMilliseconds
        self.frameMilliseconds = frameMilliseconds; self.drainMilliseconds = drainMilliseconds
    }
}
