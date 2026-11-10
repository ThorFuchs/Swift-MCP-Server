// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import MCPStdio

@Test func fragmentedUTF8AndCRLF() throws {
    let bytes = Array("{\"name\":\"世界\"}\r\n{}\n".utf8)
    for split in 0...bytes.count {
        var framer = try LineFramer(maximumFrameBytes: 64, maximumChunkBytes: 64)
        let frames = try framer.append(Array(bytes[..<split])) + framer.append(Array(bytes[split...]))
        #expect(frames == [Array("{\"name\":\"世界\"}".utf8), Array("{}".utf8)])
        try framer.finish()
        #expect(framer.bufferedBytes == 0)
    }
}

@Test func framingLimitsAndPoisonedStream() throws {
    var framer = try LineFramer(maximumFrameBytes: 2, maximumChunkBytes: 4)
    #expect(try framer.append(Array("{}\n".utf8)) == [Array("{}".utf8)])
    #expect(throws: LineFramer.Failure.frameTooLarge) { _ = try framer.append([1, 2, 3]) }
    #expect(framer.bufferedBytes == 0)
    #expect(throws: LineFramer.Failure.closed) { _ = try framer.append([10]) }
}

@Test(arguments: [[UInt8](arrayLiteral: 10), [13, 10], [0xff, 10], [0xe2, 0x82, 10]])
func invalidFrames(_ bytes: [UInt8]) throws {
    var framer = try LineFramer()
    #expect(throws: (any Error).self) { _ = try framer.append(bytes) }
    #expect(framer.bufferedBytes == 0)
}

@Test func EOFRequiresDelimiterAndChunksAreFinite() throws {
    var framer = try LineFramer(maximumFrameBytes: 10, maximumChunkBytes: 2)
    #expect(throws: LineFramer.Failure.chunkTooLarge) { _ = try framer.append([1, 2, 3]) }
    var trailing = try LineFramer()
    _ = try trailing.append(Array("{}".utf8))
    #expect(throws: LineFramer.Failure.unterminatedFrame) { try trailing.finish() }
    #expect(throws: LineFramer.Failure.invalidLimit) { _ = try LineFramer(maximumFrameBytes: 0) }
}

private actor Sink {
    var frames: [[UInt8]] = []
    var entered = false
    var release: CheckedContinuation<Void, Never>?
    func stalled(_ frame: [UInt8]) async {
        entered = true
        await withCheckedContinuation { release = $0 }
        frames.append(frame)
    }
    func resume() { release?.resume(); release = nil }
    func record(_ frame: [UInt8]) { frames.append(frame) }
}

@Test func inFlightWriterBytesRemainCharged() async throws {
    let writer = try BoundedWriter(frameLimit: 4, byteLimit: 4, frameCountLimit: 2)
    let sink = Sink()
    try await writer.enqueue([1, 2, 3, 4])
    let worker = Task { try await writer.run { await sink.stalled($0) } }
    while await !sink.entered { await Task.yield() }
    #expect(await writer.retainedBytes == 4)
    await #expect(throws: BoundedWriter.Failure.overflow) { try await writer.enqueue([5]) }
    await writer.finish()
    await sink.resume()
    try await worker.value
    #expect(await sink.frames == [[1, 2, 3, 4]])
    #expect(await writer.retainedBytes == 0)
    await #expect(throws: BoundedWriter.Failure.closed) { try await writer.enqueue([1]) }
}

@Test func serialWriterDrainsWholeFrames() async throws {
    let writer = try BoundedWriter(frameLimit: 4, byteLimit: 8, frameCountLimit: 2)
    let sink = Sink()
    try await writer.enqueue([1, 2])
    try await writer.enqueue([3, 4])
    await #expect(throws: BoundedWriter.Failure.overflow) { try await writer.enqueue([5]) }
    await writer.finish()
    try await writer.run { await sink.record($0) }
    #expect(await sink.frames == [[1, 2], [3, 4]])
    #expect(await writer.retainedFrames == 0)
    await #expect(throws: BoundedWriter.Failure.alreadyRunning) { try await writer.run { _ in } }
}

@Test func writerCancellationUnblocksIdleLoop() async throws {
    let writer = try BoundedWriter()
    let worker = Task { try await writer.run { _ in } }
    worker.cancel()
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(await writer.retainedBytes == 0)
}

@Test func writerFailureDiscardsBoundedQueue() async throws {
    struct Broken: Error {}
    let writer = try BoundedWriter()
    try await writer.enqueue([1])
    try await writer.enqueue([2])
    await #expect(throws: Broken.self) { try await writer.run { _ in throw Broken() } }
    #expect(await writer.retainedBytes == 0)
    #expect(await writer.retainedFrames == 0)
    await #expect(throws: BoundedWriter.Failure.closed) { try await writer.enqueue([3]) }
}
