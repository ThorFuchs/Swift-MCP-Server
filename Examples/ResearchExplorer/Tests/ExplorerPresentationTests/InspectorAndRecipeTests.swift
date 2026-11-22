// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import JSON
import MCPClient
import MCPProtocol
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP
@testable import ExplorerPresentation

/// Answers every exchange at once with a fixed message; records the bodies the SDK sent.
private final class CannedTransport: ClientTransport, Sendable {
    let sent = Mutex<[Data]>([])
    let reply: Data
    init(reply: Data = Data(#"{"jsonrpc":"2.0","id":0,"error":{"code":-32603,"message":"canned"}}"#.utf8)) { self.reply = reply }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        sent.withLock { $0.append(request.body) }
        try await receive(reply)
    }
}
private func object(_ data: Data) throws -> JSONObject { try #require(try JSONParser(options: .init(limits: .balanced)).parseWithReport(Array(data)).result.objectValue) }
/// The final JSON-RPC message of an HTTP response body (plain JSON or the last SSE `data:` event).
private func message(_ data: Data, contentType: String) throws -> JSONObject {
    guard contentType.hasPrefix("text/event-stream") else { return try object(data) }
    let text = String(decoding: data, as: UTF8.self)
    let last = try #require(text.components(separatedBy: "\n").last { $0.hasPrefix("data:") })
    return try object(Data(last.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
}
/// Order-insensitive rendering of a JSON value (object members sorted by key, recursively).
private func canonical(_ value: JSON) -> String {
    if let object = value.objectValue {
        return "{" + object.map { ($0.key, $0.value) }.sorted { "\($0.0)" < "\($1.0)" }.map { "\(String(reflecting: "\($0.0)")):\(canonical($0.1))" }.joined(separator: ",") + "}"
    }
    if let array = value.arrayValue { return "[" + array.map(canonical).joined(separator: ",") + "]" }
    return "\(value)"
}
private let secret = "Bearer sk-live-SECRET-7f3a https://evil.example/leak?token=abc"

/// RE-04 (#36): opt-in exchange inspector, tested connection recipes and privacy of everything kept.
@Suite(.serialized) struct InspectorAndRecipeTests {
    @Test @MainActor func inspectorIsOptInAndRecordsTheRealExchangesOfARun() async throws {
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        let journey = MCPJourneyController()
        #expect(!journey.inspectExchanges)
        journey.start(endpoint: endpoint, running: true, source: .offlineDemo); await journey.waitUntilFinished()
        #expect(journey.phase == .completed && journey.exchanges.isEmpty, "nothing is recorded unless enabled")
        journey.setInspectExchanges(true)
        journey.start(endpoint: endpoint, running: true, source: .offlineDemo)
        journey.setInspectExchanges(false) // locked while running
        #expect(journey.inspectExchanges)
        await journey.waitUntilFinished()
        let records = journey.exchanges
        #expect(records.map(\.method) == ["server/discover", "tools/list", "tools/call", "tools/call", "tools/call", "tools/call"])
        #expect(records.map(\.tool) == [nil, nil] + MCPResearchClient.toolNames.map { Optional($0) })
        #expect(records.allSatisfy { $0.outcome == .response && $0.requestBytes > 0 && $0.responseBytes > 0 && $0.messages >= 1 })
        #expect(records.map(\.id) == Array(0..<6) && journey.droppedExchanges == 0)
        // Exactly the four real tool calls reached the handlers (plus the first, uninspected run's four).
        #expect(await server.activity.snapshot().completed == 8)
        journey.clear()
        #expect(journey.exchanges.isEmpty && journey.steps.isEmpty && journey.phase == .idle && journey.outline == nil)
        await journey.shutdown()
        #expect(await server.stop())
    }

    @Test func recorderIsBoundedAndCountsWhatItDrops() async throws {
        let recorder = ExchangeRecorder()
        let transport = InspectingTransport(CannedTransport(), recorder: recorder)
        for i in 0..<40 {
            try await transport.exchange(.init(id: try RequestID(.string("r\(i)")), method: "tools/list", name: nil, body: Data("{}".utf8))) { _ in }
        }
        #expect(recorder.records.count == ExchangeRecorder.capacity && recorder.dropped == 40 - ExchangeRecorder.capacity)
        #expect(recorder.records.last?.id == ExchangeRecorder.capacity - 1)
    }

    @Test @MainActor func nothingKeptOrExportedContainsArgumentsResultsOrCredentials() async throws {
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        do {
            let recorder = ExchangeRecorder()
            let client = MCPResearchClient(client: Client(transport: InspectingTransport(try MCPJourneyController.httpTransport(endpoint), recorder: recorder)), profile: .offlineDemo)
            try await client.prepare()
            _ = try await client.search(.init(query: secret, project: "fixture-enwiki", limit: 5))
            _ = try? await client.outline(.init(project: "fixture-enwiki", candidateID: "sk-live-SECRET"))
            let outline = try await client.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
            let part = try #require(outline.sections.first { $0.location.partID == "p2" }?.location)
            _ = try await client.section(.init(snapshot: outline.snapshot, part: part, maxTextBytes: nil))
            // Inspector records: only fixed method/tool vocabulary and numbers.
            for record in recorder.records {
                #expect(["server/discover", "tools/list", "tools/call"].contains(record.method))
                #expect(record.tool == nil || MCPResearchClient.toolNames.contains(record.tool!))
                #expect(!"\(record)".contains("SECRET") && !"\(record)".contains("evil.example"))
            }
            // Activity and its export: no arguments, result text, URL or credential.
            let export = String(decoding: try ActivityExportEncoder.encode(await server.activity.snapshot(), filter: .init()), as: UTF8.self)
            for leaked in ["SECRET", "Bearer", "evil.example", "token=abc", "2-metre", "Halden", "fixture://"] {
                #expect(!export.contains(leaked), "export contains \(leaked)")
            }
            #expect(export.contains("\"payloadRecorded\":false") && export.contains("search_articles"))
        } catch { _ = await server.stop(); throw error }
        #expect(await server.stop())
    }

    @Test @MainActor func copiedRecipesWorkEndToEndAgainstTheRunningHost() async throws {
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        do {
            let recipes = ConnectionRecipe.recipes(for: endpoint, source: .offlineDemo)
            #expect(recipes.map(\.title) == ["Discover the server", "List the tools", "Call search_articles"])
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var results: [JSONObject] = []
            for recipe in recipes {
                // The curl text is a faithful rendering of the executed model.
                #expect(recipe.curl.contains("'\(recipe.endpoint.absoluteString)'") && recipe.curl.contains("--data '\(recipe.body)'"))
                for header in recipe.headers { #expect(recipe.curl.contains("-H '\(header.name): \(header.value)'")) }
                #expect(!recipe.body.contains("'") && recipe.headers.allSatisfy { !$0.value.contains("'") })
                var request = URLRequest(url: recipe.endpoint); request.httpMethod = "POST"; request.httpBody = Data(recipe.body.utf8)
                for header in recipe.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
                let (data, response) = try await session.data(for: request)
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200, "\(recipe.title): \(http.statusCode) \(String(decoding: data, as: UTF8.self))")
                let reply = try message(data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
                results.append(try #require(reply["result"]?.objectValue, "\(recipe.title) returned no result"))
            }
            #expect(results[0]["supportedVersions"]?.arrayValue?.contains { $0.stringValue == "2026-07-28" } == true)
            #expect(Set(results[1]["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []) == Set(MCPResearchClient.toolNames))
            let structured = try #require(results[2]["structuredContent"]?.objectValue)
            #expect(structured["status"]?.stringValue == "ok" && structured["value"]?.objectValue?["candidates"]?.arrayValue?.count == 5)
            #expect(await server.activity.snapshot().completed == 1, "the recipe's tools/call reached the real handler")
        } catch { _ = await server.stop(); throw error }
        #expect(await server.stop())
    }

    @Test func recipeBodiesAreWhatTheSDKClientSends() async throws {
        for (method, recipeIndex) in [("server/discover", 0), ("tools/list", 1)] {
            let canned = CannedTransport()
            let client = Client(transport: canned)
            _ = try? await (method == "server/discover" ? { _ = try await client.discover() } : { _ = try await client.listTools() })()
            let sdk = try object(try #require(canned.sent.withLock { $0.first })).removing(JSONKey("id"))
            let endpoint = try ServerEndpoint(host: "127.0.0.1", port: 8765)
            let recipe = try object(Data(ConnectionRecipe.recipes(for: endpoint, source: .offlineDemo)[recipeIndex].body.utf8)).removing(JSONKey("id"))
            #expect(canonical(.object(recipe)) == canonical(.object(sdk)), "\(method): recipe \(canonical(.object(recipe))) vs SDK \(canonical(.object(sdk)))")
        }
        // A recipe can only target an announced loopback endpoint; a wildcard host is not even an endpoint.
        #expect(throws: HostFailure.self) { _ = try ServerEndpoint(host: "0.0.0.0", port: 8765) }
    }
}
