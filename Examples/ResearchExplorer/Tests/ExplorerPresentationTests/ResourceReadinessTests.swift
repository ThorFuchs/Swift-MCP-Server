// SPDX-License-Identifier: Apache-2.0
// WRE-S01 source only: NOT_COMPILED / NOT_RUN. This controlled host does not
// replace the unchanged LiveCatalogTests or prove SDK resource loading.
import Testing
@testable import ExplorerPresentation

private actor CatalogUnavailableHost: ExplorerHTTPHost {
    private(set) var runs = 0
    private(set) var joins = 0
    func run(ready: @escaping @Sendable (ServerEndpoint) async -> Void) async throws {
        runs += 1
        defer { joins += 1 }
        throw HostFailure.catalogUnavailable
    }
    func stop() async throws {}
}

struct ResourceReadinessTests {
    @Test @MainActor func catalogFailureKeepsEndpointUnavailableAndJoinsBeforeRetry() async {
        let host = CatalogUnavailableHost()
        let controller = ServerController(activity: ActivityStore(), factory: { _ in host })
        controller.start()
        await controller.waitUntilRunJoined()
        #expect(controller.phase == .failed)
        #expect(controller.failure == .catalogUnavailable)
        #expect(controller.endpoint == nil)
        #expect(!controller.cleanupDebt && controller.canStart)
        #expect(await host.runs == 1)
        #expect(await host.joins == 1)
        #expect(await controller.stopAndJoin())
        controller.start()
        await controller.waitUntilRunJoined()
        #expect(controller.endpoint == nil && controller.failure == .catalogUnavailable)
        #expect(await host.runs == 2)
        #expect(await host.joins == 2)
    }
}
