// SPDX-License-Identifier: Apache-2.0
import MCPProtocol

public enum DiagnosticTransport: String, Sendable, CaseIterable { case inProcess, stdio, http }
public enum DiagnosticOutcome: String, Sendable, CaseIterable {
    case completed, protocolError, cancelled, deadline, rejected, limit, disconnected, failed
}
/// Fixed classifications and already verified identity. No request ID, metadata,
/// payload, state or credentials are provided to the diagnostic backend.
public struct DiagnosticRequest: Sendable {
    public let method: WireMethod?
    public let transport: DiagnosticTransport
    public let principal: VerifiedPrincipal
    public init(method: WireMethod?, transport: DiagnosticTransport, principal: VerifiedPrincipal) {
        self.method = method; self.transport = transport; self.principal = principal
    }
}
/// Opt-in host facade. Must execute operation exactly once, propagate its failure
/// and cooperate with cancellation. The core enforces single invocation; diagnostics
/// cannot replace authority, settle JSON work or synthesize a wire response.
public protocol ServerRequestInstrumentation: Sendable {
    func withRequest(_ request: DiagnosticRequest,
        operation: @escaping @Sendable () async throws -> DiagnosticOutcome) async throws
}
