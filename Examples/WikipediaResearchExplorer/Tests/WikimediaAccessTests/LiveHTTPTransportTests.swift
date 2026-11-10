// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
@testable import WikimediaAccess

@Suite struct LiveHTTPTransportTests {
    @Test func expiredRequestIsDeniedBeforeStartingNetwork() async throws {
        let transport = WikipediaHTTPTransport()
        let url = try WikipediaRoute.search("Noether theorem", limit: 1)
        do {
            _ = try await transport.get(url, deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
            Issue.record("An expired request must not start")
        } catch let problem as ExplorerProblem {
            #expect(problem.code == .upstreamTimedOut)
        }
    }
    @Test func unapprovedDestinationIsDeniedBeforeStartingNetwork() async throws {
        let transport = WikipediaHTTPTransport()
        let url = try #require(URL(string: "https://example.com/"))
        do {
            _ = try await transport.get(url, deadline: ContinuousClock.now.advanced(by: .seconds(1)))
            Issue.record("An unapproved destination must not start")
        } catch let failure as LiveFailure {
            #expect(failure == .url)
        }
    }
}
