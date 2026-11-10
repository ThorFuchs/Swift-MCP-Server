// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Byte framing only; JSON syntax and envelope validation belong to Swift-JSON.
/// LF terminates a frame; CRLF is accepted. Empty frames and unterminated EOF
/// are errors. A framing failure poisons the stream rather than resynchronizing.
public struct LineFramer: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit, chunkTooLarge, frameTooLarge, emptyFrame, invalidUTF8, unterminatedFrame, closed
    }
    private let maximumFrameBytes: Int
    private let maximumChunkBytes: Int
    private var pending: [UInt8] = []
    private var closed = false

    public init(maximumFrameBytes: Int = 1_048_576, maximumChunkBytes: Int = 65_536) throws {
        guard maximumFrameBytes > 0, maximumChunkBytes > 0 else { throw Failure.invalidLimit }
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumChunkBytes = maximumChunkBytes
    }
    public var bufferedBytes: Int { pending.count }

    public mutating func append(_ bytes: [UInt8]) throws -> [[UInt8]] {
        guard !closed else { throw Failure.closed }
        do {
            guard bytes.count <= maximumChunkBytes else { throw Failure.chunkTooLarge }
            var frames: [[UInt8]] = []
            for byte in bytes {
                if byte == 10 {
                    if pending.last == 13 { pending.removeLast() }
                    guard !pending.isEmpty else { throw Failure.emptyFrame }
                    guard String(bytes: pending, encoding: .utf8) != nil else { throw Failure.invalidUTF8 }
                    frames.append(pending)
                    pending = []
                } else {
                    // A delimiter CR is included in the byte limit; this keeps
                    // retained bytes bounded even before the following LF arrives.
                    guard pending.count < maximumFrameBytes else { throw Failure.frameTooLarge }
                    pending.append(byte)
                }
            }
            return frames
        } catch {
            closed = true
            pending = []
            throw error
        }
    }
    public mutating func finish() throws {
        guard !closed else { throw Failure.closed }
        closed = true
        defer { pending = [] }
        guard pending.isEmpty else { throw Failure.unterminatedFrame }
    }
}
