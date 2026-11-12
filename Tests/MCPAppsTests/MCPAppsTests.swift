// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPApps
import MCPProtocol
import MCPServer

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let user = VerifiedPrincipal(subject: ScalarText("user"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])
private let appsDeclaration = #"{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}"#

private func request(_ method: String, id: Int, fields: String = "", extensions: String? = nil) -> Data {
    let capabilities = extensions.map { "{\"extensions\":\($0)}" } ?? "{}"
    return Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":\(capabilities)}\(fields)}}".utf8)
}
private func respond(_ server: Server, _ data: Data) async throws -> JSON {
    try json(String(decoding: #require(await server.handle(data, principal: user, origin: ScalarText("host"))), as: UTF8.self))
}
private func result(_ value: JSON) -> JSONObject? { value.objectValue?["result"]?.objectValue }

private let dashboard = try! AppView(uri: "ui://weather/dashboard", name: "dashboard", description: "Weather dashboard",
    html: "<!doctype html><html><body>Weather</body></html>",
    metadata: AppViewMetadata(csp: AppContentSecurityPolicy(connectDomains: ["https://api.weather.example"], resourceDomains: ["https://*.cdn.example"]),
                              permissions: [.geolocation], prefersBorder: true))

private func weatherTool() throws -> ToolRegistration {
    let definition = try dashboard.annotate(try json(#"{"name":"forecast","inputSchema":{"type":"object"},"_meta":{"com.example/keep":1}}"#))
    return ToolRegistration(definition: definition) { _, context in
        let text = MCPApps.clientRendersApps(context) ? "Forecast shown in the dashboard." : "Sunny, 21 °C."
        return try json(#"{"resultType":"complete","content":[{"type":"text","text":"\#(text)"}],"structuredContent":{"temperature":21}}"#)
    }
}

private func makeServer(tools: [ToolRegistration], resources: [ResourceProvider], extensions: [ExtensionRegistration] = []) async throws -> Server {
    try await Server.make(info: json(#"{"name":"apps","version":"1"}"#),
        catalog: ServerCatalog(tools: tools, resources: resources, extensions: extensions),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
}

@Suite struct MCPAppsCases {
    @Test func viewsAreServedAsAppResourcesWithTheirMetadata() async throws {
        let server = try await makeServer(tools: [try weatherTool()], resources: [try dashboard.resource()], extensions: [try MCPApps.registration()])
        let discovered = try #require(result(try await respond(server, request("server/discover", id: 1))))
        #expect(discovered["capabilities"]?.objectValue?["extensions"]?.objectValue?[MCPApps.extensionIdentifier] != nil)

        let listed = try #require(result(try await respond(server, request("resources/list", id: 2)))?["resources"]?.arrayValue?.first?.objectValue)
        #expect(listed["uri"]?.stringValue == "ui://weather/dashboard" && listed["mimeType"]?.stringValue == MCPApps.mimeType)
        let ui = try #require(listed["_meta"]?.objectValue?["ui"]?.objectValue)
        #expect(ui["csp"]?.objectValue?["connectDomains"]?.arrayValue?.first?.stringValue == "https://api.weather.example")
        #expect(ui["csp"]?.objectValue?["frameDomains"] == nil)
        #expect(ui["permissions"]?.objectValue?["geolocation"] != nil && ui["permissions"]?.objectValue?["camera"] == nil)
        #expect(ui["prefersBorder"]?.booleanValue == true && ui["domain"] == nil)

        let read = try #require(result(try await respond(server, request("resources/read", id: 3, fields: #", "uri":"ui://weather/dashboard""#))))
        let content = try #require(read["contents"]?.arrayValue?.first?.objectValue)
        #expect(content["text"]?.stringValue == dashboard.html && content["mimeType"]?.stringValue == MCPApps.mimeType)
        #expect(content["_meta"]?.objectValue?["ui"]?.objectValue == ui)
    }

    @Test func toolsReferenceTheirViewAndKeepATextFallback() async throws {
        let tool = try weatherTool()
        let meta = try #require(tool.definition.objectValue?["_meta"]?.objectValue)
        #expect(meta["ui"]?.objectValue?["resourceUri"]?.stringValue == "ui://weather/dashboard")
        #expect(meta["ui"]?.objectValue?["visibility"] == nil)
        #expect(meta["com.example/keep"] != nil)
        let appOnly = try dashboard.annotate(try json(#"{"name":"refresh","inputSchema":{"type":"object"}}"#), visibility: [.app])
        #expect(appOnly.objectValue?["_meta"]?.objectValue?["ui"]?.objectValue?["visibility"]?.arrayValue?.compactMap(\.stringValue) == ["app"])

        let server = try await makeServer(tools: [tool], resources: [try dashboard.resource()])
        let call = #", "name":"forecast", "arguments":{}"#
        let plain = try await respond(server, request("tools/call", id: 1, fields: call))
        #expect(result(plain)?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "Sunny, 21 °C.")
        let rich = try await respond(server, request("tools/call", id: 2, fields: call, extensions: appsDeclaration))
        #expect(result(rich)?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "Forecast shown in the dashboard.")
    }

    @Test func catalogValidationRequiresServedAppViews() throws {
        let tool = try weatherTool()
        try MCPApps.validate(tools: [tool], resources: [try dashboard.resource()])
        #expect(throws: AppDefinitionError.self) { try MCPApps.validate(tools: [tool], resources: []) }
        let plain = ResourceProvider(definition: try json(#"{"uri":"ui://weather/dashboard","name":"d","mimeType":"text/html"}"#)) { _, _ in
            try json(#"{"resultType":"complete","contents":[]}"#)
        }
        #expect(throws: AppDefinitionError.self) { try MCPApps.validate(tools: [tool], resources: [plain]) }
    }

    @Test func invalidViewsAreRejectedWhenBuilt() {
        for uri in ["https://weather/dashboard", "ui:///dashboard", "ui://weather/dashboard?x=1", "ui://weather/dashboard#top"] {
            #expect(throws: AppDefinitionError.self) { _ = try AppView(uri: uri, name: "d", html: "<p>") }
        }
        #expect(throws: AppDefinitionError.self) { _ = try AppView(uri: "ui://weather/d", name: "d", html: "") }
        for origin in ["api.example", "ftp://files.example", "https://example.com/path", "https://user@example.com", "https://*"] {
            #expect(throws: AppDefinitionError.self) {
                _ = try AppView(uri: "ui://weather/d", name: "d", html: "<p>", metadata: .init(csp: .init(connectDomains: [origin])))
            }
        }
        #expect(throws: Never.self) {
            _ = try AppView(uri: "ui://weather/d", name: "d", html: "<p>",
                            metadata: .init(csp: .init(connectDomains: ["wss://live.example:8443", "https://*.cdn.example"])))
        }
    }
}
