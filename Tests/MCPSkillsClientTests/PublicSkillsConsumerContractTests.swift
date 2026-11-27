// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol
import MCPSkillsClient

private func skillConsumerJSON(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}

private struct SkillConsumerStep: Sendable {
    let method: String
    let params: String
    let result: String
    let name: String?
    init(_ method: String, _ params: String, _ result: String, name: String? = nil) {
        self.method = method; self.params = params; self.result = result; self.name = name
    }
}

private final class SkillConsumerScript: ClientTransport, Sendable {
    let steps: [SkillConsumerStep]
    private let position = Mutex(0)
    init(_ steps: [SkillConsumerStep]) { self.steps = steps }
    var count: Int { position.withLock { $0 } }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let index = position.withLock { n in let i = n; n += 1; return i }
        let step = try #require(steps.indices.contains(index) ? steps[index] : nil)
        let body = try #require(try skillConsumerJSON(String(decoding: request.body, as: UTF8.self)).objectValue)
        let params = try #require(body["params"]?.objectValue)
        let expected = try #require(try skillConsumerJSON(step.params).objectValue)
        let meta = try #require(params["_meta"]?.objectValue)
        #expect(request.method == step.method && body["method"]?.stringValue == step.method && request.name == step.name)
        #expect(body["id"] == request.id.value && body["jsonrpc"]?.stringValue == "2.0")
        #expect(meta["io.modelcontextprotocol/protocolVersion"]?.stringValue == "2026-07-28")
        #expect(params.count == expected.count + 1)
        for member in expected { #expect(params[member.key.string] == member.value) }
        let reply = JSON.object(try JSONObject(members: [
            JSONMember("jsonrpc", value: .string("2.0")), JSONMember("id", value: request.id.value),
            JSONMember("result", value: try skillConsumerJSON(step.result))
        ]))
        try await receive(try WireCodec.write(reply, limits: .balanced).result)
    }
}

private let skillURI = "skill://demo/SKILL.md"
private let supportURI = "skill://demo/data.bin"
private let skillMarkdown = "---\nname: demo\ndescription: A demo skill\n---\n\nHello.\n"
// Independent known-byte vectors: the markdown is 53 UTF-8 bytes,
// supporting binary is [0,1,2,255], four bytes.
private let skillEntry = #"{"uri":"skill://demo/SKILL.md","frontmatter":{"name":"demo","description":"A demo skill"},"resources":[{"uri":"skill://demo/SKILL.md","size":53,"digest":"sha256:c754fc4d6fb2ab00364240592f63a8dc6b00881ba201a117c918bd9094eed013"},{"uri":"skill://demo/data.bin","size":4,"digest":"sha256:3d1f57c984978ef98a18378c8166c1cb8ede02c03eeb6aee7e2f121dfeee3e56"}]}"#
private let skillGet = #"{"resultType":"complete","ttlMs":30,"cacheScope":"private","skill":\#(skillEntry)}"#
private let skillRead = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"uri":"skill://demo/SKILL.md","mimeType":"text/markdown","text":"---\nname: demo\ndescription: A demo skill\n---\n\nHello.\n"}]}"#

@Suite(.serialized) struct PublicSkillsConsumerContractCases {
    @Test func skillsConsumerDirectLookupLoadsOnlyExplicitlyRequestedFiles() async throws {
        let discover = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","supportedVersions":["2026-07-28"],"capabilities":{"resources":{},"extensions":{"io.modelcontextprotocol/skills":{"directoryRead":true}}}}"#
        let binary = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"uri":"skill://demo/data.bin","blob":"AAEC/w=="}]}"#
        let script = SkillConsumerScript([.init("server/discover","{}",discover),
            .init("skills/get", #"{"uri":"skill://demo/SKILL.md"}"#, skillGet),
            .init("resources/read", #"{"uri":"skill://demo/SKILL.md"}"#, skillRead, name: skillURI),
            .init("resources/read", #"{"uri":"skill://demo/data.bin"}"#, binary, name: supportURI)])
        let client = Client(transport: script)
        let description = try await client.discover()
        #expect(SkillsClient.isSupported(by: description))
        let skills = SkillsClient(client: client)
        let entry: SkillEntry = try await skills.get(skillURI)
        #expect(entry.uri == skillURI && entry.name == "demo" && entry.description == "A demo skill")
        #expect(entry.files.map(\.uri) == [skillURI,supportURI])
        #expect(entry.files.map(\.size) == [53,4] && entry.raw == (try skillConsumerJSON(skillEntry)))
        #expect(script.count == 2) // no list or speculative content read
        let loaded: LoadedSkill = try await skills.load(entry)
        #expect(loaded.markdown == skillMarkdown && loaded.entry.raw == entry.raw && script.count == 3)
        await #expect(throws: SkillVerificationError.notListed(uri: "skill://demo/unlisted")) {
            _ = try await skills.file("skill://demo/unlisted", of: loaded)
        }
        #expect(script.count == 3)
        #expect(try await skills.file(supportURI, of: loaded) == [0,1,2,255])
        #expect(script.count == 4)
    }

    @Test func skillsConsumerPagesRetainRawCacheHintsAndOpaqueCursorWithoutPrefetch() async throws {
        let first = #"{"resultType":"complete","ttlMs":30,"cacheScope":"private","nextCursor":"","skills":[\#(skillEntry)]}"#
        let last = #"{"resultType":"complete","ttlMs":0,"cacheScope":"public","skills":[]}"#
        let script = SkillConsumerScript([.init("skills/list","{}",first),
            .init("skills/list", #"{"cursor":""}"#, last)])
        let skills = SkillsClient(client: Client(transport: script))
        let page: Page<SkillEntry> = try await skills.list()
        #expect(page.items.count == 1 && page.nextCursor == "" && page.raw == (try skillConsumerJSON(first)))
        #expect(page.items.first?.raw == (try skillConsumerJSON(skillEntry)))
        let end = try await skills.list(cursor: try #require(page.nextCursor))
        #expect(end.items.isEmpty && end.nextCursor == nil && end.raw == (try skillConsumerJSON(last)) && script.count == 2)
    }

    @Test func skillsConsumerRejectsContentForDifferentURI() async throws {
        let other = skillRead.replacingOccurrences(of: skillURI, with: "skill://other/SKILL.md")
        let script = SkillConsumerScript([.init("skills/get", #"{"uri":"skill://demo/SKILL.md"}"#, skillGet),
            .init("resources/read", #"{"uri":"skill://demo/SKILL.md"}"#, other, name: skillURI)])
        let skills = SkillsClient(client: Client(transport: script))
        let entry = try await skills.get(skillURI)
        await #expect(throws: SkillVerificationError.missingContent(uri: skillURI)) {
            _ = try await skills.load(entry)
        }
        #expect(script.count == 2)
    }

    @Test func skillsConsumerGetCannotSubstituteAnotherSkillURI() async throws {
        let other = skillGet.replacingOccurrences(of: "skill://demo/", with: "skill://other/")
        let script = SkillConsumerScript([.init("skills/get", #"{"uri":"skill://demo/SKILL.md"}"#, other)])
        do {
            _ = try await SkillsClient(client: Client(transport: script)).get(skillURI)
            Issue.record("skills/get returned an entry for another URI")
        } catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected error category: \(error)") }
        #expect(script.count == 1)
    }

    @Test func skillsConsumerListAndGetRejectMissingRequiredCacheFields() async throws {
        let malformedList = #"{"resultType":"complete","skills":[\#(skillEntry)]}"#
        let malformedGet = #"{"resultType":"complete","skill":\#(skillEntry)}"#
        let script = SkillConsumerScript([.init("skills/list","{}",malformedList),
            .init("skills/get", #"{"uri":"skill://demo/SKILL.md"}"#, malformedGet)])
        let skills = SkillsClient(client: Client(transport: script))
        do { _ = try await skills.list(); Issue.record("skills/list accepted missing required cache fields") }
        catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected list error: \(error)") }
        do { _ = try await skills.get(skillURI); Issue.record("skills/get accepted missing required cache fields") }
        catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected get error: \(error)") }
        #expect(script.count == 2)
    }

    @Test func skillsConsumerRejectsNonStringContinuationInsteadOfSilentlyEnding() async throws {
        let malformed = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","nextCursor":7,"skills":[\#(skillEntry)]}"#
        let script = SkillConsumerScript([.init("skills/list","{}",malformed)])
        do { _ = try await SkillsClient(client: Client(transport: script)).list(); Issue.record("malformed continuation looked like terminal page") }
        catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected error category: \(error)") }
        #expect(script.count == 1)
    }

    @Test func skillsConsumerFixedManifestProfileDeclinesDynamicWithoutFetching() async throws {
        let dynamic = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","skill":{"uri":"skill://demo/SKILL.md","frontmatter":{"name":"demo","description":"A demo skill"},"resources":"dynamic"}}"#
        let script = SkillConsumerScript([.init("skills/get", #"{"uri":"skill://demo/SKILL.md"}"#, dynamic)])
        do { _ = try await SkillsClient(client: Client(transport: script)).get(skillURI); Issue.record("unsupported dynamic manifest was accepted as fixed") }
        catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected error category: \(error)") }
        #expect(script.count == 1)
    }
}
