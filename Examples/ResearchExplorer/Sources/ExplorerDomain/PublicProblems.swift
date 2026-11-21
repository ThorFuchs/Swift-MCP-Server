// SPDX-License-Identifier: Apache-2.0
/// Owned finite public vocabulary. Adapter messages/recovery are NEVER output.
public enum PublicProblems {
    public static func project(_ code: ExplorerProblem.Code) -> ExplorerProblem {
        switch code {
        case .invalidArguments: .init(code, "Arguments exceed the operation contract.", recovery: "Use the documented fields and limits.")
        case .projectNotAllowed: .init(code, "Project is not enabled.", recovery: "Use fixture-enwiki.")
        case .unknownCandidate: .init(code, "Candidate is unknown.", recovery: "Search again and choose a returned candidate ID.")
        case .absentPage: .init(code, "No article seed exists for this candidate.", recovery: "Choose fixture-observatory.")
        case .absentSnapshot: .init(code, "Exact snapshot is absent or expired.", recovery: "Obtain a new outline and reuse its complete locator.")
        case .absentSection: .init(code, "Part is absent from this revision.", recovery: "Choose a part from this exact outline.")
        case .revisionMismatch: .init(code, "Snapshot and part identities differ.", recovery: "Use identities from the same outline.")
        case .ambiguousTitle: .init(code, "Title does not identify one article.", recovery: "Search and choose an exact candidate ID.")
        case .missingReferences: .init(code, "Reference metadata was not supplied.", recovery: "Treat citations as unverified; do not infer an empty list.")
        case .unsupportedVariant: .init(code, "The normalized variant is unsupported.", recovery: "Use a supported owned fixture format.")
        case .budgetExceeded: .init(code, "Result exceeds the example profile.", recovery: "Select a narrower section or smaller limit.")
        case .upstreamUnavailable: .init(code, "Provider is unavailable.", recovery: "Retry explicitly after the provider is restored.")
        case .upstreamRateLimited: .init(code, "Provider rate limit was reached.", recovery: "Wait before explicitly retrying.")
        case .upstreamTimedOut: .init(code, "Provider operation timed out.", recovery: "Retry explicitly; no empty result was substituted.")
        case .invalidFixture: .init(code, "Provider violated the normalized contract.", recovery: "Restore the checked fixture or repair the provider adapter.")
        }
    }
}
