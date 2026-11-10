// SPDX-License-Identifier: Apache-2.0
import MCPServer
import Logging

/// Fixed-field diagnostics. There is no raw payload/error/credential capture API.
/// Passing a correlation is explicit host consent to record that bounded value.
public struct RedactionPolicy: Sendable {
    public let recordCorrelation: Bool
    public init(recordCorrelation: Bool = false) { self.recordCorrelation = recordCorrelation }
    func metadata(_ request: DiagnosticRequest, outcome: DiagnosticOutcome?, correlation: DiagnosticCorrelation) -> Logger.Metadata {
        var value: Logger.Metadata = ["mcp.method": .string(request.method?.rawValue ?? "unknown"),
            "mcp.transport": .string(request.transport.rawValue)]
        if let outcome { value["mcp.outcome"] = .string(outcome.rawValue) }
        if recordCorrelation { value["mcp.correlation"] = .string(correlation.value) }
        return value
    }
}
