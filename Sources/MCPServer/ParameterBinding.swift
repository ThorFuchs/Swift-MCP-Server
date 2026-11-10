// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import JSON
import MCPProtocol

/// Version 1 is a frozen semantic encoding for parameter binding, not JCS.
/// Scalar-key order, normalized exact decimal coefficients/exponents, compact
/// upstream escaping, ordered arrays, and explicit absent/null/value tags.
public enum ParameterBinding {
    public static let version: UInt32 = 1
    /// Bind the original semantic parameters of the three MRTR methods. A retry
    /// changes its ID, metadata, inputResponses and requestState; unrelated extra
    /// params are ignored by the frozen protocol. State protection separately
    /// authenticates the principal/purpose/expiry and current capabilities.
    public static func forRequest(_ request: IncomingEnvelope.Request, budget: RequestBudget) async throws -> [UInt8] {
        do {
            guard let method = WireMethod(rawValue: request.method.description), method.permitsInputRequired,
                  let identityField = method.mirroredNameField else { throw WireFailure.forbiddenDirection }
            for member in request.params {
                try await budget.consume(UInt64(member.key.string.utf8.count + 1))
            }
            guard let identity = request.params[identityField], identity.stringValue != nil else { throw WireFailure.invalidParams }
            let arguments = method == .readResource ? nil : request.params["arguments"]
            var limits = JSONLimits.balanced
            limits[.numericWorkUnits] = 65_536
            for metric in [JSONResourceMetric.compileWorkUnits, .evaluationWorkUnits, .regexCompileWorkUnits, .aggregateRegexWorkUnits] { limits[metric] = 0 }
            let projection = try await budget.performUnreported(workUnits: 1_000_000, limits: limits) { supplied in
                var members = [JSONMember("method", value: .string(method.rawValue)), JSONMember(identityField, value: identity)]
                if let arguments { members.append(JSONMember("arguments", value: arguments)) }
                return JSON.object(try JSONObject(members: members, limits: supplied))
            }
            return try await digest(.value(projection), budget: budget)
        } catch { await budget.terminate(); throw error }
    }
    /// Supplemental MRTR binds all application parameters and the exact current
    /// namespace settings. Core binding-v1 projections/goldens stay unchanged.
    static func forSupplementalRequest(_ request: IncomingEnvelope.Request, context: RequestContext) async throws -> [UInt8] {
        let original = try await RuntimeJSON.object(request.params.filter {
            !["_meta", "requestState", "inputResponses"].contains($0.key.string)
        }, budget: context.budget)
        guard let namespace = context.method.extensionNamespace, let settings = context.extensions[namespace.description] else { throw CoreFailure.missingCapability }
        let projection = try await RuntimeJSON.object([.init("method", value: .string(context.method.rawValue)),
            .init("parameters", value: original), .init("extension", value: .string(namespace.description)),
            .init("settings", value: settings)], budget: context.budget)
        return try await digest(.value(projection), budget: context.budget)
    }
    public static func digest(_ presence: JSONPresence<JSON>, budget: RequestBudget,
                              maximumBytes: Int = 262_144) async throws -> [UInt8] {
        do {
            guard maximumBytes > 0 else { throw RequestBudget.Failure.invalidLimit }
            try Task.checkCancellation()
            var bytes = Array("Swift-MCP/parameter-binding\0".utf8) + [0, 0, 0, 1]
            switch presence {
            case .absent: bytes.append(0)
            case .null, .value(.null): bytes.append(1)
            case .value(let value):
                bytes.append(2)
                var limits = JSONLimits.balanced
                limits[.outputBytes] = UInt64(maximumBytes)
                let output = try await budget.performJSON(limits: limits) {
                    try JSONWriter(options: .init(limits: $0, keyOrder: .scalar, numberStyle: .normalized)).writeWithReport(value)
                }
                bytes.append(contentsOf: output)
            }
            guard bytes.count <= maximumBytes else { throw RequestBudget.Failure.exhausted }
            // Copy/hash input is server-owned, byte-bounded and charged separately.
            try await budget.consume(UInt64(bytes.count))
            try Task.checkCancellation()
            let result = Array(SHA256.hash(data: Data(bytes)))
            try Task.checkCancellation()
            return result
        } catch { await budget.terminate(); throw error }
    }
}
