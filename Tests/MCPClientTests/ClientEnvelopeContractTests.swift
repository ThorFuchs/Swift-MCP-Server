// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private enum EnvelopeFixtureError: Error, Sendable { case unexpectedExchange, missingToken }
private func envelopeJSON(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}
private let envelopeDone = #"{"jsonrpc":"2.0","id":$ID,"result":{"resultType":"complete","content":[{"type":"text","text":"done"}]}}"#
private let envelopeInput = #"{"jsonrpc":"2.0","id":$ID,"result":{"resultType":"input_required","inputRequests":{"s":{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8}}}}}"#
private let envelopeProgress = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":$TOKEN,"progress":1,"total":2}}"#
private let envelopeLog = #"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":{"label":"log"}}}"#
private let envelopeVersionError = #"{"jsonrpc":"2.0","id":$ID,"error":{"code":-32022,"message":"unsupported","data":{"supported":["2026-07-28"]}}}"#
private func envelopeError(_ error: String) -> String { #"{"jsonrpc":"2.0","id":$ID,"error":\#(error)}"# }

/// Await every receive and propagate its error. Some plans deliberately violate
/// the final-response contract to test Client's defensive boundary, not a real
/// transport's routing. Exhaustion throws, never repeats a successful frame.
private final class EnvelopeScript: ClientTransport, Sendable {
    private let plans: [[String]]
    private let receipts = Mutex<([Int], Int)>(([], 0))
    init(_ plans: [[String]]) { self.plans = plans }
    var ids: [Int] { receipts.withLock { $0.0 } }
    var delivered: Int { receipts.withLock { $0.1 } }
    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let body = try #require(try envelopeJSON(String(decoding: request.body, as: UTF8.self)).objectValue)
        let id = try #require(body["id"]?.numberValue).integer(as: Int.self)
        #expect(body["id"] == request.id.value && body["method"]?.stringValue == request.method)
        let token = body["params"]?.objectValue?["_meta"]?.objectValue?["progressToken"]
        let index = receipts.withLock { state in
            let previous = state.0.count; state.0.append(id); return previous
        }
        guard index < plans.count else { throw EnvelopeFixtureError.unexpectedExchange }
        for template in plans[index] {
            var frame = template.replacingOccurrences(of: "$FOREIGN", with: String(id + 1))
                .replacingOccurrences(of: "$ID", with: String(id))
            if frame.contains("$TOKEN") {
                guard let token else { throw EnvelopeFixtureError.missingToken }
                frame = frame.replacingOccurrences(of: "$TOKEN", with: String(decoding: try WireCodec.write(token, limits: .balanced).result, as: UTF8.self))
            }
            receipts.withLock { $0.1 += 1 }
            try await receive(Data(frame.utf8))
        }
    }
}

private final class EnvelopeHost: Sendable {
    private let calls = Mutex<[String]>([])
    var observed: [String] { calls.withLock { $0 } }
    var configuration: ClientConfiguration {
        .init(sampling: { _ in
            self.calls.withLock { $0.append("sampling") }
            return try .text("answer", model: "fixture")
        })
    }
    func run(_ client: Client) async throws -> ToolResult {
        try await client.callTool("probe", onProgress: { progress in
            self.calls.withLock { $0.append("progress") }
            #expect(progress.progress == 1 && progress.total == 2)
        }, onLog: { log in
            self.calls.withLock { $0.append("log") }
            #expect(log.data.objectValue?["label"]?.stringValue == "log")
        })
    }
}

/// One valid continuation is available to expose an erroneous version/MRTR
/// retry. Invalid cases must fail with the local protocol error, not a fixture
/// error, fabricated server error, or unexpected success.
private func envelopeReject(_ label: String, _ frames: [String], observed: [String] = [], exchanges: Int = 1) async {
    let transport = EnvelopeScript([frames, [envelopeDone]])
    let host = EnvelopeHost()
    let client = Client(transport: transport, configuration: host.configuration)
    do { _ = try await host.run(client); Issue.record("\(label): invalid envelope completed") }
    catch ClientError.invalidResponse(_) { }
    catch { Issue.record("\(label): wrong error category: \(error)") }
    #expect(transport.ids.count == exchanges, "\(label): unexpected retry")
    #expect(host.observed == observed, "\(label): unexpected host callback")
    print("A22C2A_CASE \(label) exchanges=\(transport.ids.count) delivered=\(transport.delivered) host=\(host.observed)")
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ClientEnvelopeContractCases {
    @Test func validProgressAndLogPrecedeTerminal() async throws {
        let transport = EnvelopeScript([[envelopeProgress, envelopeLog, envelopeDone]])
        let host = EnvelopeHost()
        let result = try await host.run(Client(transport: transport, configuration: host.configuration))
        #expect(result.text == "done" && host.observed == ["progress", "log"])
        #expect(transport.ids.count == 1 && transport.delivered == 3)
    }

    @Test func legacyMissingResultTypeRemainsComplete() async throws {
        let legacy = envelopeDone.replacingOccurrences(of: #""resultType":"complete","#, with: "")
        let transport = EnvelopeScript([[legacy]])
        let result = try await Client(transport: transport).callTool("probe")
        #expect(result.resultType == "complete" && result.text == "done" && transport.ids.count == 1)
    }

    @Test func rawExtensionResultPreservesFields() async throws {
        let raw = #"{"resultType":"complete","vendor":{"nested":[null,1,"opaque"]}}"#
        let transport = EnvelopeScript([[#"{"jsonrpc":"2.0","id":$ID,"result":\#(raw)}"#]])
        let result = try await Client(transport: transport).request("example/inspect")
        #expect(result == (try envelopeJSON(raw)))
        #expect(transport.ids.count == 1)
    }

    @Test func validServerErrorsPreserveCodeMessageAndOptionalData() async throws {
        let cases: [(String, JSON?)] = [
            (#"{"code":-32002,"message":"legacy"}"#, nil),
            (#"{"code":-32002,"message":"legacy","data":null}"#, .null),
            (#"{"code":-32002,"message":"legacy","data":[1,{"detail":"raw"}]}"#, try envelopeJSON(#"[1,{"detail":"raw"}]"#))]
        for (error, data) in cases {
            let transport = EnvelopeScript([[envelopeError(error)], [envelopeDone]])
            await #expect(throws: ClientError.server(code: -32002, message: "legacy", data: data)) {
                _ = try await Client(transport: transport).callTool("probe")
            }
            #expect(transport.ids.count == 1)
        }
    }

    @Test func validVersionRetryRemainsSingleAndUsesFreshID() async throws {
        let transport = EnvelopeScript([[envelopeVersionError], [envelopeDone]])
        #expect(try await Client(transport: transport).callTool("probe").text == "done")
        #expect(transport.ids.count == 2 && Set(transport.ids).count == 2)
        let stubborn = EnvelopeScript([[envelopeVersionError], [envelopeVersionError], [envelopeDone]])
        await #expect(throws: ClientError.unsupportedProtocol(supported: ["2026-07-28"])) {
            _ = try await Client(transport: stubborn).callTool("probe")
        }
        #expect(stubborn.ids.count == 2 && Set(stubborn.ids).count == 2)
    }

    @Test func responseIDMustCorrelateExactly() async {
        for (label, value) in [("foreign", "$FOREIGN"), ("string", #""$ID""#), ("fractional", "$ID.5"), ("null", "null"), ("boolean", "true")] {
            await envelopeReject("id-" + label, [envelopeDone.replacingOccurrences(of: "$ID", with: value)])
        }
        await envelopeReject("id-absent", [envelopeDone.replacingOccurrences(of: #""id":$ID,"#, with: "")])
        await envelopeReject("uncorrelated-error", [#"{"jsonrpc":"2.0","error":{"code":-32700,"message":"parse error"}}"#])
    }

    @Test func missingResultAndErrorIsInvalid() async {
        await envelopeReject("missing-both", [#"{"jsonrpc":"2.0","id":$ID}"#])
    }

    @Test func resultAndErrorCannotCoexist() async {
        await envelopeReject("result-and-error", [#"{"jsonrpc":"2.0","id":$ID,"result":{"resultType":"complete","content":[]},"error":{"code":-32603,"message":"error"}}"#])
        await envelopeReject("result-and-null-error", [#"{"jsonrpc":"2.0","id":$ID,"result":{"resultType":"complete","content":[]},"error":null}"#])
    }

    @Test func mixedVersionErrorCannotTriggerRetryOrHost() async {
        let mixed = envelopeInput.dropLast() + #", "error":{"code":-32022,"message":"unsupported","data":{"supported":["2026-07-28"]}}}"#
        await envelopeReject("mixed-version-error", [String(mixed)])
    }

    @Test func errorMustBeAnObjectWithRequiredMembers() async {
        for (label, error) in [("null", "null"), ("array", "[]"), ("string", #""error""#), ("empty", "{}"), ("no-code", #"{"message":"error"}"#), ("no-message", #"{"code":-32603}"#)] {
            await envelopeReject("error-" + label, [envelopeError(error)])
        }
    }

    @Test func errorCodeMustBeRepresentableInteger() async {
        for (label, code) in [("string", #""-32603""#), ("fractional", "-32603.5"), ("null", "null"), ("boolean", "true"), ("overflow", "9223372036854775808")] {
            await envelopeReject("code-" + label, [envelopeError(#"{"code":\#(code),"message":"error"}"#)])
        }
    }

    @Test func errorMessageMustBeString() async {
        for (label, message) in [("numeric", "1"), ("null", "null"), ("object", "{}") ] {
            await envelopeReject("message-" + label, [envelopeError(#"{"code":-32603,"message":\#(message)}"#)])
        }
    }

    @Test func malformedVersionErrorCannotTriggerRetry() async {
        await envelopeReject("version-error-no-message", [envelopeError(#"{"code":-32022,"data":{"supported":["2026-07-28"]}}"#)])
    }

    @Test func resultMustBeObjectEvenForGenericRequest() async throws {
        for value in ["null", "[]", #""text""#, "1"] {
            let frame = #"{"jsonrpc":"2.0","id":$ID,"result":\#(value)}"#
            await envelopeReject("result-shape-" + value, [frame])
            let transport = EnvelopeScript([[frame], [envelopeDone]])
            do { _ = try await Client(transport: transport).request("example/inspect"); Issue.record("generic scalar result accepted: \(value)") }
            catch ClientError.invalidResponse(_) { }
            catch { Issue.record("wrong generic result error: \(error)") }
            #expect(transport.ids.count == 1)
        }
    }

    @Test func explicitNonStringResultTypeIsNotLegacyAbsence() async {
        for value in ["null", "1", "{}", "[]"] {
            let transport = EnvelopeScript([[#"{"jsonrpc":"2.0","id":$ID,"result":{"resultType":\#(value),"vendor":true}}"#], [envelopeDone]])
            do { _ = try await Client(transport: transport).request("example/inspect"); Issue.record("generic resultType accepted: \(value)") }
            catch ClientError.invalidResponse(_) { }
            catch { Issue.record("wrong resultType error: \(error)") }
            #expect(transport.ids.count == 1)
        }
    }

    @Test func notificationCannotContainResultOrError() async {
        for (label, member) in [("result", #""result":{"resultType":"complete"}"#), ("error", #""error":{"code":-32603,"message":"error"}"#)] {
            let mixed = envelopeProgress.dropLast() + "," + member + "}"
            await envelopeReject("notification-" + label, [String(mixed), envelopeDone])
        }
    }

    @Test func malformedNotificationParamsCannotBeIgnoredAsExtension() async {
        for value in ["null", "[]", "1", #""text""#] {
            let frame = #"{"jsonrpc":"2.0","method":"notifications/example/opaque","params":\#(value)}"#
            await envelopeReject("notification-params-" + value, [frame, envelopeDone])
        }
    }

    @Test func unknownNotificationWithOptionalObjectParamsRemainsCompatible() async throws {
        let transport = EnvelopeScript([[#"{"jsonrpc":"2.0","method":"notifications/example/opaque"}"#,
                                         #"{"jsonrpc":"2.0","method":"notifications/example/opaque","params":{"extension":[1,null]}}"#,
                                         envelopeDone]])
        let host = EnvelopeHost()
        #expect(try await host.run(Client(transport: transport, configuration: host.configuration)).text == "done")
        #expect(host.observed.isEmpty && transport.delivered == 3 && transport.ids.count == 1)
    }

    @Test func serverInitiatedRequestDoesNotInvokeSampling() async {
        await envelopeReject("server-request", [#"{"jsonrpc":"2.0","id":$FOREIGN,"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8}}"#, envelopeDone])
    }

    @Test func duplicateTerminalCannotStartInputHandler() async {
        await envelopeReject("duplicate-input-terminal", [envelopeInput, envelopeDone])
        await envelopeReject("duplicate-error-terminal", [envelopeDone, envelopeVersionError])
    }

    @Test func progressAfterTerminalCannotInvokeCallbackOrContinueMRTR() async {
        await envelopeReject("late-progress-complete", [envelopeDone, envelopeProgress])
        await envelopeReject("late-progress-input", [envelopeInput, envelopeProgress])
    }

    @Test func logAfterTerminalCannotInvokeCallback() async {
        await envelopeReject("late-log", [envelopeDone, envelopeLog])
    }

    @Test func emptyExchangeIsNoResponseNotServerError() async {
        let transport = EnvelopeScript([[], [envelopeDone]])
        await #expect(throws: ClientError.noResponse) { _ = try await Client(transport: transport).callTool("probe") }
        #expect(transport.ids.count == 1 && transport.delivered == 0)
    }

    @Test func foreignProgressTokenIsNotDelivered() async throws {
        let foreign = envelopeProgress.replacingOccurrences(of: "$TOKEN", with: #""not-this-token""#)
        let transport = EnvelopeScript([[foreign, envelopeProgress, envelopeDone]])
        let host = EnvelopeHost()
        #expect(try await host.run(Client(transport: transport, configuration: host.configuration)).text == "done")
        #expect(host.observed == ["progress"] && transport.delivered == 3 && transport.ids.count == 1)
    }
}
