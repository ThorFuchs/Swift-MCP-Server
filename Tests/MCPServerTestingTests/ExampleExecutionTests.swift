// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Testing
import JSON
import MCPProtocol

/// The test owns each subprocess and every pipe. Bounded nonblocking reads avoid
/// an unbounded collector or detached task; cleanup joins only this owned child.
private final class ExampleChild {
    let process = Process(), input = Pipe(), output = Pipe(), diagnostics = Pipe()
    var out = Data(), err = Data()
    init(_ binary: String, arguments: [String] = [], environment: [String:String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        try process.run()
        for fd in [output.fileHandleForReading.fileDescriptor, diagnostics.fileHandleForReading.fileDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func write(_ bytes: Data) throws { try input.fileHandleForWriting.write(contentsOf: bytes) }
    func eof() { try? input.fileHandleForWriting.close() }
    func pump() throws {
        for (fd, kind) in [(output.fileHandleForReading.fileDescriptor,0),(diagnostics.fileHandleForReading.fileDescriptor,1)] {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard out.count + err.count + count <= 2097152 else { throw TestFailure.limit }
                    if kind == 0 { out.append(contentsOf: buffer.prefix(count)) } else { err.append(contentsOf: buffer.prefix(count)) }
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                else if errno != EINTR { throw TestFailure.io }
            }
        }
    }
    func until(_ predicate: () -> Bool, seconds: Int = 60) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true { try pump(); if predicate() { return }; guard ContinuousClock.now < deadline else { throw TestFailure.timeout }; try await Task.sleep(for: .milliseconds(5)) }
    }
    func finish() async throws -> Int32 {
        // isRunning=false and terminationStatus establish Foundation-reaped exit.
        // waitUntilExit can enter an unbounded CFRunLoop after that transition.
        try await until({ !process.isRunning }, seconds: 15); try pump(); return process.terminationStatus
    }
    deinit {
        if process.isRunning { process.terminate(); let end = Date().addingTimeInterval(5); while process.isRunning && Date() < end { usleep(10000) }; if process.isRunning { kill(process.processIdentifier, SIGKILL); let killed = Date().addingTimeInterval(5); while process.isRunning && Date() < killed { usleep(10000) } } }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? diagnostics.fileHandleForReading.close()
    }
    enum TestFailure: Error { case limit, io, timeout }
}
private func exampleJSON(_ s: String) throws -> JSON { try WireCodec.parse(Array(s.utf8), limits: .balanced).result }
private func exampleRequest(_ name: String, id: Int, fields: String = "", method: String = "tools/call", capabilities: String = "{}", metadata: String = "") -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":\(capabilities)\(metadata)},\"name\":\"\(name)\"\(fields)}}".utf8)
}
private func exampleBinary(_ key: String) throws -> String { try #require(ProcessInfo.processInfo.environment[key], "Actual outside-root example binary is required") }
@Suite(.serialized) struct ExampleExecutionCases {
    @Test func realStdioExampleFragmentsErrorsSilenceCancellationAndBackpressure() async throws {
        let child = try ExampleChild(exampleBinary("MCP_EXAMPLE_STDIO"), arguments: ["--extensions"])
        try await child.until { String(decoding: child.err, as: UTF8.self).contains("EXAMPLE_READY") }
        try child.write(Data("{bad}\n".utf8))
        try child.write(Data(#"{"jsonrpc":"2.0","method":"com.example/unsupported"}"#.utf8) + Data([10]))
        try child.write(exampleRequest("wait", id: 2) + Data([10]))
        try await child.until { String(decoding: child.err, as: UTF8.self).contains("EXAMPLE_PROVIDER_WAITING") }
        try child.write(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8) + Data([10]))
        let text = String(repeating: "世界", count: 8192)
        let quoted = String(decoding: try WireCodec.write(.string(text), limits: .balanced).result, as: UTF8.self)
        let frame = exampleRequest("echo", id: 3, fields: ",\"arguments\":{\"text\":" + quoted + "}")
        let unicode = try #require(frame.firstIndex(of: 0xE4))
        for slice in [frame.prefix(7), frame.dropFirst(7).prefix(unicode - 6), frame.dropFirst(unicode + 1)] { try child.write(Data(slice)) }
        try child.write(Data([10]))
        let supplemental = Data(#"{"jsonrpc":"2.0","id":4,"method":"com.example/demo/echo","params":{"text":"stdio extension","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"com.example/demo":{}}}}}}"#.utf8)
        try child.write(supplemental + Data([10])); child.eof()
        #expect(try await child.finish() == 0)
        let frames = try child.out.split(separator: 10).map { try exampleJSON(String(decoding: $0, as: UTF8.self)) }
        #expect(frames.count == 3)
        #expect(frames[0].objectValue?["error"] != nil && frames[0].objectValue?["id"]?.isNull == true)
        #expect(frames.first { (try? $0.objectValue?["id"]?.numberValue?.integer(as: Int.self, limits: .balanced)) == 3 }?.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["text"]?.stringValue == text)
        #expect(frames.first { (try? $0.objectValue?["id"]?.numberValue?.integer(as: Int.self, limits: .balanced)) == 4 }?.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "com.example/demo/echoed")
        #expect(String(decoding: child.err, as: UTF8.self).contains("EXAMPLE_STOPPED joined=1 active=0"))
    }
    @Test func standaloneStdioSignalCancelsOwnedProviderAndJoins() async throws {
        let child = try ExampleChild(exampleBinary("MCP_EXAMPLE_STDIO"))
        try await child.until { String(decoding: child.err, as: UTF8.self).contains("EXAMPLE_READY") }
        try child.write(exampleRequest("wait", id: 1) + Data([10]))
        try await child.until { String(decoding: child.err, as: UTF8.self).contains("EXAMPLE_PROVIDER_WAITING") }
        child.process.terminate()
        #expect(try await child.finish() == 0)
        #expect(child.out.isEmpty)
        #expect(String(decoding: child.err, as: UTF8.self).contains("EXAMPLE_STOPPED joined=1 active=0"))
    }
    // HTTP and TLS example tests live in the separate Swift-MCP-Server-HTTP package.
}
