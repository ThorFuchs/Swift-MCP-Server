// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import ExplorerDomain
@testable import WikimediaAccess

/// An actual URLSession task receives a response and partial body, then the
/// protocol deliberately withholds EOF until URLSession stops the request.
private final class StallingURLProtocol: URLProtocol {
    struct Counts { var started = 0; var stopped = 0 }
    static let counts = Mutex(Counts())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": "1024"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"pages\":".utf8))
        Self.counts.withLock { $0.started += 1 }
    }
    override func stopLoading() { Self.counts.withLock { $0.stopped += 1 } }
}

/// The URL loading system's own request timeout ends a partial response. The
/// transport derives that timeout from its deadline, so this is the same event
/// as its deadline timer firing; which one fires first depends on scheduling
/// (the timer task runs on the cooperative pool, the request timeout does not).
private final class RequestTimeoutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": "1024"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"pages\":".utf8))
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LiveHTTPStallTests {
    private func makeTransport() -> WikipediaHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        return WikipediaHTTPTransport(configuration: configuration)
    }
    private func waitForStart() async throws {
        for _ in 0..<200 {
            if StallingURLProtocol.counts.withLock({ $0.started }) > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StallTestFailure.noResponse
    }
    private func waitForStop() async throws {
        for _ in 0..<200 {
            if StallingURLProtocol.counts.withLock({ $0.stopped }) > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StallTestFailure.noStop
    }
    private enum StallTestFailure: Error { case noResponse, noStop }

    @Test func cancellationOfPartialResponseJoinsTask() async throws {
        StallingURLProtocol.counts.withLock { $0 = .init() }
        let transport = makeTransport(), url = try WikipediaRoute.search("stall", limit: 1)
        let task = Task { try await transport.get(url, deadline: ContinuousClock.now.advanced(by: .seconds(5))) }
        do {
            try await waitForStart()
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancellation must not succeed") }
            catch is CancellationError { }
            try await waitForStop()
            #expect(StallingURLProtocol.counts.withLock { $0.stopped } == 1)
        } catch { task.cancel(); _ = await task.result; throw error }
    }
    /// #28 / R3: whichever of the two deadline mechanisms fires first, the
    /// transport reports its deadline as `upstreamTimedOut`, never a raw URLError.
    @Test func requestTimeoutOfPartialResponseIsTheDeadline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestTimeoutURLProtocol.self]
        let transport = WikipediaHTTPTransport(configuration: configuration)
        let url = try WikipediaRoute.search("stall", limit: 1)
        do {
            _ = try await transport.get(url, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
            Issue.record("A timed-out partial response must not succeed")
        } catch let problem as ExplorerProblem {
            #expect(problem.code == .upstreamTimedOut)
        } catch { Issue.record("Expected upstreamTimedOut, got \(error)") }
    }
    @Test func deadlineOfPartialResponseJoinsTask() async throws {
        StallingURLProtocol.counts.withLock { $0 = .init() }
        let transport = makeTransport(), url = try WikipediaRoute.search("stall", limit: 1)
        let task = Task { try await transport.get(url, deadline: ContinuousClock.now.advanced(by: .seconds(1))) }
        do {
            try await waitForStart()
            do { _ = try await task.value; Issue.record("A stalled body must time out") }
            catch let problem as ExplorerProblem { #expect(problem.code == .upstreamTimedOut) }
            try await waitForStop()
            #expect(StallingURLProtocol.counts.withLock { $0.stopped } == 1)
        } catch { task.cancel(); _ = await task.result; throw error }
    }
}
