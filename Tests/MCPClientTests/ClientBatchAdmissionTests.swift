// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private enum BatchFixtureError: Error, Equatable, Sendable { case unexpectedExchange, host }
private enum BatchPath: String, Sendable, CaseIterable { case wire, direct }
private enum BatchRejection: Equatable, Sendable { case invalid, unsupported(String) }
private func batchJSON(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private func batchObject(_ text: String) throws -> JSONObject { try #require(try batchJSON(text).objectValue) }
private let batchRoots = #"{"method":"roots/list"}"#
private let batchForm = #"{"method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}"#
private let batchURL = #"{"method":"elicitation/create","params":{"mode":"url","message":"Consent?","url":"https://example.invalid/consent"}}"#
private let batchSampling = #"{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8}}"#
private let batchExtension = #"{"method":"example/input","params":{"nested":[null,1,{"opaque":"keep"}]}}"#
private let batchExtensionAbsent = #"{"method":"example/input"}"#
private let batchUnknown = #"{"method":"example/unregistered","params":{}}"#
private let batchBadSampling = #"{"method":"sampling/createMessage","params":{"messages":[]}}"#
private let batchBadForm = #"{"method":"elicitation/create","params":{"message":"missing schema"}}"#
private let batchBadRoots = #"{"method":"roots/list","params":[]}"#
private let batchSamplingTools = #"{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8,"tools":[]}}"#
private let batchSamplingChoice = #"{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8,"toolChoice":{"mode":"auto"}}}"#
private func batchPair(_ valid: String, _ invalid: String, reversed: Bool) -> String {
    // Both placements, with stable input keys; JSONObject is insertion-ordered.
    reversed ? #"{"bad":\#(invalid),"good":\#(valid)}"# : #"{"good":\#(valid),"bad":\#(invalid)}"#
}

/// A finite public-API script. No handler or result validation is performed
/// here. It offers a valid second reply to expose an erroneous continuation.
private final class BatchTransport: ClientTransport, Sendable {
    private let plans: [String]
    private let requests = Mutex<[JSONObject]>([])
    init(_ plans: [String] = []) { self.plans = plans }
    var records: [JSONObject] { requests.withLock { $0 } }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let body = try batchObject(String(decoding: request.body, as: UTF8.self))
        #expect(body["id"] == request.id.value && request.method == "tools/call" && request.name == "probe")
        let index = requests.withLock { rows in let i = rows.count; rows.append(body); return i }
        guard index < plans.count else { throw BatchFixtureError.unexpectedExchange }
        let id = String(decoding: try WireCodec.write(request.id.value, limits: .balanced).result, as: UTF8.self)
        try await receive(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(plans[index])}"#.utf8))
    }
}
private func batchInput(_ input: String) -> String {
    #"{"resultType":"input_required","requestState":"opaque-batch","inputRequests":\#(input)}"#
}
private let batchDone = #"{"resultType":"complete","content":[{"type":"text","text":"done"}]}"#

private final class BatchHost: Sendable {
    private let trace = Mutex<[String]>([])
    private let raw = Mutex<[JSON]>([])
    var observed: [String] { trace.withLock { $0 } }
    var rawInputs: [JSON] { raw.withLock { $0 } }
    func configuration(sampling: Bool = true, roots: Bool = true, form: Bool = true, url: Bool = false,
                       extensionHandler: Bool = true, failAt: String? = nil, invalidAt: String? = nil) -> ClientConfiguration {
        var config = ClientConfiguration(elicitation: .init(form: form, url: url) { request in
            let label: String
            switch request.mode { case .form: label = "form"; case .url: label = "url" }
            self.trace.withLock { $0.append(label) }
            if failAt == label { throw BatchFixtureError.host }
            if invalidAt == label { return .accept(content: nil) }
            return .decline
        }, sampling: { _ in
            self.trace.withLock { $0.append("sampling") }
            if failAt == "sampling" { throw BatchFixtureError.host }
            if invalidAt == "sampling" { return SamplingResponse(content: .null, model: "fixture") }
            return try .text("answer", model: "fixture")
        }, roots: {
            self.trace.withLock { $0.append("roots") }
            if failAt == "roots" { throw BatchFixtureError.host }
            return [Root(uri: "file:///batch", name: "batch")]
        }, additionalInputHandlers: ["example/input": { params in
            self.trace.withLock { $0.append("extension") }
            self.raw.withLock { $0.append(params) }
            if failAt == "extension" { throw BatchFixtureError.host }
            return try batchJSON(#"{"resultType":"complete","vendor":{"keep":[1,null]}}"#)
        }])
        if !sampling { config.sampling = nil }
        if !roots { config.roots = nil }
        if !extensionHandler { config.additionalInputHandlers = [:] }
        return config
    }
}

/// The order assertion is fixture admission, not a public promise that JSON
/// map order is semantically significant. It prevents an invalid-first case
/// from masquerading as proof that valid-first execution is atomic.
private func batchReject(_ label: String, valid: String, invalid: String, path: BatchPath,
                         expected: BatchRejection,
                         configure: (BatchHost) -> ClientConfiguration) async throws {
    for reversed in [false, true] {
        let input = batchPair(valid, invalid, reversed: reversed)
        let object = try batchObject(input)
        try #require(object.members.map(\.key.string) == (reversed ? ["bad", "good"] : ["good", "bad"]))
        let transport = BatchTransport(path == .wire ? [batchInput(input), batchDone] : [])
        let host = BatchHost()
        let client = Client(transport: transport, configuration: configure(host))
        var actual: BatchRejection?
        do {
            if path == .wire { _ = try await client.callTool("probe") }
            else { _ = try await client.answerInputRequests(object) }
            Issue.record("\(label): invalid batch completed")
        } catch ClientError.invalidResponse(_) { actual = .invalid }
        catch ClientError.unsupportedInput(let method) { actual = .unsupported(method) }
        catch { Issue.record("\(label): unexpected error \(error)") }
        #expect(actual == expected, "\(label): exact local error category")
        #expect(host.observed.isEmpty && host.rawInputs.isEmpty, "\(label): admission must precede every handler")
        #expect(transport.records.count == (path == .wire ? 1 : 0), "\(label): no retry/partial response")
        if let first = transport.records.first {
            #expect(first["params"]?.objectValue?["inputResponses"] == nil)
        }
        let order = reversed ? "bad-first" : "good-first"
        print("A22C2B_CASE \(label) path=\(path.rawValue) order=\(order) matched=\(actual == expected) exchanges=\(transport.records.count) host=\(host.observed)")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ClientBatchAdmissionCases {
    @Test func validWireBatchAnswersAllKeysExactlyOnce() async throws {
        let input = #"{"r":\#(batchRoots),"f":\#(batchForm),"s":\#(batchSampling)}"#
        let transport = BatchTransport([batchInput(input), batchDone])
        let host = BatchHost()
        #expect(try await Client(transport: transport, configuration: host.configuration()).callTool("probe").text == "done")
        #expect(host.observed.sorted() == ["form", "roots", "sampling"])
        let records = transport.records
        try #require(records.count == 2)
        #expect(records[0]["id"] != records[1]["id"])
        let params = try #require(records[1]["params"]?.objectValue)
        #expect(params["requestState"] == .string("opaque-batch"))
        let responses = try #require(params["inputResponses"]?.objectValue)
        let expected = try batchObject(#"{"r":{"roots":[{"uri":"file:///batch","name":"batch"}]},"f":{"action":"decline"},"s":{"role":"assistant","content":{"type":"text","text":"answer"},"model":"fixture","stopReason":"endTurn"}}"#)
        #expect(responses == expected)
    }

    @Test func validDirectBatchPreservesRawExtensionParamsAndKeys() async throws {
        let input = try batchObject(#"{"opaque-key":\#(batchExtension),"r":\#(batchRoots),"absent":\#(batchExtensionAbsent),"f":\#(batchURL)}"#)
        let transport = BatchTransport()
        let host = BatchHost()
        let result = try await Client(transport: transport, configuration: host.configuration(url: true)).answerInputRequests(input)
        let expected = try batchJSON(#"{"opaque-key":{"resultType":"complete","vendor":{"keep":[1,null]}},"r":{"roots":[{"uri":"file:///batch","name":"batch"}]},"absent":{"resultType":"complete","vendor":{"keep":[1,null]}},"f":{"action":"decline"}}"#)
        #expect(result == expected && transport.records.isEmpty)
        #expect(host.observed.sorted() == ["extension", "extension", "roots", "url"])
        #expect(host.rawInputs == [try batchJSON(#"{"nested":[null,1,{"opaque":"keep"}]}"#), try batchJSON("{}")])
    }

    @Test func emptyDirectBatchReturnsEmptyObjectWithoutHost() async throws {
        let transport = BatchTransport()
        let host = BatchHost()
        let input = try batchObject("{}")
        let result = try await Client(transport: transport, configuration: host.configuration()).answerInputRequests(input)
        #expect(result == .object(input) && host.observed.isEmpty && transport.records.isEmpty)
    }

    @Test func malformedWireBatchIsRejectedBeforeAnyHandler() async throws {
        for (label, invalid) in [("wire-bad-sampling", batchBadSampling), ("wire-bad-form", batchBadForm), ("wire-bad-roots", batchBadRoots)] {
            try await batchReject(label, valid: batchRoots, invalid: invalid, path: .wire, expected: .invalid) { $0.configuration() }
        }
    }

    @Test func wireInputUnionDoesNotAdmitRegisteredRawExtension() async throws {
        try await batchReject("wire-extension", valid: batchRoots, invalid: batchExtension, path: .wire, expected: .invalid) { $0.configuration() }
    }

    @Test func unavailableWireHandlerPreventsAllCallbacks() async throws {
        try await batchReject("wire-no-sampling", valid: batchRoots, invalid: batchSampling, path: .wire, expected: .unsupported("sampling/createMessage")) { $0.configuration(sampling: false) }
        try await batchReject("wire-no-roots", valid: batchForm, invalid: batchRoots, path: .wire, expected: .unsupported("roots/list")) { $0.configuration(roots: false) }
    }

    @Test func unadvertisedWireElicitationModePreventsAllCallbacks() async throws {
        try await batchReject("wire-no-url", valid: batchRoots, invalid: batchURL, path: .wire, expected: .unsupported("elicitation/create")) { $0.configuration() }
        try await batchReject("wire-no-form", valid: batchRoots, invalid: batchForm, path: .wire, expected: .unsupported("elicitation/create")) { $0.configuration(form: false, url: true) }
    }

    @Test func unadvertisedWireSamplingFeaturePreventsAllCallbacks() async throws {
        for (label, invalid) in [("wire-tools", batchSamplingTools), ("wire-choice", batchSamplingChoice)] {
            try await batchReject(label, valid: batchRoots, invalid: invalid, path: .wire, expected: .unsupported("sampling/createMessage")) { $0.configuration() }
        }
    }

    @Test func malformedDirectKnownRequestPreventsAllCallbacks() async throws {
        for (label, invalid) in [("direct-bad-sampling", batchBadSampling), ("direct-bad-form", batchBadForm), ("direct-bad-roots", batchBadRoots)] {
            try await batchReject(label, valid: batchExtension, invalid: invalid, path: .direct, expected: .invalid) { $0.configuration() }
        }
    }

    @Test func unregisteredDirectExtensionPreventsAllCallbacks() async throws {
        try await batchReject("direct-unregistered", valid: batchRoots, invalid: batchUnknown, path: .direct, expected: .unsupported("example/unregistered")) { $0.configuration() }
    }

    @Test func malformedDirectEntryCannotBeTreatedAsUnsupportedMethod() async throws {
        for (label, invalid) in [("direct-null-entry", "null"), ("direct-array-entry", "[]"), ("direct-missing-method", #"{"params":{}}"#), ("direct-numeric-method", #"{"method":7}"#)] {
            try await batchReject(label, valid: batchRoots, invalid: invalid, path: .direct, expected: .invalid) { $0.configuration() }
        }
    }

    @Test func malformedDirectExtensionParamsPreventsAllCallbacks() async throws {
        for (label, params) in [("null", "null"), ("array", "[]"), ("number", "7"), ("string", #""text""#)] {
            let invalid = #"{"method":"example/input","params":\#(params)}"#
            try await batchReject("direct-extension-params-" + label, valid: batchRoots, invalid: invalid, path: .direct, expected: .invalid) { $0.configuration() }
        }
    }

    @Test func unavailableDirectHandlerOrModePreventsAllCallbacks() async throws {
        try await batchReject("direct-no-sampling", valid: batchExtension, invalid: batchSampling, path: .direct, expected: .unsupported("sampling/createMessage")) { $0.configuration(sampling: false) }
        try await batchReject("direct-no-roots", valid: batchExtension, invalid: batchRoots, path: .direct, expected: .unsupported("roots/list")) { $0.configuration(roots: false) }
        try await batchReject("direct-no-url", valid: batchExtension, invalid: batchURL, path: .direct, expected: .unsupported("elicitation/create")) { $0.configuration() }
    }

    @Test func unadvertisedDirectSamplingFeaturePreventsAllCallbacks() async throws {
        for (label, invalid) in [("direct-tools", batchSamplingTools), ("direct-choice", batchSamplingChoice)] {
            try await batchReject(label, valid: batchExtension, invalid: invalid, path: .direct, expected: .unsupported("sampling/createMessage")) { $0.configuration() }
        }
    }

    @Test func hostFailureStopsExecutionWithoutPretendingToRollbackEarlierWork() async throws {
        let input = #"{"first":\#(batchRoots),"failure":\#(batchSampling),"last":\#(batchForm)}"#
        let object = try batchObject(input)
        try #require(object.members.map(\.key.string) == ["first", "failure", "last"])
        for path in BatchPath.allCases {
            let transport = BatchTransport(path == .wire ? [batchInput(input), batchDone] : [])
            let host = BatchHost()
            let client = Client(transport: transport, configuration: host.configuration(failAt: "sampling"))
            await #expect(throws: BatchFixtureError.host) {
                if path == .wire { _ = try await client.callTool("probe") }
                else { _ = try await client.answerInputRequests(object) }
            }
            #expect(host.observed == ["roots", "sampling"])
            #expect(transport.records.count == (path == .wire ? 1 : 0))
        }
    }

    @Test func invalidHandlerResultStopsExecutionWithoutPartialResponse() async throws {
        let input = #"{"first":\#(batchRoots),"failure":\#(batchSampling),"last":\#(batchForm)}"#
        let object = try batchObject(input)
        try #require(object.members.map(\.key.string) == ["first", "failure", "last"])
        for path in BatchPath.allCases {
            let transport = BatchTransport(path == .wire ? [batchInput(input), batchDone] : [])
            let host = BatchHost()
            let client = Client(transport: transport, configuration: host.configuration(invalidAt: "sampling"))
            do {
                if path == .wire { _ = try await client.callTool("probe") }
                else { _ = try await client.answerInputRequests(object) }
                Issue.record("invalid handler result completed")
            } catch ClientError.invalidResponse(_) { }
            catch { Issue.record("unexpected handler result error \(error)") }
            #expect(host.observed == ["roots", "sampling"])
            #expect(transport.records.count == (path == .wire ? 1 : 0))
        }
    }

    @Test func failedBatchDoesNotPoisonNextIndependentCall() async throws {
        let bad = #"{"bad":\#(batchBadSampling),"good":\#(batchRoots)}"#
        let good = #"{"good":\#(batchRoots)}"#
        let transport = BatchTransport([batchInput(bad), batchInput(good), batchDone])
        let host = BatchHost()
        let client = Client(transport: transport, configuration: host.configuration())
        do { _ = try await client.callTool("probe"); Issue.record("invalid first batch completed") }
        catch ClientError.invalidResponse(_) { }
        catch { Issue.record("unexpected first error \(error)") }
        #expect(host.observed.isEmpty && transport.records.count == 1)
        #expect(try await client.callTool("probe").text == "done")
        let records = transport.records
        try #require(records.count == 3)
        #expect(host.observed == ["roots"])
        #expect(records[1]["params"]?.objectValue?["inputResponses"] == nil)
        #expect(records[1]["params"]?.objectValue?["requestState"] == nil)
        #expect(records[2]["params"]?.objectValue?["inputResponses"]?.objectValue?.count == 1)
    }
}
