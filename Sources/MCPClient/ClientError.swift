// SPDX-License-Identifier: Apache-2.0
import JSON

public enum ClientError: Error, Sendable {
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
    /// The extensions a `-32021` error names in `data.requiredCapabilities.extensions`.
    public var requiredExtensions: [String] {
        guard case .server(-32021, _, let data?) = self,
              let extensions = data.objectValue?["requiredCapabilities"]?.objectValue?["extensions"]?.objectValue else { return [] }
        return extensions.map { $0.key.string }
    }
}
