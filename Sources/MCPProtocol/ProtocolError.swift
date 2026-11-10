// SPDX-License-Identifier: Apache-2.0
import JSON

public enum ProtocolErrorCode: Int64, Sendable {
    case parse = -32700, invalidRequest = -32600, methodNotFound = -32601
    case invalidParams = -32602, internalError = -32603, headerMismatch = -32020
    case missingCapability = -32021, unsupportedVersion = -32022
}
public enum ErrorEnvelope {
    /// D01: Unidentifiable requests use null, never a fabricated ID.
    /// Bounded generic construction is upstream-owned, outside wire parsing.
    public static func make(code: ProtocolErrorCode, id: RequestID?, limits: JSONLimits) throws -> JSONOperationReport<JSON> {
        let message: String
        switch code {
        case .parse: message = "Parse error"
        case .invalidRequest: message = "Invalid Request"
        case .methodNotFound: message = "Method not found"
        case .invalidParams: message = "Invalid params"
        case .internalError: message = "Internal error"
        case .headerMismatch: message = "HeaderMismatch"
        case .missingCapability, .unsupportedVersion: throw WireFailure.invalidParams
        }
        return try JSONValueEncoder(options: .init(limits: limits)).encodeWithReport(
            Envelope(id: id?.value ?? .null, error: Payload(code: code.rawValue, message: message)))
    }
    private struct Envelope: Encodable {
        let jsonrpc = "2.0"
        let id: JSON
        let error: Payload
    }
    private struct Payload: Encodable { let code: Int64; let message: String }
}

public enum ModernProtocolError: Sendable {
    case standard(ProtocolErrorCode)
    case resourceNotFound(uri: ScalarText)
    case unsupportedVersion(requested: ScalarText)
    case missingCapability(required: MCPWire.ClientCapabilities)
}
extension ErrorEnvelope {
    public static func make(_ error: ModernProtocolError, id: RequestID?, limits: JSONLimits) throws -> JSONOperationReport<JSON> {
        struct Version: Encodable { let requested: String; let supported = [ProtocolMetadata.version] }
        struct Required: Encodable { let requiredCapabilities: JSON }
        struct Resource: Encodable { let uri: String }
        struct Payload<Data: Encodable>: Encodable { let code: Int64; let message: String; let data: Data }
        struct Envelope<Data: Encodable>: Encodable { let jsonrpc = "2.0"; let id: JSON; let error: Payload<Data> }
        let encoder = JSONValueEncoder(options: .init(limits: limits))
        switch error {
        case .standard(let code): return try make(code: code, id: id, limits: limits)
        case .resourceNotFound(let uri):
            guard uri.description.utf8.count <= 4096 else { throw WireFailure.limit }
            return try encoder.encodeWithReport(Envelope(id: id?.value ?? .null,
                error: Payload(code: -32602, message: "Resource not found", data: Resource(uri: uri.description))))
        case .unsupportedVersion(let requested):
            guard requested.description.utf8.count <= 256 else { throw WireFailure.limit }
            return try encoder.encodeWithReport(Envelope(id: id?.value ?? .null,
                error: Payload(code: -32022, message: "UnsupportedProtocolVersion",
                               data: Version(requested: requested.description))))
        case .missingCapability(let required):
            return try encoder.encodeWithReport(Envelope(id: id?.value ?? .null,
                error: Payload(code: -32021, message: "MissingRequiredClientCapability",
                               data: Required(requiredCapabilities: required.value))))
        }
    }
}
