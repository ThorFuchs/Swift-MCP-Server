// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPServer
import ServiceContextModule

/// Host correlation is diagnostic data, never authentication or a metric label.
public struct DiagnosticCorrelation: Sendable, Equatable {
    public let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95,46].contains($0)
        }) else { throw InstrumentationFailure.invalidConfiguration }
        self.value = value
    }
    public init() { value = UUID().uuidString }
}
public struct DiagnosticTrace: Sendable {
    public let correlation: DiagnosticCorrelation
    public let request: DiagnosticRequest
    public static var current: DiagnosticTrace? { ServiceContext.current?[TraceKey.self] }
}
enum TraceKey: ServiceContextKey { typealias Value = DiagnosticTrace; static let nameOverride: String? = "mcp-diagnostic-trace" }

/// Host-controlled, task-scoped propagation of already validated metadata.
/// Values are not automatically logged/exported; baggage can contain private data.
public enum RequestTraceScope {
    public static var current: RequestTraceContext? { ServiceContext.current?[RequestTraceContextKey.self] }
    public static func withTrace<Value: Sendable>(_ request: RequestContext,
        operation: @Sendable () async throws -> Value) async rethrows -> Value {
        var context = ServiceContext.current ?? .topLevel
        // Setting nil clears any inherited trace for requests without metadata.
        context[RequestTraceContextKey.self] = request.traceContext
        return try await ServiceContext.withValue(context) { try await operation() }
    }
}
private enum RequestTraceContextKey: ServiceContextKey {
    typealias Value = RequestTraceContext
    static let nameOverride: String? = "mcp-validated-request-trace"
}
