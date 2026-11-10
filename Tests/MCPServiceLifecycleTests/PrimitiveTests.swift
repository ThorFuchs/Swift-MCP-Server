// SPDX-License-Identifier: Apache-2.0
import Testing
import MCPServiceLifecycle

@Test func readinessCannotReopenStoppedOrDrainingService() async throws {
    let state = Readiness()
    #expect(await state.state == .starting)
    try await state.markReady()
    #expect(await state.state == .ready)
    await #expect(throws: Readiness.Failure.invalidTransition) { try await state.markReady() }
    await state.beginDrain()
    await state.beginDrain()
    #expect(await state.state == .draining)
    await #expect(throws: Readiness.Failure.invalidTransition) { try await state.markReady() }
    await state.stop()
    await state.beginDrain()
    #expect(await state.state == .stopped)
}

@Test func startupFailureNeverBecomesReady() async {
    let state = Readiness()
    await state.fail()
    await state.stop()
    #expect(await state.state == .failed)
    await #expect(throws: Readiness.Failure.invalidTransition) { try await state.markReady() }
}
