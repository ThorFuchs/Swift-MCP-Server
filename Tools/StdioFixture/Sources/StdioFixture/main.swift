// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if CORE53_DIAGNOSTICS
import Dispatch
#endif
import JSON
import MCPProtocol
import MCPServer
import MCPStdio
import SystemPackage

@main struct Fixture {
    static func parse(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
    static func diagnostic(_ text: String) {
        #if CORE53_DIAGNOSTICS
        // Preserve the termination reason independently of the parent stderr-reader lifetime.
        if let directory = ProcessInfo.processInfo.environment["MCP_CORE53_TRACE_DIR"],
           ["START", "PREPARE_BEGIN", "PREPARE_END", "POLICY", "READY", "STOP", "CLEAN", "FAIL"].contains(where: { text.hasPrefix($0) }) {
            let pid = ProcessInfo.processInfo.processIdentifier
            let tick = DispatchTime.now().uptimeNanoseconds
            let line = "[core53-fixture] pid=\(pid) tick_ns=\(tick) event=\(text)\n"
            let file = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("fixture-\(pid)-\(tick)-\(UUID().uuidString).log")
            do { try Data(line.utf8).write(to: file, options: .atomic) }
            catch {
                FileHandle.standardError.write(Data("[core53-fixture] evidence.write.error \(error)\n".utf8))
            }
        }
        #endif
        try? FileHandle.standardError.write(contentsOf:Data((text+"\n").utf8))
    }
    static func main() async {
        // Application boundary only: explicitly test default SIGPIPE disposition.
        signal(SIGPIPE,SIG_DFL)
        #if CORE53_DIAGNOSTICS
        diagnostic("START")
        #endif
        do {
            let mode = CommandLine.arguments.dropFirst().first ?? "normal"
            let large = String(repeating:"x",count:131_072)
            let echo = ToolRegistration(definition:try parse(#"{"name":"echo","inputSchema":{"type":"object"}}"#)) { _,context in
                try context.checkCancellation()
                return try parse(#"{"resultType":"complete","content":[{"type":"text","text":"世界\nhello"}]}"#)
            }
            let delayed = ToolRegistration(definition:try parse(#"{"name":"delay","inputSchema":{"type":"object"}}"#)) { _,_ in
                diagnostic("ENTERED delay"); try await Task.sleep(for:.milliseconds(200))
                return try parse(#"{"resultType":"complete","content":[]}"#)
            }
            let slow = ToolRegistration(definition:try parse(#"{"name":"slow","inputSchema":{"type":"object"}}"#)) { _,context in
                diagnostic("ENTERED slow")
                if mode == "uncooperative" { try? await Task.sleep(for:.milliseconds(250)) }
                else {
                    while true { try context.checkCancellation(); try await Task.sleep(for:.milliseconds(10)) }
                }
                try context.checkCancellation()
                return try parse(#"{"resultType":"complete","content":[]}"#)
            }
            let big = ToolRegistration(definition:try parse(#"{"name":"big","inputSchema":{"type":"object"}}"#)) { _,_ in
                diagnostic("ENTERED big")
                return try parse(#"{"resultType":"complete","content":[{"type":"text","text":""# + large + #""}]}"#)
            }
            let publish = ToolRegistration(definition:try parse(#"{"name":"publish","inputSchema":{"type":"object"}}"#)) { _,context in
                try await context.progress(JSONNumber(parsing:"0.25"))
                return try parse(#"{"resultType":"complete","content":[]}"#)
            }
            let cursor = try CursorProtector(keys:[.init(identifier:ScalarText("fixture"),material:Data(repeating:7,count:32))],
                active:ScalarText("fixture"),clock:{1000})
            #if CORE53_DIAGNOSTICS
            diagnostic("PREPARE_BEGIN")
            #endif
            let server = try await Server.make(info:parse(#"{"name":"stdio-fixture","version":"1"}"#),
                catalog:ServerCatalog(tools:[echo,slow,big,publish,delayed]),cursors:cursor,
                configuration:ServerConfiguration(activeRequests:4,queuedRequests:4,requestsPerPrincipal:4,terminalWork:900_000,deadlineMilliseconds:10_000,bufferedBytes:33_554_432))
            #if CORE53_DIAGNOSTICS
            diagnostic("PREPARE_END")
            #endif
            let policy: StdioPolicy
            switch mode {
            case "tiny": policy = try .init(frameBytes:128,chunkBytes:7,queuedBytes:128)
            case "stalled": policy = try .init(writerBytes:1_048_576,writeIdleMilliseconds:150,drainMilliseconds:5000)
            case "saturated": policy = try .init(workers:4,queuedFrames:4,queuedBytes:1_048_576,drainMilliseconds:500)
            case "queued": policy = try .init(workers:1,drainMilliseconds:500)
            case "overflow": policy = try .init(workers:1,queuedFrames:1,queuedBytes:1_048_576,drainMilliseconds:500)
            case "output-tiny": policy = try .init(writerBytes:128,drainMilliseconds:500)
            case "idle": policy = try .init(readIdleMilliseconds:100,frameMilliseconds:100,drainMilliseconds:100)
            case "uncooperative": policy = try .init(drainMilliseconds:50)
            default: policy = try .init(chunkBytes:7,workers:4,drainMilliseconds:500)
            }
            #if CORE53_DIAGNOSTICS
            diagnostic("POLICY readIdleMilliseconds=\(policy.readIdleMilliseconds) frameMilliseconds=\(policy.frameMilliseconds) writeIdleMilliseconds=\(policy.writeIdleMilliseconds) drainMilliseconds=\(policy.drainMilliseconds)")
            #endif
            let transport = try StdioTransport(input:.standardInput,output:.standardOutput,
                inputOwnership:.owned,outputOwnership:.owned,policy:policy)
            diagnostic("READY")
            let principal = VerifiedPrincipal(subject:ScalarText("fixture"),issuer:ScalarText("host"),resource:ScalarText("stdio"),scopes:[])
            do { try await transport.run(server:server,principal:principal,origin:ScalarText("owned-subprocess")) }
            catch {
                let activity = await server.activity
                diagnostic("STOP \(String(describing:error)) active=\(activity.active) requests=\(activity.requests) buffered=\(activity.bufferedBytes) events=\(activity.eventBytes)")
                exit(2)
            }
            let stats = transport.statistics, activity = await server.activity
            diagnostic("CLEAN frames=\(stats.deliveredFrames) writer=\(stats.writerBytes) active=\(activity.active) requests=\(activity.requests) buffered=\(activity.bufferedBytes) events=\(activity.eventBytes)")
        } catch { diagnostic("FAIL \(String(describing:error))"); exit(3) }
    }
}
