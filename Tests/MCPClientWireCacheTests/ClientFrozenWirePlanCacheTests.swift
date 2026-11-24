// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol
@testable import MCPClient
import Testing

// An isolated cache per test makes cold-start counts independent of test
// scheduling and of other SDK consumers warming the process-wide cache.
@Suite(.serialized) struct ClientFrozenWirePlanCacheCases {
    @Test func concurrentValidatorsCompileEachDefinitionOnceAndStillEvaluateEveryValue() async throws {
        let cache = ClientFrozenWirePlanCache()
        let implementation = try JSONParser().parse(#"{"name":"client","version":"1"}"#)
        let invalidImplementation = try JSONParser().parse(#"{"name":false,"version":"1"}"#)
        let discovery = try JSONParser().parse(#"{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"private"}"#)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { () async throws -> Void in
                    let validator = WireValidator(frozenPlans: cache)
                    // Evaluate throwing actor calls before expanding the nonthrowing
                    // assertion macros inside the task-group child closure.
                    let validImplementation = try await validator.validate(implementation, as: .Implementation)
                    #expect(validImplementation)
                    let invalidImplementationAccepted = try await validator.validate(invalidImplementation, as: .Implementation)
                    #expect(!invalidImplementationAccepted)
                    let validDiscovery = try await validator.validate(discovery, as: .DiscoverResult)
                    #expect(validDiscovery)
                    let invalidDiscoveryAccepted = try await validator.validate(.null, as: .DiscoverResult)
                    #expect(!invalidDiscoveryAccepted)
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await cache.snapshot
        #expect(snapshot.documentCached)
        #expect(snapshot.parses == 1)
        #expect(snapshot.definitions == 2 && snapshot.compilations == 2)
        #expect(snapshot.hits == 62)
        #expect(snapshot.retainedBytes > 0 && snapshot.retainedBytes <= 33_554_432)
    }

    @Test func definitionCeilingPreservesWarmEntryAndValidatesColdFallback() async throws {
        let cache = ClientFrozenWirePlanCache(maximumDefinitions: 1)
        let validator = WireValidator(frozenPlans: cache)
        let implementation = try JSONParser().parse(#"{"name":"client","version":"1"}"#)
        #expect(try await validator.validate(implementation, as: .Implementation))
        #expect(try await !validator.validate(.null, as: .DiscoverResult))
        #expect(try await !validator.validate(.null, as: .DiscoverResult))
        #expect(try await validator.validate(implementation, as: .Implementation))
        let snapshot = await cache.snapshot
        #expect(snapshot.documentCached && snapshot.parses == 1)
        #expect(snapshot.definitions == 1 && snapshot.compilations == 3 && snapshot.hits == 1)
        #expect(snapshot.retainedBytes <= 33_554_432)
    }

    @Test func byteCeilingRetainsNothingButDoesNotSkipValidation() async throws {
        let cache = ClientFrozenWirePlanCache(maximumRetainedBytes: 1)
        let validator = WireValidator(frozenPlans: cache)
        let implementation = try JSONParser().parse(#"{"name":"client","version":"1"}"#)
        #expect(try await validator.validate(implementation, as: .Implementation))
        #expect(try await !validator.validate(.null, as: .Implementation))
        let snapshot = await cache.snapshot
        #expect(!snapshot.documentCached && snapshot.retainedBytes == 0)
        #expect(snapshot.definitions == 0 && snapshot.parses == 2 && snapshot.compilations == 2 && snapshot.hits == 0)
    }

    @Test func cancelledColdAndWarmCallersDoNotAcquireOrPoisonPlans() async throws {
        let cache = ClientFrozenWirePlanCache()
        let validator = WireValidator(frozenPlans: cache)

        // A child added to an already cancelled structured group starts
        // cancelled; no sleep, timeout or ordering assumption is needed.
        await withTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                #expect(Task.isCancelled)
                await #expect(throws: CancellationError.self) {
                    _ = try await cache.plan(for: .Implementation)
                }
            }
            await group.waitForAll()
        }
        let cold = await cache.snapshot
        #expect(!cold.documentCached && cold.parses == 0 && cold.compilations == 0)

        let valid = try JSONParser().parse(#"{"name":"client","version":"1"}"#)
        #expect(try await validator.validate(valid, as: .Implementation))
        await withTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                #expect(Task.isCancelled)
                await #expect(throws: CancellationError.self) {
                    _ = try await cache.plan(for: .Implementation)
                }
                await #expect(throws: CancellationError.self) {
                    _ = try await validator.validate(valid, as: .Implementation)
                }
            }
            await group.waitForAll()
        }
        #expect(try await !validator.validate(.null, as: .Implementation))
        let warm = await cache.snapshot
        #expect(warm.parses == 1 && warm.compilations == 1 && warm.hits == 1)
    }

    @Test func failedPreparationDoesNotPublishOrBecomeACacheHit() async throws {
        var limited = ClientFrozenWirePlanCache.compileLimits
        limited[.workUnits] = 1
        let cache = ClientFrozenWirePlanCache(limits: limited)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                _ = try await cache.plan(for: .Implementation)
            }
        }
        let snapshot = await cache.snapshot
        #expect(snapshot.definitions == 0 && snapshot.compilations == 0 && snapshot.hits == 0)
    }

    @Test func serverSuppliedSchemasNeverEnterTheFrozenCache() async throws {
        let cache = ClientFrozenWirePlanCache()
        let first = WireValidator(frozenPlans: cache), second = WireValidator(frozenPlans: cache)
        let numeric = try JSONParser().parse(#"{"type":"object","required":["value"],"properties":{"value":{"type":"number"}}}"#)
        let textual = try JSONParser().parse(#"{"type":"object","required":["value"],"properties":{"value":{"type":"string"}}}"#)
        let value = try JSONParser().parse(#"{"value":1}"#)
        #expect(try await first.conforms(value, to: numeric))
        #expect(try await !second.conforms(value, to: textual))
        #expect(try await first.conforms(value, to: numeric))
        let snapshot = await cache.snapshot
        #expect(!snapshot.documentCached && snapshot.parses == 0)
        #expect(snapshot.definitions == 0 && snapshot.compilations == 0 && snapshot.hits == 0)
    }
}
