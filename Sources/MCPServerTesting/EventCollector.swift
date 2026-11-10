// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol
import MCPServer

/// Explicit multi-frame observation, independent of the one-response harness.
public actor EventCollector {
    private let maximumFrames: Int, maximumBytes: Int
    private var frames: [Data] = [], retained = 0
    public init(maximumFrames: Int = 128, maximumBytes: Int = 8388608) throws {
        guard maximumFrames > 0, maximumFrames <= 100000, maximumBytes > 0, maximumBytes <= 268435456 else { throw CoreFailure.invalidPolicy }
        self.maximumFrames = maximumFrames; self.maximumBytes = maximumBytes
    }
    public func record(_ bytes: Data) throws {
        guard frames.count < maximumFrames, bytes.count <= maximumBytes - retained else { throw CoreFailure.limit }
        frames.append(bytes); retained += bytes.count
    }
    public var snapshot: [Data] { frames }
    public func dispatch(_ request: Data, to server: Server, principal: VerifiedPrincipal, origin: ScalarText, mode: DeliveryMode) async throws {
        try await server.dispatchEvents(request,principal:principal,origin:origin,mode:mode) { try await self.record($0) }
    }
}
