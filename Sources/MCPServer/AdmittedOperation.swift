// SPDX-License-Identifier: Apache-2.0

/// One owned admission permit and one request account for an entire operation.
/// The caller owns this task. No library task/signal/backend is created here.
/// Each permit conservatively covers the configured finite request allowance;
/// no library stage starts before acquisition or after a terminal account.
public enum AdmittedOperation {
    // Dispatch owns emission and terminal election inside the operation. This
    // owner joins its children before releasing the sole admission permit.
    static func runDelivering(admission: AdmissionController, budget: RequestBudget,
        operation: @Sendable () async throws -> Void) async throws {
        let permit: AdmissionController.Permit
        do { permit = try await admission.acquire() }
        catch { await budget.terminate(); throw error }
        do { try await operation() }
        catch {
            await budget.terminate()
            try await admission.release(permit)
            throw error
        }
        await budget.terminate()
        try await admission.release(permit)
    }
    public static func run<Result: Sendable>(admission: AdmissionController,
        budget: RequestBudget, terminal: TerminalCoordinator,
        operation: @Sendable (RequestBudget) async throws -> Result) async throws -> Result {
        let permit: AdmissionController.Permit
        do { permit = try await admission.acquire() }
        catch {
            await budget.terminate()
            _ = await terminal.claim(error is CancellationError ? .cancelled : .failure)
            throw error
        }
        let result: Result
        do {
            try Task.checkCancellation()
            guard !(await budget.snapshot.isTerminal), await terminal.outcome == nil else { throw RequestBudget.Failure.exhausted }
            result = try await operation(budget)
            try Task.checkCancellation()
            let final = await budget.snapshot
            guard !final.isTerminal, final.activeReservations == 0 else { throw RequestBudget.Failure.exhausted }
        } catch {
            await budget.terminate()
            _ = await terminal.claim(error is CancellationError ? .cancelled : .failure)
            // Release once, outside the operation's failure/cancellation paths.
            // A release invariant error propagates rather than being hidden.
            try await admission.release(permit)
            throw error
        }
        guard await terminal.claim(.complete) else {
            await budget.terminate()
            try await admission.release(permit)
            throw RequestBudget.Failure.exhausted
        }
        try await admission.release(permit)
        return result
    }
}
