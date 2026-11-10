// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer
import SystemPackage
@testable import MCPStdio

private func stdioRequest(_ method: String = "tools/call", id: String = "1", fields: String = #", "name":"echo""#, meta: String = "") -> [UInt8] {
    Array((#"{"jsonrpc":"2.0","id":"# + id + #","method":""# + method +
        #"","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}"# + meta + "}" + fields + "}}\n").utf8)
}
private func stdioCancel(_ id: String) -> [UInt8] {
    Array((#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"# + id + "}}\n").utf8)
}
private func parsed(_ frame: Data) throws -> JSON { try JSONParser().parseWithReport(Array(frame)).result }

private enum ChildFailure: Error { case exited(String) }
@MainActor private final class Child {
    let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
    var stdout = Data(), stderr = Data(), inputClosed = false, outputClosed = false
    init(_ mode: String = "normal") throws {
        guard let path = ProcessInfo.processInfo.environment["MCP_STDIO_FIXTURE"], FileManager.default.isExecutableFile(atPath:path) else { throw StdioFailure.invalidDescriptor }
        process.executableURL = URL(fileURLWithPath:path); process.arguments = [mode]
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try error.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor,output.fileHandleForReading.fileDescriptor,error.fileHandleForReading.fileDescriptor] {
            guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK) == 0 else { throw StdioFailure.system(errno) }
        }
        _ = setNoSigPipe(input.fileHandleForWriting.fileDescriptor)
    }
    func cleanup() {
        if process.isRunning { kill(process.processIdentifier,SIGKILL) }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close()
    }
    func closeInput() throws { if !inputClosed { inputClosed = true; try input.fileHandleForWriting.close() } }
    func closeOutput() throws { outputClosed = true; try output.fileHandleForReading.close() }
    func pull(_ fd: Int32, into bytes: inout Data) throws {
        var buffer = [UInt8](repeating:0,count:4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,$0.count) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { return }; throw StdioFailure.system(errno) }
            if n == 0 { return }
            guard bytes.count + n <= 2_097_152 else { throw StdioFailure.outputOverflow }
            bytes.append(contentsOf:buffer.prefix(n))
        }
    }
    func collect(readOutput: Bool = true) throws {
        if readOutput && !outputClosed { try pull(output.fileHandleForReading.fileDescriptor,into:&stdout) }
        try pull(error.fileHandleForReading.fileDescriptor,into:&stderr)
    }
    func write(_ bytes: [UInt8], fragment: Int = 65_536) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        var offset = 0
        while offset < bytes.count {
            guard ContinuousClock.now < deadline else { throw StdioFailure.writeDeadline }
            let n = bytes.withUnsafeBytes { p in Darwin.write(input.fileHandleForWriting.fileDescriptor,p.baseAddress!.advanced(by:offset),min(fragment,bytes.count-offset)) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { try await Task.sleep(for:.milliseconds(2)); continue }
                throw StdioFailure.system(errno)
            }
            offset += n
            if fragment < bytes.count { await Task.yield() }
        }
    }
    func waitDiagnostic(_ text: String, count: Int = 1) async throws {
        // Startup cold-prepares every frozen wire plan: about 30-40s in debug builds on
        // a laptop, more on small CI runners or under load. This finite host launch
        // bound is separate from transport I/O; transport deadlines stay unchanged.
        let end = ContinuousClock.now.advanced(by:.seconds(text == "READY" ? 180 : 10))
        while true {
            try collect()
            if String(decoding:stderr,as:UTF8.self).components(separatedBy:text).count > count { return }
            guard process.isRunning else { throw ChildFailure.exited(diagnostics) }
            guard ContinuousClock.now < end else { throw StdioFailure.readDeadline }
            try await Task.sleep(for:.milliseconds(2))
        }
    }
    func frames(_ count: Int) async throws -> [Data] {
        let end = ContinuousClock.now.advanced(by:.seconds(10))
        while stdout.filter({ $0 == 10 }).count < count {
            try collect()
            guard process.isRunning || stdout.filter({ $0 == 10 }).count >= count,
                ContinuousClock.now < end else { throw StdioFailure.readDeadline }
            try await Task.sleep(for:.milliseconds(2))
        }
        return stdout.split(separator:10).map(Data.init)
    }
    func exit(readOutput: Bool = true) async throws -> Int32 {
        let end = ContinuousClock.now.advanced(by:.seconds(10))
        while process.isRunning {
            try collect(readOutput:readOutput)
            guard ContinuousClock.now < end else { throw StdioFailure.drainDeadline }
            try await Task.sleep(for:.milliseconds(2))
        }
        try collect(readOutput:readOutput)
        return process.terminationStatus
    }
    var diagnostics: String { String(decoding:stderr,as:UTF8.self) }
}

@Suite(.serialized) @MainActor struct RealStdioSubprocesses {
    @Test func fragmentedCoalescedExactIDsAndProtocolOnlyStdout() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest(id:"9007199254740993"),fragment:1)
        try await c.write(stdioRequest(id:#""scalar-é""#) + stdioRequest(id:"3"))
        try c.closeInput()
        #expect(try await c.exit() == 0)
        let frames = try c.stdout.split(separator:10).map { try parsed(Data($0)) }
        #expect(frames.count == 3)
        try #require(frames.count == 3)
        #expect(frames.allSatisfy { $0.objectValue?["result"] != nil && $0.objectValue?["method"] == nil })
        #expect(try frames.contains { try $0.objectValue?["id"]?.numberValue?.integer(as:Int64.self,limits:.balanced) == 9007199254740993 })
        #expect(c.stdout.last == 10)
        #expect(frames[0].objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "世界\nhello")
        #expect(c.diagnostics.contains("writer=0 active=0 requests=0 buffered=0 events=0"))
    }
    @Test func recognizableNotificationsSilentAndD01Preserved() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        let silent = [
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":[]}"#,
            #"{"jsonrpc":"2.0","method":"unsupported","params":false}"#]
        try await c.write(Array((silent.joined(separator:"\n")+"\n").utf8) + stdioRequest(id:"null") + Array("{broken}\n".utf8) + stdioRequest(id:"7"))
        try c.closeInput(); #expect(try await c.exit() == 0)
        let values = try c.stdout.split(separator:10).map { try parsed(Data($0)) }
        #expect(values.count == 3)
        #expect(values.filter { $0.objectValue?["id"] == .null }.count == 2)
        #expect(values.filter { $0.objectValue?["error"] != nil }.count == 2)
    }
    @Test func cancellationBypassesSaturatedWorkersAndContinues() async throws {
        let c = try Child("saturated"); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        for id in 1...4 { try await c.write(stdioRequest(id:String(id),fields:#", "name":"slow""#)) }
        try await c.waitDiagnostic("ENTERED slow",count:4)
        try await c.write(stdioCancel("1.5"))
        for id in 1...4 { try await c.write(stdioCancel(String(id))) }
        try await c.write(stdioRequest(id:"5"))
        _ = try await c.frames(1); try c.closeInput()
        #expect(try await c.exit() == 0)
        let values = try c.stdout.split(separator:10).map { try parsed(Data($0)) }
        #expect(values.count == 1)
        try #require(values.count == 1)
        #expect(try values[0].objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 5)
        #expect(c.diagnostics.contains("active=0 requests=0 buffered=0 events=0"))
    }
    @Test func actualSubscriptionServerEOFUsesD02AndProgress() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest("subscriptions/listen",id:"11",fields:#", "notifications":{"toolsListChanged":true}"#))
        let ack = try parsed(try await c.frames(1)[0])
        #expect(ack.objectValue?["method"]?.stringValue == "notifications/subscriptions/acknowledged")
        try await c.write(stdioRequest(id:"12",fields:#", "name":"publish""#,meta:#", "progressToken":9007199254740993"#))
        _ = try await c.frames(3)
        try c.closeInput(); #expect(try await c.exit() == 0)
        let values = try c.stdout.split(separator:10).map { try parsed(Data($0)) }
        #expect(values.count == 5)
        let subscription = values.filter { $0.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] != nil || (try? $0.objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced)) == 11 }
        #expect(subscription.count == 3)
        try #require(subscription.count == 3)
        #expect(subscription[1].objectValue?["method"]?.stringValue == "notifications/cancelled")
        #expect(subscription[2].objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
        #expect(values.contains { $0.objectValue?["method"]?.stringValue == "notifications/progress" })
    }
    @Test func clientSubscriptionCancellationHasNoTerminalFrame() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest("subscriptions/listen",id:"21",fields:#", "notifications":{"toolsListChanged":true}"#))
        _ = try await c.frames(1)
        try await c.write(stdioCancel("21") + stdioRequest(id:"22"))
        _ = try await c.frames(2)
        try c.closeInput(); #expect(try await c.exit() == 0)
        let values = try c.stdout.split(separator:10).map { try parsed(Data($0)) }
        #expect(values.count == 2)
        try #require(values.count == 2)
        #expect(values[0].objectValue?["method"]?.stringValue == "notifications/subscriptions/acknowledged")
        #expect(try values[1].objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 22)
    }
    @Test(arguments: [[UInt8](arrayLiteral:10),[13,10],[255,10],[226,130,10],Array("{}".utf8),Array(repeating:65,count:129)])
    func malformedFramingPoisonsOnlyOwnedChild(_ bytes: [UInt8]) async throws {
        let c = try Child("tiny"); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(bytes); try c.closeInput()
        #expect(try await c.exit() == 2)
        #expect(c.stdout.isEmpty)
        #expect(c.diagnostics.contains("STOP"))
    }
    @Test func stalledOutputIsFiniteAndNeverAppendsSecondFrame() async throws {
        let c = try Child("stalled"); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest(fields:#", "name":"big""#)); try c.closeInput()
        #expect(try await c.exit(readOutput:false) == 2)
        try c.collect()
        #expect(c.stdout.count > 0 && c.stdout.count < 131_072)
        #expect(!c.stdout.contains(10))
        #expect(c.diagnostics.contains("STOP"))
        #expect(c.diagnostics.contains("active=0 requests=0 buffered=0 events=0"))
    }
    @Test func largeSuccessfulFrameSurvivesRealPipeBackpressure() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest(fields:#", "name":"big""#))
        let frames = try await c.frames(1)
        try c.closeInput(); #expect(try await c.exit() == 0)
        let response = try parsed(try #require(frames.first))
        #expect(response.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?.utf8.count == 131_072)
        #expect(c.stdout.last == 10 && c.stdout.filter { $0 == 10 }.count == 1)
        #expect(c.diagnostics.contains("writer=0 active=0 requests=0 buffered=0 events=0"))
    }
    @Test func brokenOutputSurvivesDefaultSIGPIPE() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try c.closeOutput(); try await c.write(stdioRequest())
        #expect(try await c.exit(readOutput:false) == 2)
        #expect(c.process.terminationReason == .exit)
        #expect(c.diagnostics.contains("active=0 requests=0 buffered=0 events=0"))
    }
    @Test func EOFDeadlineCancelsAndJoinsProvider() async throws {
        let c = try Child("uncooperative"); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest(fields:#", "name":"slow""#))
        try await c.waitDiagnostic("ENTERED slow")
        try c.closeInput(); #expect(try await c.exit() == 2)
        #expect(c.diagnostics.contains("drainDeadline"))
        #expect(c.diagnostics.contains("active=0 requests=0 buffered=0 events=0"))
        #expect(c.stdout.isEmpty)
    }
    @Test func queuedCancellationUsesExactIDsAndUnknownIDsDoNotPoisonReuse() async throws {
        let c = try Child("queued"); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest(id:"101",fields:#", "name":"slow""#)); try await c.waitDiagnostic("ENTERED slow")
        try await c.write(stdioRequest(id:"9007199254740993") + stdioCancel("9007199254740993e0") +
            stdioCancel("102") + stdioRequest(id:"102") + stdioCancel("101"))
        _ = try await c.frames(1); try c.closeInput()
        #expect(try await c.exit() == 0)
        let values = try c.stdout.split(separator:10).map { try parsed(Data($0)) }
        #expect(values.count == 1)
        try #require(values.count == 1)
        #expect(try values[0].objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 102)
    }
    @Test func concurrentResponsesRemainWholeAndFinishOutOfOrder() async throws {
        let c = try Child(); defer { c.cleanup() }
        try await c.waitDiagnostic("READY")
        try await c.write(stdioRequest(id:"201",fields:#", "name":"delay""#)); try await c.waitDiagnostic("ENTERED delay")
        try await c.write(stdioRequest(id:"202"))
        let frames = try await c.frames(2); try c.closeInput()
        #expect(try await c.exit() == 0)
        let values = try frames.map(parsed)
        #expect(try values[0].objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 202)
        #expect(try values[1].objectValue?["id"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 201)
        #expect(c.stdout.split(separator:10).count == 2)
    }
    @Test func ingressAndOutputOverflowReleaseAllAccounting() async throws {
        for mode in ["overflow","output-tiny"] {
            let c = try Child(mode)
            do {
                try await c.waitDiagnostic("READY")
                if mode == "overflow" {
                    try await c.write(stdioRequest(id:"301",fields:#", "name":"slow""#))
                    try await c.waitDiagnostic("ENTERED slow")
                    try await c.write(stdioRequest(id:"302") + stdioRequest(id:"303"))
                } else { try await c.write(stdioRequest()) }
                #expect(try await c.exit() == 2)
                #expect(c.stdout.isEmpty)
                #expect(c.diagnostics.contains("active=0 requests=0 buffered=0 events=0"))
            } catch { c.cleanup(); throw error }
            c.cleanup()
        }
    }
    @Test func idleReadDeadlineAndRepeatedSubprocessCleanup() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        for _ in 0..<8 {
            let c = try Child("idle")
            do { try await c.waitDiagnostic("READY"); #expect(try await c.exit() == 2); #expect(c.diagnostics.contains("readDeadline")) }
            catch { c.cleanup(); throw error }
            c.cleanup()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        #expect(after <= before + 1)
    }
}
