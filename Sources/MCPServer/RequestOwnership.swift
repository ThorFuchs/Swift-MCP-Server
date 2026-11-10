// SPDX-License-Identifier: Apache-2.0
import MCPProtocol
import JSON

struct PrincipalKey: Sendable, Hashable {
    let issuer: ScalarText
    let subject: ScalarText
    let resource: ScalarText
    init(_ principal: VerifiedPrincipal) { issuer = principal.issuer; subject = principal.subject; resource = principal.resource }
}
struct RequestKey: Sendable, Hashable {
    let principal: PrincipalKey
    let origin: ScalarText
    let id: ScalarText
    static func make(_ id: RequestID, principal: VerifiedPrincipal, origin: ScalarText, budget: RequestBudget) async throws -> Self {
        let text: ScalarText
        switch id {
        case .string(let value): text = ScalarText("s:" + value.description)
        case .integer(let number):
            var limits = JSONLimits.balanced
            for metric in [JSONResourceMetric.compileWorkUnits, .evaluationWorkUnits, .regexCompileWorkUnits, .aggregateRegexWorkUnits] { limits[metric] = 0 }
            text = try await budget.performUnreported(workUnits: 4096, limits: limits) {
                ScalarText("i:" + (try number.numericText(style: .normalized, limits: $0)))
            }
        }
        try await budget.consume(UInt64(text.description.utf8.count + origin.description.utf8.count + 1))
        return .init(principal: PrincipalKey(principal), origin: origin, id: text)
    }
}
actor RequestOwnership {
    let perPrincipal: Int
    private var requests: [RequestKey: RequestCancellation] = [:]
    private var counts: [PrincipalKey: Int] = [:]
    init(perPrincipal: Int) { self.perPrincipal = perPrincipal }
    func insert(_ key: RequestKey, cancellation: RequestCancellation) throws {
        guard requests[key] == nil else { throw CoreFailure.duplicate }
        guard counts[key.principal, default: 0] < perPrincipal else { throw AdmissionController.Failure.saturated }
        requests[key] = cancellation; counts[key.principal, default: 0] += 1
    }
    func remove(_ key: RequestKey) {
        guard requests.removeValue(forKey: key) != nil else { return }
        let count = counts[key.principal]! - 1
        if count == 0 { counts.removeValue(forKey: key.principal) } else { counts[key.principal] = count }
    }
    func cancel(_ key: RequestKey) { requests[key]?.cancel() }
    var activeCount: Int { requests.count }
}
