// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

/// Trusted registration, never inferred from a client's response keys.
public struct InputDescriptor: Sendable {
    public let identifier: ScalarText
    public let request: JSON
    public init(identifier: ScalarText, request: JSON) { self.identifier = identifier; self.request = request }
}
public struct InputInstruction: Sendable {
    public let inputs: [ScalarText]?
    public let state: JSONPresence<JSON>
    public let inputOnly: Bool
    public init(inputs: [ScalarText]? = nil, state: JSONPresence<JSON> = .absent, inputOnly: Bool = false) {
        self.inputs = inputs; self.state = state; self.inputOnly = inputOnly
    }
}
public enum ProviderOutcome: Sendable { case complete(JSON), inputRequired(InputInstruction), supplemental(JSON) }
public struct RoundInvocation: Sendable {
    public let state: JSONPresence<JSON>
    public let responses: JSONObject
    /// Independently admitted invocations, including incomplete retries.
    public let attempt: Int
    public let isRetry: Bool
    public let effect: ContinuationEffect?
}
public enum ContinuationReplayPolicy: Sendable {
    /// Integrity only. Replays may execute; counters do not impose global bounds.
    case integrityOnly
    /// Process/shared scope and durability are those of the supplied host store.
    case consuming(any ContinuationConsumption)
}
public struct MultiRoundProvider: Sendable {
    public let version: ScalarText
    public let inputs: [InputDescriptor]
    /// Explicit deterministic, static reconstruction for state-free retries.
    public let inputOnlyReconstruction: [ScalarText]?
    public let replay: ContinuationReplayPolicy
    let handler: @Sendable (JSONPresence<JSON>, RoundInvocation, RequestContext) async throws -> ProviderOutcome
    public init(version: ScalarText, inputs: [InputDescriptor] = [], inputOnlyReconstruction: [ScalarText]? = nil,
        replay: ContinuationReplayPolicy,
        handler: @escaping @Sendable (JSONPresence<JSON>, RoundInvocation, RequestContext) async throws -> ProviderOutcome) {
        self.version = version; self.inputs = inputs; self.inputOnlyReconstruction = inputOnlyReconstruction
        self.replay = replay; self.handler = handler
    }
}
