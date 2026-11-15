// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
@testable import MCPClient
import MCPProtocol

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private func text(_ value: JSON) throws -> String { String(decoding: try WireCodec.write(value, limits: .balanced).result, as: UTF8.self) }

@Suite struct ClientTypeViews {
    @Test func contentBlocksDecodeAndUnknownOnesPassThrough() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let blocks = try json("""
            [{"type":"text","text":"hi"},{"type":"image","data":"\(png)","mimeType":"image/png"},
             {"type":"audio","data":"\(png)","mimeType":"audio/wav"},
             {"type":"resource_link","uri":"file:///a","name":"a","mimeType":"text/plain"},
             {"type":"resource","resource":{"uri":"file:///b","blob":"\(png)"}},
             {"type":"image","data":"not base64!","mimeType":"image/png"},
             {"type":"hologram","depth":3}]
            """).arrayValue!.map(Content.init)
        #expect(blocks[0] == .text("hi"))
        #expect(blocks[1] == .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"))
        #expect(blocks[2] == .audio(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "audio/wav"))
        #expect(blocks[3] == .resourceLink(uri: "file:///a", name: "a", mimeType: "text/plain", description: nil))
        #expect(blocks[4] == .embeddedResource(.blob(uri: "file:///b", mimeType: nil, data: Data([0x89, 0x50, 0x4E, 0x47]))))
        // Undecodable payloads and unknown types are kept, not dropped.
        guard case .unknown = blocks[5], case .unknown(let hologram) = blocks[6] else { Issue.record("expected unknown"); return }
        #expect(hologram.objectValue?["depth"] != nil)
        #expect(ToolResult(try json(#"{"resultType":"complete","content":[{"type":"text","text":"a"},{"type":"image","data":"","mimeType":"x"},{"type":"text","text":"b"}]}"#)).text == "ab")
    }

    @Test func resourceContentsRequireTextOrValidBase64() throws {
        let text = try ResourceContents(try json(#"{"uri":"file:///a","mimeType":"text/plain","text":"Hä"}"#))
        #expect(text.uri == "file:///a" && text.mimeType == "text/plain" && text.bytes == Array("Hä".utf8))
        #expect(try ResourceContents(try json(#"{"uri":"file:///b","blob":"AAEC"}"#)).bytes == [0, 1, 2])
        #expect(throws: ClientError.self) { _ = try ResourceContents(try json(#"{"uri":"file:///c","blob":"%%%"}"#)) }
        #expect(throws: ClientError.self) { _ = try ResourceContents(try json(#"{"uri":"file:///d"}"#)) }
    }

    @Test func promptsCompletionsTemplatesAndServerInfo() throws {
        let prompt = try PromptResult(try json(#"{"resultType":"complete","description":"d","messages":[{"role":"user","content":{"type":"text","text":"Q"}},{"role":"assistant","content":{"type":"text","text":"A"}}]}"#))
        #expect(prompt.description == "d" && prompt.messages == [PromptMessage(role: .user, content: .text("Q")), PromptMessage(role: .assistant, content: .text("A"))])
        #expect(throws: ClientError.self) { _ = try PromptResult(try json(#"{"messages":[{"role":"system","content":{"type":"text","text":"x"}}]}"#)) }

        let completion = Completion(try json(#"{"resultType":"complete","completion":{"values":["py","pyx"],"total":7,"hasMore":true}}"#))
        #expect(completion.values == ["py", "pyx"] && completion.total == 7 && completion.hasMore == true)
        #expect(try text(try CompletionReference.prompt(name: "code").json) == #"{"type":"ref/prompt","name":"code"}"#)
        #expect(try text(try CompletionReference.resourceTemplate(uri: "file:///{path}").json) == #"{"type":"ref/resource","uri":"file:///{path}"}"#)

        let template = try ResourceTemplate(try json(#"{"uriTemplate":"file:///{path}","name":"files","mimeType":"text/plain"}"#))
        #expect(template.uriTemplate == "file:///{path}" && template.name == "files" && template.mimeType == "text/plain" && template.title == nil)
        #expect(Implementation(try json(#"{"name":"srv","version":"1.2","title":"Server"}"#))?.title == "Server")
        #expect(Implementation(try json(#"{"name":"srv"}"#)) == nil)
    }

    @Test func filtersAndHandlerAnswersEncodeAsTheSchemaExpects() throws {
        let filter = SubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["file:///a"], extensions: ["taskIds": .array([.string("t1")])])
        #expect(try text(try filter.json) == #"{"toolsListChanged":true,"resourceSubscriptions":["file:///a"],"taskIds":["t1"]}"#)
        #expect(try text(try SubscriptionFilter().json) == "{}")

        #expect(try text(try ElicitationResponse.accept(content: try json(#"{"name":"Ada"}"#).objectValue).json) == #"{"action":"accept","content":{"name":"Ada"}}"#)
        #expect(try text(try ElicitationResponse.accept(content: nil).json) == #"{"action":"accept"}"#)
        #expect(try text(try ElicitationResponse.decline.json) == #"{"action":"decline"}"#)
        #expect(try text(try [Root(uri: "file:///a", name: "A"), Root(uri: "file:///b")].json) == #"{"roots":[{"uri":"file:///a","name":"A"},{"uri":"file:///b"}]}"#)
        #expect(try text(try SamplingResponse.text("Hi", model: "m").json) == #"{"role":"assistant","content":{"type":"text","text":"Hi"},"model":"m","stopReason":"endTurn"}"#)
    }

    @Test func inputRequestsDecode() throws {
        let form = try ElicitationRequest(try json(#"{"mode":"form","message":"Name?","requestedSchema":{"type":"object","properties":{}}}"#))
        guard case .form(let schema) = form.mode else { Issue.record("expected form"); return }
        #expect(form.message == "Name?" && schema.objectValue?["type"]?.stringValue == "object")
        let url = try ElicitationRequest(try json(#"{"mode":"url","message":"Sign in","url":"https://example.com/login","elicitationId":"e1"}"#))
        guard case .url(let target, let id) = url.mode else { Issue.record("expected url"); return }
        #expect(target.absoluteString == "https://example.com/login" && id == "e1")

        let sampling = try SamplingRequest(try json(#"{"messages":[{"role":"user","content":{"type":"text","text":"2+2?"}}],"systemPrompt":"Be brief","maxTokens":64,"temperature":0.5,"stopSequences":["\n"]}"#))
        #expect(sampling.messages.first?.role == .user && sampling.messages.first?.text == "2+2?")
        #expect(sampling.systemPrompt == "Be brief" && sampling.maxTokens == 64 && sampling.temperature == 0.5 && sampling.stopSequences == ["\n"])
    }

    @Test func errorsCompareAndExposeCodes() throws {
        let missing = ClientError.server(code: ClientError.Code.missingRequiredCapabilities, message: "m",
                                         data: try json(#"{"requiredCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}"#))
        #expect(missing.requiredExtensions == ["io.modelcontextprotocol/tasks"] && missing.serverCode == -32021)
        #expect(ClientError.server(code: ClientError.Code.invalidParams, message: "x", data: nil) == .server(code: -32602, message: "x", data: nil))
        #expect(ClientError.noResponse != .tooManyInputRounds && ClientError.noResponse.serverCode == nil)
        #expect(LoggingLevel.debug < .warning && LoggingLevel.allCases.max() == .emergency)
        #expect(RejectedTool(name: "t", reason: "r") == RejectedTool(name: "t", reason: "r"))
    }
}
