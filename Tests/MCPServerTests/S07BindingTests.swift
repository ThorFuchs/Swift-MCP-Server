// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer

private func s07BoundRequest(_ method: String, fields: String, id: String = "1", capabilities: String = "{}", metadata: String = "") throws -> IncomingEnvelope.Request {
    let raw = try JSONParser().parseWithReport(Array(StateFixture.request(method, fields: fields, id: id, capabilities: capabilities, metadata: metadata))).result
    guard case .request(let request) = try EnvelopeProjection.decode(raw).result else { throw WireFailure.invalidRequest }
    return request
}
private func s07Digest(_ text: String) async throws -> [UInt8] {
    try await ParameterBinding.digest(.value(StateFixture.json(text)), budget: RequestBudget(workUnits: 1_000_000))
}

@Suite struct S07ParameterBinding {
    @Test func rootRouteRetainsTheExistingBindingV1GoldenAndPresenceTags() async throws {
        // Exact retained consumer golden, now also asserted on the root SDK
        // route. No new encoding, algorithm, version or JCS claim is made.
        let first = try await s07Digest(#"{"é":100,"e\u0301":[-0,true,null]}"#)
        let equivalent = try await s07Digest(#"{"e\u0301":[0.0,true,null],"é":1e2}"#)
        #expect(first == equivalent && ParameterBinding.version == 1)
        #expect(first.map { String(format: "%02x", $0) }.joined() == "b03a3546d329d5d0cdbeb9e0d01a6b63bc3cc50f040a71eea142b549d0ada13c")
        let ordered = try await s07Digest(#"[1,2]"#), reversed = try await s07Digest(#"[2,1]"#)
        #expect(ordered != reversed)
        let composed = try await s07Digest(#""é""#), decomposed = try await s07Digest(#""e\u0301""#)
        #expect(composed != decomposed)
        let number = try await s07Digest("1"), string = try await s07Digest(#""1""#)
        #expect(number != string)
        let absent = try await ParameterBinding.digest(.absent, budget: RequestBudget(workUnits: 1000))
        let null = try await ParameterBinding.digest(.null, budget: RequestBudget(workUnits: 1000))
        let valueNull = try await ParameterBinding.digest(.value(.null), budget: RequestBudget(workUnits: 1000))
        #expect(absent != null && null == valueNull)
    }

    @Test(arguments: ["tools/call", "resources/read", "prompts/get"])
    func coreRetryProjectionBindsOriginalParametersAndExcludesRoundMetadata(method: String) async throws {
        let resource = method == "resources/read"
        let identity = resource ? #""uri":"fixture://r""# : #""name":"round""#
        let originalArguments = method == "prompts/get" ? #"{"n":"1000"}"# : #"{"n":1000}"#
        let retryArguments = method == "prompts/get" ? originalArguments : #"{"n":1e3}"#
        let first = try s07BoundRequest(method, fields: ",\(identity),\"arguments\":\(originalArguments)")
        let retry = try s07BoundRequest(method, fields: ",\(identity),\"arguments\":\(retryArguments),\"requestState\":\"opaque\",\"inputResponses\":{},\"unrelated\":99",
            id: "2", capabilities: #"{"roots":{}}"#, metadata: #", "com.example/retry":"untrusted data""#)
        let changedIdentity = resource ? #""uri":"fixture://other""# : #""name":"other""#
        let changed = try s07BoundRequest(method, fields: ",\(changedIdentity),\"arguments\":\(originalArguments)", id: "3")
        let a = try await ParameterBinding.forRequest(first, budget: RequestBudget(workUnits: 8_000_000))
        let b = try await ParameterBinding.forRequest(retry, budget: RequestBudget(workUnits: 8_000_000))
        let c = try await ParameterBinding.forRequest(changed, budget: RequestBudget(workUnits: 8_000_000))
        #expect(a == b && a != c)
        let omitted = try s07BoundRequest(method, fields: ",\(identity)", id: "4")
        let explicitNull = try s07BoundRequest(method, fields: ",\(identity),\"arguments\":null", id: "5")
        let x = try await ParameterBinding.forRequest(omitted, budget: RequestBudget(workUnits: 8_000_000))
        let y = try await ParameterBinding.forRequest(explicitNull, budget: RequestBudget(workUnits: 8_000_000))
        #expect((x == y) == resource)
        // Binding is not request validation or authority: the dispatcher still
        // validates method-specific params/capabilities and verifies state.
    }

    @Test func failedBindingCannotReplenishOrReuseTheSameAccount() async throws {
        let budget = try RequestBudget(workUnits: 1_000_000)
        let value = JSON.string(String(repeating: "x", count: 128))
        await #expect(throws: JSONFailure.self) {
            _ = try await ParameterBinding.digest(.value(value), budget: budget, maximumBytes: 64)
        }
        let failed = await budget.snapshot
        #expect(failed.isTerminal && failed.activeReservations == 0 && failed.terminalTransitions == 1)
        await #expect(throws: RequestBudget.Failure.exhausted) {
            _ = try await ParameterBinding.digest(.null, budget: budget)
        }
        #expect(await budget.snapshot.remaining == 0)
        #expect(await budget.snapshot.terminalTransitions == 1)
    }
}
