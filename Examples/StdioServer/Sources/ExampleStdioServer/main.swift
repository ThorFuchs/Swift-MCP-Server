// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import SystemPackage
import JSON
import MCPProtocol
import MCPServer
import MCPStdio
import MCPServiceLifecycle
import Logging
import ServiceLifecycle
import ExampleSupport

@main struct ExampleStdioServer {
    static func main() async {
        do {
            let server = try await ExampleCatalog.make(extensions: CommandLine.arguments.contains("--extensions"))
            let transport = try StdioTransport(input: .standardInput, output: .standardOutput, inputOwnership: .owned, outputOwnership: .owned,
                policy: .init(workers: 4, drainMilliseconds: 1000))
            // Deliberate host-owned development identity, never clientInfo authority.
            let principal = VerifiedPrincipal(subject: ScalarText("local-demo"), issuer: ScalarText("example-host"), resource: ScalarText("stdio-demo"), scopes: [])
            let stop = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let component = try TransportService(name: "stdio", run: { ready in
                try await ready()
                FileHandle.standardError.write(Data("EXAMPLE_READY stdio\n".utf8))
                do {
                    try await withThrowingTaskGroup(of: Void.self) { owned in
                        owned.addTask { try await transport.run(server: server, principal: principal, origin: ScalarText("example-stdio")) }
                        owned.addTask { for await _ in stop.stream { break } }
                        _ = try await owned.next(); owned.cancelAll()
                        do { try await owned.waitForAll() } catch is CancellationError { }
                    }
                } catch is CancellationError { }
            }, shutdown: { transport.shutdown(); stop.continuation.yield(()); stop.continuation.finish() })
            let runtime = try ServerService(server: server, components: [component])
            let logger = Logger(label: "example", factory: { _ in SwiftLogNoOpLogHandler() })
            var config = ServiceGroupConfiguration(services: [.init(service: runtime, successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .cancelGroup)], logger: logger)
            // Standalone executable choice only. Reusable products install none.
            config.gracefulShutdownSignals = [.sigterm, .sigint]
            config.maximumGracefulShutdownDuration = nil; config.maximumCancellationDuration = nil
            try await ServiceGroup(configuration: config).run()
            let report = await runtime.report, activity = await server.activity
            guard report.joined == 1, report.failure == nil, activity.active == 0, activity.requests == 0,
                  activity.bufferedBytes == 0, activity.eventBytes == 0, transport.statistics.writerBytes == 0 else { throw CoreFailure.invalidOutput }
            FileHandle.standardError.write(Data("EXAMPLE_STOPPED joined=1 active=0\n".utf8))
        } catch { FileHandle.standardError.write(Data("EXAMPLE_FAILED\n".utf8)); Darwin.exit(1) }
    }
}
