// SPDX-License-Identifier: Apache-2.0
/// An explicitly owned provider or transport lifetime. Dependencies remain alive
/// until their dependants have drained. Call ready only after resource validation
/// and actual binding; construction alone does not announce readiness.
public struct TransportService: Sendable {
    public enum Completion: Sendable { case shutdown, unexpected }
    public typealias Ready = @Sendable () async throws -> Void
    public let name: String, dependencies: [String]
    let completion: Completion
    let operation: @Sendable (@escaping Ready) async throws -> Void
    let stop: @Sendable () async -> Void
    let forceClose: @Sendable () -> Void
    public init(name: String, dependencies: [String] = [], completion: Completion = .shutdown,
                run: @escaping @Sendable (@escaping Ready) async throws -> Void,
                shutdown: @escaping @Sendable () async -> Void,
                forceClose: @escaping @Sendable () -> Void = {}) throws {
        func valid(_ s: String) -> Bool {
            !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        guard valid(name), dependencies.count <= 64, dependencies.allSatisfy(valid),
              Set(dependencies).count == dependencies.count, !dependencies.contains(name) else { throw LifecycleFailure.invalidConfiguration }
        self.name = name; self.dependencies = dependencies; self.completion = completion
        operation = run; stop = shutdown; self.forceClose = forceClose
    }
}
