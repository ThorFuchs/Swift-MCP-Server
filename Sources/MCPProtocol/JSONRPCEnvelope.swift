// SPDX-License-Identifier: Apache-2.0
import JSON

public enum IncomingEnvelope: Sendable {
    case request(Request), cancellation(JSONObject)
    public struct Request: Sendable {
        public let raw: JSON
        public let id: RequestID
        public let method: ScalarText
        public let params: JSONObject
        public let version: ScalarText
        public let capabilities: JSONObject
    }
}
public enum WireFailure: Error, Sendable, Equatable {
    case invalidLimit, limit, invalidRequest, invalidParams, unsupportedVersion, forbiddenDirection
}

/// Bounded projection of the envelope only. Method-specific schemas are selected
/// by dispatch from the same frozen generation; this is not all-definition validation.
public enum EnvelopeProjection {
    /// Envelope recognition only: invalid notification payloads still receive
    /// no reply. Present-null IDs and invalid/non-message objects remain errors.
    /// The caller charges the bounded parsed message's lookup work.
    public static func isNotification(_ raw: JSON) -> Bool {
        guard let object = raw.objectValue else { return false }
        return object["jsonrpc"]?.stringValue?.utf8.elementsEqual("2.0".utf8) == true
            && object["method"]?.stringValue != nil && object["id"] == nil
            && object["result"] == nil && object["error"] == nil
    }
    public struct Report: Sendable {
        public let result: IncomingEnvelope
        public let workUnits: UInt64
    }
    public static func decode(_ raw: JSON, workUnits: UInt64 = 65_536) throws -> Report {
        var account = try ProjectionWork(workUnits)
        guard let object = raw.objectValue,
              try account.member("jsonrpc", in: object)?.stringValue == "2.0",
              let method = try account.member("method", in: object)?.stringValue,
              try account.member("result", in: object) == nil,
              try account.member("error", in: object) == nil else { throw WireFailure.invalidRequest }
        guard method.utf8.count <= 1024 else { throw WireFailure.limit }
        let params = try account.member("params", in: object)?.objectValue
        let idValue = try account.member("id", in: object)
        if idValue == nil {
            guard method.utf8.elementsEqual(WireMethod.cancelled.rawValue.utf8), let params,
                  let target = try account.member("requestId", in: params) else { throw WireFailure.forbiddenDirection }
            _ = try RequestID(target)
            if let reason = try account.member("reason", in: params), reason.stringValue == nil { throw WireFailure.invalidParams }
            return .init(result: .cancellation(params), workUnits: account.consumed)
        }
        let id = try RequestID(idValue!)
        if let known = WireMethod(rawValue: method), known.leg != .clientRequest { throw WireFailure.forbiddenDirection }
        guard let params, let meta = try account.member("_meta", in: params)?.objectValue,
              let version = try account.member(ProtocolMetadata.protocolVersion, in: meta)?.stringValue,
              let caps = try account.member(ProtocolMetadata.clientCapabilities, in: meta)?.objectValue else {
            throw WireFailure.invalidParams
        }
        guard version.utf8.elementsEqual(ProtocolMetadata.version.utf8) else { throw WireFailure.unsupportedVersion }
        return .init(result: .request(.init(raw: raw, id: id, method: ScalarText(method), params: params,
            version: ScalarText(version), capabilities: caps)), workUnits: account.consumed)
    }
}

/// Server-owned lookup charges examined bytes, including nonmatching unknown keys.
private struct ProjectionWork {
    private var remaining: UInt64
    private let total: UInt64
    var consumed: UInt64 { total - remaining }
    init(_ total: UInt64) throws {
        guard total > 0 else { throw WireFailure.invalidLimit }; self.total = total; remaining = total
    }
    mutating func member(_ name: String, in object: JSONObject) throws -> JSON? {
        for member in object {
            try Task.checkCancellation()
            let cost = UInt64(member.key.string.utf8.count) + UInt64(name.utf8.count) + 1
            guard cost <= remaining else { throw WireFailure.limit }; remaining -= cost
            if member.key.string.utf8.elementsEqual(name.utf8) { return member.value }
        }
        return nil
    }
}
