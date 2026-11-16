// SPDX-License-Identifier: Apache-2.0
import JSON

public enum ClientError: Error, Sendable, Equatable {
    /// A JSON-RPC error response. `-32021` carries `data.requiredCapabilities`.
    case server(code: Int, message: String, data: JSON?)
    /// A response or notification that is not valid for 2026-07-28.
    case invalidResponse(String)
    /// The server does not support protocol revision 2026-07-28.
    case unsupportedProtocol(supported: [String])
    /// The server asked for input (`method`) that no configured handler answers.
    case unsupportedInput(method: String)
    /// More input rounds than `ClientConfiguration.maximumInputRounds`.
    case tooManyInputRounds
    /// The exchange ended without a response.
    case noResponse
}

extension ClientError {
    /// JSON-RPC and MCP 2026-07-28 error codes, for matching `.server(code:...)`.
    public enum Code {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        /// `MissingRequiredClientCapabilityError`; `data.requiredCapabilities` names what is missing.
        public static let missingRequiredCapabilities = -32021
        /// `UnsupportedProtocolVersionError`; the client reports it as `.unsupportedProtocol`.
        public static let unsupportedProtocolVersion = -32022
    }

    /// The server's error code, for `.server` errors.
    public var serverCode: Int? { if case .server(let code, _, _) = self { return code }; return nil }

    /// The extensions a `-32021` error names in `data.requiredCapabilities.extensions`.
    public var requiredExtensions: [String] {
        guard case .server(Code.missingRequiredCapabilities, _, let data?) = self,
              let extensions = data.objectValue?["requiredCapabilities"]?.objectValue?["extensions"]?.objectValue else { return [] }
        return extensions.map { $0.key.string }
    }
}
