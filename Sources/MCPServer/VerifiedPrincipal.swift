// SPDX-License-Identifier: Apache-2.0
import MCPProtocol

/// Trusted host identity supplied after verification, separate from client metadata.
public struct VerifiedPrincipal: Sendable, Equatable {
    public let subject: ScalarText
    public let issuer: ScalarText
    public let resource: ScalarText
    public let scopes: Set<ScalarText>
    public init(subject: ScalarText, issuer: ScalarText, resource: ScalarText, scopes: Set<ScalarText>) {
        self.subject = subject
        self.issuer = issuer
        self.resource = resource
        self.scopes = scopes
    }
}
