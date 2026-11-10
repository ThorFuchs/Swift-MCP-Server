// SPDX-License-Identifier: Apache-2.0
/// Finite coupled configurations. A byte ceiling does not promise every payload
/// below it fits work/terminal/global-buffer ceilings simultaneously. Host I/O,
/// keys, credentials and arbitrary provider costs remain separately configured.
public enum ResourceProfile: String, Sendable, CaseIterable {
    case conservative, balanced, trusted
    public func serverConfiguration() throws -> ServerConfiguration {
        switch self {
        case .conservative: try .init(activeRequests: 8, queuedRequests: 16, requestsPerPrincipal: 4, requestWork: 8000000, messageBytes: 262144, resultBytes: 1048576, catalogEntries: 1000, pageEntries: 100, deadlineMilliseconds: 30000, bufferedBytes: 8388608)
        case .balanced: try .init()
        case .trusted: try .init(activeRequests: 128, queuedRequests: 256, requestsPerPrincipal: 32, requestWork: 512000000, terminalWork: 1000000, messageBytes: 8388608, resultBytes: 16777216, catalogEntries: 100000, pageEntries: 1000, deadlineMilliseconds: 600000, bufferedBytes: 268435456)
        }
    }
    public func eventPolicy() throws -> EventPolicy {
        switch self {
        case .conservative: try .init(queuedEvents: 16, queuedBytes: 65536, globalBytes: 2097152, principalBytes: 262144, notificationBytes: 65536, subscriptions: 8, subscriptionsPerPrincipal: 4, filters: 64, subscriptionLifetimeMilliseconds: 60000, progressIntervalMilliseconds: 100, logIntervalMilliseconds: 200)
        case .balanced: try .init()
        case .trusted: try .init(queuedEvents: 256, queuedBytes: 1048576, globalBytes: 67108864, principalBytes: 4194304, notificationBytes: 1048576, subscriptions: 128, subscriptionsPerPrincipal: 64, filters: 1024, subscriptionLifetimeMilliseconds: 3600000, progressIntervalMilliseconds: 10, logIntervalMilliseconds: 10)
        }
    }
    /// SDK continuation claim keys are32-byte binding digests. A general host
    /// store can choose a different key policy independently of these profiles.
    public func consumptionStore(now: @escaping @Sendable () -> Int64) throws -> StateConsumptionStore {
        switch self {
        case .conservative: try .init(maximumEntries: 128, maximumBytes: 1048576, maximumKeyBytes: 32, now: now)
        case .balanced: try .init(maximumEntries: 4096, maximumBytes: 8388608, maximumKeyBytes: 32, now: now)
        case .trusted: try .init(maximumEntries: 16384, maximumBytes: 67108864, maximumKeyBytes: 32, now: now)
        }
    }
    public func continuationPolicy() throws -> ContinuationPolicy {
        switch self {
        case .conservative: try .init(maximumAttempts: 4, maximumInputs: 4, maximumTokenBytes: 8192, maximumStateBytes: 4096, lifetimeMilliseconds: 60000, maximumChainWork: 32000000)
        case .balanced: try .init()
        case .trusted: try .init(maximumAttempts: 64, maximumInputs: 64, maximumTokenBytes: 131072, maximumStateBytes: 65536, lifetimeMilliseconds: 3600000, maximumChainWork: 32768000000)
        }
    }
}
