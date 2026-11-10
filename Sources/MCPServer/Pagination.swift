// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import JSON
import MCPProtocol

public struct CursorContext: Sendable {
    public let principal: VerifiedPrincipal
    public let method: WireMethod
    public let parameters: JSON
    public let generation: UInt64
    public let catalogInstance: ScalarText
    public init(principal: VerifiedPrincipal, method: WireMethod, parameters: JSON, generation: UInt64, catalogInstance: ScalarText) {
        self.principal = principal; self.method = method; self.parameters = parameters
        self.generation = generation; self.catalogInstance = catalogInstance
    }
}
/// Purpose-separated authenticated encryption, limited to catalog pagination.
/// No replay/MRTR/exactly-once certification follows from this value.
public struct CursorProtector: Sendable {
    public struct Key: Sendable {
        public let identifier: ScalarText
        // Raw 32-byte key; SymmetricKey is created per operation (swift-crypto's is not Sendable).
        fileprivate let materialBytes: Data
        fileprivate var material: SymmetricKey { SymmetricKey(data: materialBytes) }
        public init(identifier: ScalarText, material: Data) throws {
            let bytes = identifier.description.utf8
            guard !bytes.isEmpty, bytes.count <= 32, bytes.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }), material.count == 32 else { throw CoreFailure.invalidPolicy }
            self.identifier = identifier; self.materialBytes = material
        }
    }
    private let keys: [Key]
    private let active: ScalarText
    private let epoch: ScalarText
    private let clock: @Sendable () -> Int64
    private let ttl: Int64
    private static let purpose = Data("Swift-MCP/catalog-cursor\0version=1\0binding=1\0".utf8)
    public init(keys: [Key], active: ScalarText, epoch: ScalarText = ScalarText(UUID().uuidString),
        ttlMilliseconds: Int64 = 300_000, clock: @escaping @Sendable () -> Int64) throws {
        guard !keys.isEmpty, keys.count <= 4, Set(keys.map(\.identifier)).count == keys.count,
              keys.contains(where: { $0.identifier == active }), !epoch.description.isEmpty, epoch.description.utf8.count <= 64,
              ttlMilliseconds > 0, ttlMilliseconds <= 3_600_000 else { throw CoreFailure.invalidPolicy }
        self.keys = keys; self.active = active; self.epoch = epoch; ttl = ttlMilliseconds; self.clock = clock
    }
    private struct Claims: Codable, Sendable {
        let version: Int
        let epoch: String
        let principal: String
        let method: String
        let parameters: String
        let generation: UInt64
        let catalog: String
        let expires: Int64
        let offset: Int
    }
    private func bindings(_ context: CursorContext, budget: RequestBudget) async throws -> (String, String) {
        guard context.catalogInstance.description.utf8.count <= 64, context.principal.scopes.count <= 256 else { throw CoreFailure.limit }
        struct Principal: Encodable {
            let issuer: String; let subject: String; let resource: String; let scopes: [String]
        }
        let principal = context.principal
        let input = Principal(issuer: principal.issuer.description, subject: principal.subject.description,
            resource: principal.resource.description, scopes: principal.scopes.sorted {
                $0.description.utf8.lexicographicallyPrecedes($1.description.utf8)
            }.map(\.description))
        let value = try await budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(input) }
        let principalDigest = try await ParameterBinding.digest(.value(value), budget: budget)
        let parameterDigest = try await ParameterBinding.digest(.value(context.parameters), budget: budget)
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        return (hex(principalDigest), hex(parameterDigest))
    }
    public func seal(offset: Int, context: CursorContext, budget: RequestBudget) async throws -> String {
        guard offset > 0, offset <= 100_000 else { throw CoreFailure.invalidCursor }
        let now = clock(), expiry = now.addingReportingOverflow(ttl)
        guard now >= 0, !expiry.overflow else { throw CoreFailure.invalidPolicy }
        let hashes = try await bindings(context, budget: budget)
        let claims = Claims(version: 1, epoch: epoch.description, principal: hashes.0, method: context.method.rawValue,
            parameters: hashes.1, generation: context.generation, catalog: context.catalogInstance.description,
            expires: expiry.partialValue, offset: offset)
        let value = try await budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(claims) }
        var limits = JSONLimits.balanced; limits[.outputBytes] = 640
        let data = try await budget.performJSON(limits: limits) { try WireCodec.write(value, limits: $0) }
        try await budget.consume(UInt64(data.count) * 16 + 1024)
        let key = keys.first { $0.identifier == active }!
        let aad = Self.purpose + Data(active.description.utf8)
        let box = try AES.GCM.seal(data, using: key.material, authenticating: aad)
        let token = "1." + active.description + "." + Self.base64URL(box.combined!)
        guard token.utf8.count <= 1024 else { await budget.terminate(); throw CoreFailure.limit }
        return token
    }
    public func open(_ token: String, context: CursorContext, budget: RequestBudget) async throws -> Int {
        guard !token.isEmpty, token.utf8.count <= 1024 else { throw CoreFailure.invalidCursor }
        try await budget.consume(UInt64(token.utf8.count) * 16 + 1024)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "1", let key = keys.first(where: { $0.identifier == ScalarText(String(parts[1])) }),
              let encoded = Self.decode64(String(parts[2])) else { throw CoreFailure.invalidCursor }
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: encoded), using: key.material,
                                         authenticating: Self.purpose + Data(key.identifier.description.utf8)) }
        catch { throw CoreFailure.invalidCursor }
        guard plaintext.count <= 640 else { throw CoreFailure.invalidCursor }
        let value = try await budget.performJSON { try WireCodec.parse(Array(plaintext), limits: $0) }
        let claims = try await budget.performJSON { try JSONValueDecoder(options: .init(limits: $0)).decodeWithReport(Claims.self, from: value) }
        let now = clock(), hashes = try await bindings(context, budget: budget)
        guard now >= 0, claims.version == 1, ScalarText(claims.epoch) == epoch,
              ScalarText(claims.principal) == ScalarText(hashes.0), ScalarText(claims.parameters) == ScalarText(hashes.1),
              claims.method == context.method.rawValue, claims.generation == context.generation,
              ScalarText(claims.catalog) == context.catalogInstance,
              claims.expires > now, claims.expires - now <= ttl,
              claims.offset > 0, claims.offset <= 100_000 else { throw CoreFailure.invalidCursor }
        return claims.offset
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func decode64(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }), text.utf8.count % 4 != 1 else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64URL(data).utf8.elementsEqual(text.utf8) else { return nil }
        return data
    }
}
