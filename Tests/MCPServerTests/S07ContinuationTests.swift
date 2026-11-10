// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

private func s07cProtector() throws -> RequestStateProtector {
    try .init(keys: [.init(identifier: ScalarText("s07"), material: Data(repeating: 13, count: 32))],
        active: ScalarText("s07"), namespace: ScalarText("s07-tests"), epoch: ScalarText("1"), clock: { 1000 })
}
private func s07cServer(_ provider: MultiRoundProvider, scopes: Set<ScalarText> = []) async throws -> Server {
    let tool = ToolRegistration(definition: try StateFixture.json(#"{"name":"round","inputSchema":{"type":"object"}}"#), requiredScopes: scopes, rounds: provider)
    return try await Server.make(info: StateFixture.json(#"{"name":"s07-rounds","version":"1"}"#),
        catalog: ServerCatalog(tools: [tool]), cursors: StateFixture.cursors(), continuations: s07cProtector())
}
private func s07cComplete() throws -> JSON { try StateFixture.json(#"{"resultType":"complete","content":[]}"#) }
private func s07cToken(_ value: JSON) throws -> String {
    try #require(value.objectValue?["result"]?.objectValue?["requestState"]?.stringValue)
}
private func s07cRetry(_ token: String, id: String, caps: String = "{}", fields: String = "") throws -> Data {
    let quoted = String(decoding: try WireCodec.write(.string(token), limits: .balanced).result, as: UTF8.self)
    return StateFixture.request("tools/call", fields: #", "name":"round","requestState":"# + quoted + fields, id: id, capabilities: caps)
}
private func s07cCode(_ value: JSON) throws -> Int? {
    try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced)
}

// Deliberately failing host settlement fixture. Its held row stays unresolved;
// neither an SDK response nor a caught callback error is evidence of release.
private actor S07SettlementProbe: ContinuationConsumption {
    enum Failure: Error, Equatable { case refusedRelease, unexpectedCommit }
    nonisolated let maximumSettlementWork: UInt64 = 4096
    private var claims = 0, commits = 0, releases = 0
    private var held = false
    var snapshot: (claims: Int, commits: Int, releases: Int, held: Bool) { (claims, commits, releases, held) }
    func claim(key: [UInt8], expiresAt: Int64, budget: RequestBudget) async throws -> ConsumptionClaim {
        try await budget.consume(1)
        claims += 1
        guard !held else { throw StateConsumptionStore.Failure.alreadyClaimed }
        #expect(key.count == 32 && expiresAt > 1000)
        held = true; return .init(handle: ScalarText("owned-probe-claim"))
    }
    func commit(_ claim: ConsumptionClaim, budget: RequestBudget) async throws {
        try await budget.consume(1); commits += 1; throw Failure.unexpectedCommit
    }
    func release(_ claim: ConsumptionClaim, budget: RequestBudget) async throws {
        try await budget.consume(1)
        #expect(claim.handle == ScalarText("owned-probe-claim") && held)
        releases += 1; throw Failure.refusedRelease
    }
}

@Suite(.serialized) struct S07ContinuationAcceptance {
    @Test(arguments: ["subject", "issuer", "resource"])
    func eachForeignPrincipalFieldRejectsStateBeforeResume(field: String) async throws {
        let resumed = Mutex(0)
        let provider = MultiRoundProvider(version: ScalarText("principal"), replay: .integrityOnly) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(state: .value(.string("private-handler-state")))) }
            resumed.withLock { $0 += 1 }; return .complete(try s07cComplete())
        }
        let server = try await s07cServer(provider)
        let first = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"round""#))
        let token = try s07cToken(first), p = StateFixture.principal
        let foreign = VerifiedPrincipal(subject: field == "subject" ? ScalarText("other") : p.subject,
            issuer: field == "issuer" ? ScalarText("other") : p.issuer,
            resource: field == "resource" ? ScalarText("other") : p.resource, scopes: p.scopes)
        let denied = try await StateFixture.response(server, s07cRetry(token, id: "2"), principal: foreign)
        #expect(try s07cCode(denied) == -32602 && resumed.withLock { $0 } == 0)
        let failureBytes = try WireCodec.write(denied, limits: .balanced).result
        #expect(!String(decoding: failureBytes, as: UTF8.self).contains("private-handler-state"))
        let accepted = try await StateFixture.response(server, s07cRetry(token, id: "3"))
        #expect(accepted.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
        #expect(resumed.withLock { $0 } == 1)
        await StateFixture.clean(server)
    }

    @Test func retryReauthorizesScopesWhileAllowingTheSamePrincipalOnAnotherOrigin() async throws {
        let resumed = Mutex(0)
        let provider = MultiRoundProvider(version: ScalarText("authority"), replay: .integrityOnly) { _, round, context in
            if !round.isRetry { return .inputRequired(.init(state: .null)) }
            #expect(context.origin == ScalarText("new-origin"))
            #expect(context.principal.scopes.contains(ScalarText("run")))
            resumed.withLock { $0 += 1 }; return .complete(try s07cComplete())
        }
        let server = try await s07cServer(provider, scopes: [ScalarText("run")]), p = StateFixture.principal
        let authorized = VerifiedPrincipal(subject: p.subject, issuer: p.issuer, resource: p.resource, scopes: [ScalarText("run")])
        let first = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"round""#), principal: authorized)
        let token = try s07cToken(first)
        await #expect(throws: CoreFailure.insufficientScopes) {
            _ = try await StateFixture.response(server, s07cRetry(token, id: "2"), principal: p)
        }
        #expect(resumed.withLock { $0 } == 0)
        let expanded = VerifiedPrincipal(subject: p.subject, issuer: p.issuer, resource: p.resource,
            scopes: [ScalarText("run"), ScalarText("extra")])
        let bytes = try #require(await server.handle(s07cRetry(token, id: "3"), principal: expanded, origin: ScalarText("new-origin")))
        #expect(try WireCodec.parse(Array(bytes), limits: .balanced).result.objectValue?["result"] != nil)
        #expect(resumed.withLock { $0 } == 1)
        await StateFixture.clean(server)
    }

    @Test func replayPolicyIsSeparateFromIntegrityAndFailedDeliveryDoesNotRepeatAConsumedEffect() async throws {
        let integrityEffects = Mutex(0)
        let integrity = MultiRoundProvider(version: ScalarText("integrity"), replay: .integrityOnly) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(state: .null)) }
            integrityEffects.withLock { $0 += 1 }; return .complete(try s07cComplete())
        }
        let replayable = try await s07cServer(integrity)
        let token = try s07cToken(await StateFixture.response(replayable, StateFixture.request("tools/call", fields: #", "name":"round""#)))
        for id in ["2", "3"] {
            #expect(try await StateFixture.response(replayable, s07cRetry(token, id: id)).objectValue?["result"] != nil)
        }
        #expect(integrityEffects.withLock { $0 } == 2)
        await StateFixture.clean(replayable)

        let store = try StateConsumptionStore(maximumEntries: 4, maximumBytes: 4096, maximumKeyBytes: 256, now: { 1000 })
        let consumedEffects = Mutex(0), writes = Mutex(0)
        let consuming = MultiRoundProvider(version: ScalarText("consuming"), replay: .consuming(store)) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(state: .null)) }
            consumedEffects.withLock { $0 += 1 }; return .complete(try s07cComplete())
        }
        let protected = try await s07cServer(consuming)
        let state = try s07cToken(await StateFixture.response(protected, StateFixture.request("tools/call", fields: #", "name":"round""#)))
        await #expect(throws: CoreFailure.disconnected) {
            try await protected.dispatch(s07cRetry(state, id: "2"), principal: StateFixture.principal, origin: StateFixture.origin) { _ in
                writes.withLock { $0 += 1 }; throw CoreFailure.disconnected
            }
        }
        #expect(writes.withLock { $0 } == 1 && consumedEffects.withLock { $0 } == 1)
        let replay = try await StateFixture.response(protected, s07cRetry(state, id: "3"))
        #expect(try s07cCode(replay) == -32602 && consumedEffects.withLock { $0 } == 1)
        #expect(await store.count == 1)
        #expect(await store.retainedBytes > 0)
        // The committed row intentionally retains replay protection until expiry.
        // This process-local source test promises no durable external exactly-once effect.
        await StateFixture.clean(protected)
    }

    @Test func caughtSafeReleaseFailureCannotReturnSuccessOrForgetTheHeldClaim() async throws {
        let store = S07SettlementProbe(), caught = Mutex(false), resumed = Mutex(0)
        let provider = MultiRoundProvider(version: ScalarText("settlement"), replay: .consuming(store)) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(state: .null)) }
            resumed.withLock { $0 += 1 }
            let effect = try #require(round.effect)
            do { try await effect.releaseForSafeRetry() }
            catch S07SettlementProbe.Failure.refusedRelease { caught.withLock { $0 = true } }
            return .complete(try s07cComplete())
        }
        let server = try await s07cServer(provider)
        let token = try s07cToken(await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"round""#)))
        let response = try await StateFixture.response(server, s07cRetry(token, id: "2"))
        #expect(try s07cCode(response) == -32603 && response.objectValue?["result"] == nil)
        #expect(caught.withLock { $0 } && resumed.withLock { $0 } == 1)
        let afterFailure = await store.snapshot
        #expect(afterFailure.claims == 1 && afterFailure.releases == 1 && afterFailure.commits == 0 && afterFailure.held)
        let retry = try await StateFixture.response(server, s07cRetry(token, id: "3"))
        #expect(try s07cCode(retry) == -32602 && resumed.withLock { $0 } == 1)
        let afterRetry = await store.snapshot
        #expect(afterRetry.claims == 2 && afterRetry.releases == 1 && afterRetry.commits == 0 && afterRetry.held)
        // Core owners can settle while a failing host's external debt is still
        // unresolved. Do not turn that held row into a cleanup-success assertion.
        await StateFixture.clean(server)
    }

    @Test func incompleteOrMalformedInputsCannotClaimAnEffectAndCurrentCapabilitiesStillApply() async throws {
        let store = try StateConsumptionStore(maximumEntries: 4, maximumBytes: 4096, maximumKeyBytes: 256, now: { 1000 })
        let roots = try StateFixture.json(#"{"method":"roots/list"}"#)
        let a = InputDescriptor(identifier: ScalarText("A"), request: roots), b = InputDescriptor(identifier: ScalarText("B"), request: roots)
        let resumed = Mutex(0)
        let provider = MultiRoundProvider(version: ScalarText("two-inputs"), inputs: [a,b], replay: .consuming(store)) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(inputs: [a.identifier,b.identifier], state: .null)) }
            #expect(round.responses.count == 2 && round.responses["A"] != nil && round.responses["B"] != nil)
            #expect(round.responses["unrelated"] == nil)
            resumed.withLock { $0 += 1 }; return .complete(try s07cComplete())
        }
        let server = try await s07cServer(provider), caps = #"{"roots":{}}"#
        let first = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"round""#, capabilities: caps))
        let original = try s07cToken(first)
        let missing = try await StateFixture.response(server, s07cRetry(original, id: "2", caps: caps, fields: #", "inputResponses":{}"#))
        #expect(missing.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue?.count == 2)
        let refreshed = try s07cToken(missing)
        #expect(await store.count == 0)
        let malformed = try await StateFixture.response(server, s07cRetry(refreshed, id: "3", caps: caps,
            fields: #", "inputResponses":{"A":{"roots":[]},"unrelated":null}"#))
        #expect(try s07cCode(malformed) == -32602 && resumed.withLock { $0 } == 0)
        #expect(await store.count == 0)
        let partial = try await StateFixture.response(server, s07cRetry(refreshed, id: "4", caps: caps,
            fields: #", "inputResponses":{"A":{"roots":[]}}"#))
        let pending = try #require(partial.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue)
        #expect(pending.count == 1 && pending["B"] != nil)
        #expect(await store.count == 0)
        let partialState = try s07cToken(partial)
        let noCapability = try await StateFixture.response(server, s07cRetry(partialState, id: "5", fields: #", "inputResponses":{"B":{"roots":[]}}"#))
        #expect(try s07cCode(noCapability) == -32021 && resumed.withLock { $0 } == 0)
        #expect(await store.count == 0)
        let final = try await StateFixture.response(server, s07cRetry(partialState, id: "6", caps: caps,
            fields: #", "inputResponses":{"B":{"roots":[]},"unrelated":{"roots":[]}}"#))
        #expect(final.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
        #expect(resumed.withLock { $0 } == 1)
        #expect(await store.count == 1)
        let replay = try await StateFixture.response(server, s07cRetry(original, id: "7", caps: caps,
            fields: #", "inputResponses":{"A":{"roots":[]},"B":{"roots":[]}}"#))
        #expect(try s07cCode(replay) == -32602 && resumed.withLock { $0 } == 1)
        await StateFixture.clean(server)
    }
}
