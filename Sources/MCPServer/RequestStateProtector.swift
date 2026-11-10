// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import JSON
import MCPProtocol

public struct ContinuationPolicy: Sendable {
    public let maximumAttempts: Int, maximumInputs: Int, maximumTokenBytes: Int, maximumStateBytes: Int
    public let lifetimeMilliseconds: Int64, maximumChainWork: UInt64
    public init(maximumAttempts: Int = 16, maximumInputs: Int = 16, maximumTokenBytes: Int = 32768,
        maximumStateBytes: Int = 16384, lifetimeMilliseconds: Int64 = 600000, maximumChainWork: UInt64 = 1024000000) throws {
        guard maximumAttempts > 0, maximumAttempts <= 64, maximumInputs > 0, maximumInputs <= 64,
              maximumTokenBytes >= 1024, maximumTokenBytes <= 131072,
              maximumStateBytes > 0, maximumStateBytes <= maximumTokenBytes / 2,
              lifetimeMilliseconds > 0, lifetimeMilliseconds <= 3600000, maximumChainWork > 0,
              maximumChainWork <= 32768000000 else { throw CoreFailure.invalidPolicy }
        self.maximumAttempts = maximumAttempts; self.maximumInputs = maximumInputs; self.maximumTokenBytes = maximumTokenBytes
        self.maximumStateBytes = maximumStateBytes; self.lifetimeMilliseconds = lifetimeMilliseconds; self.maximumChainWork = maximumChainWork
    }
}
struct ContinuationClaims: Codable, Sendable {
    let version: Int, bindingVersion: Int
    let namespace: String, epoch: String, principal: String, method: String, parameters: String, plan: String
    let issued: Int64, expires: Int64
    var attempts: Int, spent: UInt64, logicalRound: Int
    let maximumAttempts: Int, maximumWork: UInt64
    let chain: String
    var priorID: String, pending: [String], responses: JSON, state: JSON
    var statePresence: Int
}
/// Portable host namespace/epoch and stable plans, independent of connections,
/// discovery, local generations and cursor instances. Integrity is not single-use.
public struct RequestStateProtector: Sendable {
    public struct Key: Sendable {
        public let identifier: ScalarText
        // Raw 32-byte key; SymmetricKey is created per operation (swift-crypto's is not Sendable).
        let materialBytes: Data
        var material: SymmetricKey { SymmetricKey(data: materialBytes) }
        public init(identifier: ScalarText, material: Data) throws {
            guard !identifier.description.isEmpty, identifier.description.utf8.count <= 64,
                  identifier.description.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }), material.count == 32 else { throw CoreFailure.invalidPolicy }
            self.identifier = identifier; self.materialBytes = material
        }
    }
    private let keys: [Key], active: ScalarText
    let namespace: ScalarText, epoch: ScalarText
    public let policy: ContinuationPolicy
    let clock: @Sendable () -> Int64
    private static let purpose = Data("Swift-MCP/continuation\0version=1\0binding=1\0".utf8)
    public init(keys: [Key], active: ScalarText, namespace: ScalarText, epoch: ScalarText,
        policy: ContinuationPolicy? = nil, clock: @escaping @Sendable () -> Int64) throws {
        guard !keys.isEmpty, keys.count <= 4, Set(keys.map(\.identifier)).count == keys.count,
              keys.contains(where: { $0.identifier == active }),
              [namespace, epoch].allSatisfy({ !$0.description.isEmpty && $0.description.utf8.count <= 256 }) else { throw CoreFailure.invalidPolicy }
        self.keys = keys; self.active = active; self.namespace = namespace; self.epoch = epoch
        self.policy = try policy ?? ContinuationPolicy(); self.clock = clock
    }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    func principalBinding(_ principal: VerifiedPrincipal, budget: RequestBudget) async throws -> String {
        let value = try await RuntimeJSON.object([.init("issuer", value: .string(principal.issuer.description)),
            .init("subject", value: .string(principal.subject.description)), .init("resource", value: .string(principal.resource.description))], budget: budget)
        return Self.hex(try await ParameterBinding.digest(.value(value), budget: budget))
    }
    func seal(_ claims: ContinuationClaims, budget: RequestBudget) async throws -> String {
        try validate(claims)
        var limits = JSONLimits.balanced; limits[.outputBytes] = UInt64(policy.maximumTokenBytes / 2)
        let value = try await budget.performJSON(limits: limits) { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(claims) }
        let bytes = try await budget.performJSON(limits: limits) { try WireCodec.write(value, limits: $0) }
        // Successful CryptoKit/hash/copy work has no JSON report: a finite
        // conservative server allowance is consumed in full before execution.
        try await budget.consume(UInt64(bytes.count) * 32 + 4096)
        let key = keys.first { $0.identifier == active }!
        let box = try AES.GCM.seal(bytes, using: key.material, authenticating: Self.purpose + Data(active.description.utf8))
        guard let combined = box.combined else { throw CoreFailure.invalidState }
        let token = "c1." + active.description + "." + Self.encode(combined)
        guard token.utf8.count <= policy.maximumTokenBytes else { throw CoreFailure.limit }
        return token
    }
    func open(_ token: String, budget: RequestBudget) async throws -> ContinuationClaims {
        guard !token.isEmpty, token.utf8.count <= policy.maximumTokenBytes else { throw CoreFailure.invalidState }
        try await budget.consume(UInt64(token.utf8.count) * 32 + 4096)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c1", let key = keys.first(where: { $0.identifier == ScalarText(String(parts[1])) }),
              let encoded = Self.decode(String(parts[2])), encoded.count <= policy.maximumTokenBytes else { throw CoreFailure.invalidState }
        let data: Data
        do { data = try AES.GCM.open(AES.GCM.SealedBox(combined: encoded), using: key.material,
            authenticating: Self.purpose + Data(key.identifier.description.utf8)) }
        catch { throw CoreFailure.invalidState }
        guard data.count <= policy.maximumTokenBytes / 2 else { throw CoreFailure.invalidState }
        var limits = JSONLimits.balanced; limits[.inputBytes] = UInt64(policy.maximumTokenBytes / 2)
        do {
            let raw = try await budget.performJSON(limits: limits) { try WireCodec.parse(Array(data), limits: $0) }
            let claims = try await budget.performJSON(limits: limits) { try JSONValueDecoder(options: .init(limits: $0)).decodeWithReport(ContinuationClaims.self, from: raw) }
            try validate(claims); return claims
        } catch let failure as JSONFailure where failure.category != .resource && failure.category != .configuration {
            throw CoreFailure.invalidState
        } catch is DecodingError {
            throw CoreFailure.invalidState
        }
    }
    private func validate(_ c: ContinuationClaims) throws {
        let now = clock()
        guard now >= 0, c.version == 1, c.bindingVersion == 1, ScalarText(c.namespace) == namespace, ScalarText(c.epoch) == epoch,
              c.issued >= 0, c.issued <= now, c.expires > now, c.expires > c.issued,
              c.expires - c.issued <= policy.lifetimeMilliseconds,
              c.maximumAttempts > 0, c.maximumAttempts <= policy.maximumAttempts, c.attempts > 0, c.attempts <= c.maximumAttempts,
              c.maximumWork > 0, c.maximumWork <= policy.maximumChainWork, c.spent <= c.maximumWork,
              c.logicalRound > 0, c.logicalRound <= c.attempts, c.pending.count <= policy.maximumInputs,
              Set(c.pending.map(ScalarText.init)).count == c.pending.count,
              c.pending.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }), c.chain.utf8.count == 36,
              c.statePresence >= 0, c.statePresence <= 2,
              [c.principal,c.parameters,c.plan,c.priorID].allSatisfy({ $0.utf8.count == 64 }) else { throw CoreFailure.invalidState }
    }
    private static func encode(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func decode(_ s: String) -> Data? {
        guard !s.isEmpty, s.utf8.count % 4 != 1, s.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let padded = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - s.utf8.count % 4) % 4)
        guard let d = Data(base64Encoded: padded), encode(d).utf8.elementsEqual(s.utf8) else { return nil }; return d
    }
}
