// SPDX-License-Identifier: Apache-2.0
import Foundation
import SystemPackage
import MCPProtocol
import MCPServer
import MCPStdio

/// Standalone process owner. Public transport owns its own workers; this host
/// awaits the sole run directly, never an unjoined or detached child task.
enum FixtureStdioHost {
    static func policy() throws -> StdioPolicy {
        try StdioPolicy(frameBytes: 65_536, outputFrameBytes: 131_072,
            chunkBytes: 4096, workers: 1, queuedFrames: 1,
            queuedBytes: 67_175_000, writerFrames: 2, writerBytes: 262_146,
            readIdleMilliseconds: 30_000, writeIdleMilliseconds: 5000,
            frameMilliseconds: 5000, drainMilliseconds: 5000)
    }
    static func run(server: Server, policy: StdioPolicy) async throws {
        // All argument/catalog/key/policy preparation precedes transfer. Do not
        // create FileHandle aliases or use stdout after this point in this mode.
        let input = FileDescriptor.standardInput, output = FileDescriptor.standardOutput
        let transport: StdioTransport
        do {
            transport = try StdioTransport(input: input, output: output,
                inputOwnership: .owned, outputOwnership: .owned, policy: policy)
        } catch {
            // Public contract: on constructor failure the originals stay ours.
            // Each close is attempted once, independently; never retry EINTR.
            var closeFailed = false
            do { try input.close() } catch { closeFailed = true }
            do { try output.close() } catch { closeFailed = true }
            await server.stopAdmission(); await server.closeSubscriptions()
            if closeFailed { diagnostic("WRE cleanup: original descriptor close failed.\n") }
            throw error
        }
        do {
            try await transport.run(server: server,
                principal: .init(subject: ScalarText("local-fixture"), issuer: ScalarText("wre-fixture-host"),
                                 resource: ScalarText("wre-stdio"), scopes: []),
                origin: ScalarText("wre-stdio"))
        } catch {
            // run's task-group scope and I/O workers have joined on this return.
            // Primary error remains primary; these public cleanup calls do not throw.
            await server.stopAdmission(); await server.closeSubscriptions(); transport.shutdown()
            throw error
        }
        await server.stopAdmission(); await server.closeSubscriptions(); transport.shutdown()
        let stats = transport.statistics, activity = await server.activity
        guard stats.phase == .stopped, stats.writerBytes == 0,
              activity.active == 0, activity.queued == 0, activity.requests == 0,
              activity.leases == 0, activity.bufferedBytes == 0,
              activity.subscriptions == 0, activity.eventBytes == 0 else { throw CoreFailure.invalidOutput }
    }
    static func diagnostic(_ literal: String) {
        // Callers pass only owned static messages. Never error descriptions,
        // adapter messages, tool input, paths, URLs or environment values.
        FileHandle.standardError.write(Data(literal.utf8))
    }
}
