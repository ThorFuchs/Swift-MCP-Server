// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

private func restoredProtection(_ policy: ContinuationPolicy? = nil) throws -> RequestStateProtector {
    try .init(keys: [.init(identifier: ScalarText("one"), material: Data(repeating: 11, count: 32))],
        active: ScalarText("one"), namespace: ScalarText("restoration"), epoch: ScalarText("epoch"), policy: policy, clock: { 1000 })
}
private func restoredServer(_ provider: MultiRoundProvider, protection: RequestStateProtector) async throws -> Server {
    try await Server.make(info: StateFixture.json(#"{"name":"restored-rounds","version":"1"}"#),
        catalog: ServerCatalog(tools: [.init(definition: StateFixture.json(#"{"name":"round","inputSchema":{"type":"object"}}"#), rounds: provider)]),
        cursors: StateFixture.cursors(), continuations: protection)
}
private func restoredToken(_ value: JSON) throws -> String {
    try #require(value.objectValue?["result"]?.objectValue?["requestState"]?.stringValue)
}
private func restoredCode(_ value: JSON) -> Int? {
    try? value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced)
}
@Suite(.serialized) struct RestorationContinuationBoundaries {
    @Test func missingInputsSpendIndependentAttemptAndChainWorkLimits() async throws {
        let resumed = Mutex(0)
        let descriptor = InputDescriptor(identifier: ScalarText("roots"), request: try StateFixture.json(#"{"method":"roots/list"}"#))
        let provider = MultiRoundProvider(version: ScalarText("1"), inputs: [descriptor], replay: .integrityOnly) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(inputs: [descriptor.identifier], state: .null)) }
            resumed.withLock { $0 += 1 }
            return .complete(try StateFixture.json(#"{"resultType":"complete","content":[]}"#))
        }
        // Default requestWork is64M. The second profile permits many attempts,
        // but only two independently admitted accounts in its authenticated chain.
        for (policy, admittedAccounts) in [(try ContinuationPolicy(maximumAttempts: 3, maximumInputs: 1), 3),
                (try ContinuationPolicy(maximumAttempts: 16, maximumInputs: 1, maximumChainWork: 128_000_000), 2)] {
            let server = try await restoredServer(provider, protection: restoredProtection(policy))
            let initial = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"round""#, capabilities: #"{"roots":{}}"#))
            var token = try restoredToken(initial)
            for id in 2...admittedAccounts {
                let next = try await StateFixture.response(server, StateFixture.request("tools/call", fields: ",\"name\":\"round\",\"requestState\":\"\(token)\",\"inputResponses\":{}", id: String(id), capabilities: #"{"roots":{}}"#))
                #expect(next.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "input_required")
                token = try restoredToken(next)
                await StateFixture.clean(server)
            }
            let exhausted = try await StateFixture.response(server, StateFixture.request("tools/call", fields: ",\"name\":\"round\",\"requestState\":\"\(token)\",\"inputResponses\":{}", id: String(admittedAccounts + 1), capabilities: #"{"roots":{}}"#))
            #expect(restoredCode(exhausted) == -32602)
            #expect(resumed.withLock { $0 } == 0)
            await StateFixture.clean(server)
        }
    }

    @Test func prepaidReleaseSurvivesTerminatedMainAccount() async throws {
        let store = try StateConsumptionStore(maximumEntries: 1, maximumBytes: 512, maximumKeyBytes: 64, now: { 1000 })
        let released = Mutex(false)
        let provider = MultiRoundProvider(version: ScalarText("cleanup"), replay: .consuming(store)) { _, round, context in
            if !round.isRetry { return .inputRequired(.init(state: .null)) }
            await context.budget.terminate()
            try await round.effect?.releaseForSafeRetry()
            released.withLock { $0 = true }
            throw CoreFailure.invalidOutput
        }
        let server = try await restoredServer(provider, protection: restoredProtection())
        let token = try restoredToken(await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"round""#)))
        do {
            let result = try await StateFixture.response(server, StateFixture.request("tools/call", fields: ",\"name\":\"round\",\"requestState\":\"\(token)\"", id: "2"))
            #expect(result.objectValue?["result"] == nil)
        } catch { #expect(error is CoreFailure || error is RequestBudget.Failure) }
        #expect(released.withLock { $0 })
        let retainedCount = await store.count, retainedBytes = await store.retainedBytes
        #expect(retainedCount == 0 && retainedBytes == 0)
        await StateFixture.clean(server)
    }

    @Test func unchangedVersionWithChangedCoreFormPlanRejectsBeforeResume() async throws {
        let effects = Mutex(0)
        func provider(minimum: Int) throws -> MultiRoundProvider {
            let descriptor = InputDescriptor(identifier: ScalarText("form"), request: try StateFixture.json("{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"form\",\"message\":\"Count\",\"requestedSchema\":{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\",\"minimum\":\(minimum)}}}}}"))
            return MultiRoundProvider(version: ScalarText("unchanged"), inputs: [descriptor], replay: .integrityOnly) { _, round, _ in
                if !round.isRetry { return .inputRequired(.init(inputs: [descriptor.identifier], state: .null)) }
                effects.withLock { $0 += 1 }
                return .complete(try StateFixture.json(#"{"resultType":"complete","content":[]}"#))
            }
        }
        let protector = try restoredProtection()
        let issuer = try await restoredServer(provider(minimum: 1), protection: protector)
        let changed = try await restoredServer(provider(minimum: 2), protection: protector)
        let compatible = try await restoredServer(provider(minimum: 1), protection: protector)
        let capabilities = #"{"elicitation":{"form":{}}}"#
        let token = try restoredToken(await StateFixture.response(issuer, StateFixture.request("tools/call", fields: #", "name":"round", "arguments":{"n":1e0}"#, capabilities: capabilities)))
        let fields = ",\"name\":\"round\",\"arguments\":{\"n\":1.0},\"requestState\":\"\(token)\",\"inputResponses\":{\"form\":{\"action\":\"accept\",\"content\":{\"count\":1}}}"
        let refused = try await StateFixture.response(changed, StateFixture.request("tools/call", fields: fields, id: "2", capabilities: capabilities))
        #expect(restoredCode(refused) == -32602 && effects.withLock { $0 } == 0)
        let complete = try await StateFixture.response(compatible, StateFixture.request("tools/call", fields: fields, id: "3", capabilities: capabilities))
        #expect(complete.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
        #expect(effects.withLock { $0 } == 1)
        await StateFixture.clean(issuer); await StateFixture.clean(changed); await StateFixture.clean(compatible)
    }
}
