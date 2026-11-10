// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import Logging
import Metrics
import ServiceContextModule
import MCPProtocol
import MCPServer
import MCPObservability

private final class Capture: Sendable {
    struct Metric: Sendable { let id: UUID, label: String, dimensions: [String:String], kind: String; var values: [Double] = [] }
    struct State { var metrics: [Metric] = []; var destroyed: Set<UUID> = []; var duplicateDestroy = false; var logs: [String] = [] }
    let state = Mutex(State())
    func make(_ label:String,_ dimensions:[(String,String)],_ kind:String) -> Instrument {
        let id = UUID(); state.withLock { $0.metrics.append(.init(id:id,label:label,dimensions:Dictionary(uniqueKeysWithValues:dimensions),kind:kind)) }
        return Instrument(id:id,capture:self)
    }
    func destroy(_ handler:Any) {
        guard let i = handler as? Instrument else { return }
        state.withLock { if !$0.destroyed.insert(i.id).inserted { $0.duplicateDestroy = true } }
    }
}
private final class Instrument: CounterHandler, RecorderHandler, TimerHandler, Sendable {
    let id:UUID, capture:Capture
    init(id:UUID,capture:Capture) { self.id = id; self.capture = capture }
    private func value(_ value:Double) { capture.state.withLock { s in if let i = s.metrics.firstIndex(where: { $0.id == id }) { s.metrics[i].values.append(value) } } }
    func increment(by amount:Int64) { value(Double(amount)) }
    func reset() { value(0) }
    func record(_ v:Int64) { value(Double(v)) }
    func record(_ v:Double) { value(v) }
    func recordNanoseconds(_ v:Int64) { value(Double(v)) }
}
private struct Factory: MetricsFactory {
    let capture:Capture
    func makeCounter(label:String,dimensions:[(String,String)]) -> any CounterHandler { capture.make(label,dimensions,"counter") }
    func makeRecorder(label:String,dimensions:[(String,String)],aggregate:Bool) -> any RecorderHandler { capture.make(label,dimensions,aggregate ? "aggregate" : "gauge") }
    func makeTimer(label:String,dimensions:[(String,String)]) -> any TimerHandler { capture.make(label,dimensions,"timer") }
    func makeFloatingPointCounter(label:String,dimensions:[(String,String)]) -> any FloatingPointCounterHandler { NOOPMetricsHandler.instance }
    func makeMeter(label:String,dimensions:[(String,String)]) -> any MeterHandler { NOOPMetricsHandler.instance }
    func destroyCounter(_ handler:any CounterHandler) { capture.destroy(handler) }
    func destroyRecorder(_ handler:any RecorderHandler) { capture.destroy(handler) }
    func destroyTimer(_ handler:any TimerHandler) { capture.destroy(handler) }
    func destroyFloatingPointCounter(_ handler:any FloatingPointCounterHandler) {}
    func destroyMeter(_ handler:any MeterHandler) {}
}
private struct Handler: LogHandler {
    let capture:Capture
    var metadata:Logger.Metadata = ["host-secret":.string("SENTINEL-BEARER-SECRET")]
    var metadataProvider:Logger.MetadataProvider? = .init { ["provider-secret":.string("SENTINEL-STATE-SECRET")] }
    var logLevel:Logger.Level = .debug
    subscript(metadataKey key:String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
    func log(event:LogEvent) {
        var combined = metadata; combined.merge(metadataProvider?.get() ?? [:],uniquingKeysWith: { _,b in b })
        combined.merge(event.metadata ?? [:],uniquingKeysWith: { _,b in b })
        capture.state.withLock { $0.logs.append(event.message.description + combined.description + (event.error.map(String.init(describing:)) ?? "")) }
    }
}
private enum Baggage: ServiceContextKey { typealias Value = String }
private func identity(_ subject:String = "SENTINEL-PRIVATE-PRINCIPAL") -> VerifiedPrincipal {
    .init(subject:ScalarText(subject),issuer:ScalarText("SENTINEL-ISSUER"),resource:ScalarText("SENTINEL-URI"),scopes:[ScalarText("SENTINEL-SCOPE")])
}
private func observer(_ capture:Capture,active:Int = 1024,correlation:Bool = false) throws -> RequestInstrumentation {
    try .init(logger:Logger(label:"native",factory:{ _ in Handler(capture:capture) }),metrics:Factory(capture:capture),redaction:.init(recordCorrelation:correlation),maximumActive:active)
}
private func diag(_ method:WireMethod? = .callTool,_ subject:String = "SENTINEL-PRIVATE-PRINCIPAL") -> DiagnosticRequest {
    .init(method:method,transport:.inProcess,principal:identity(subject))
}
private func obsJSON(_ value:String) throws -> JSON { try JSONParser().parseWithReport(Array(value.utf8)).result }
private func obsCore(_ instrumentation:(any ServerRequestInstrumentation)? = nil) async throws -> Server {
    try await Server.make(info:obsJSON(#"{"name":"observed","version":"1"}"#),catalog:ServerCatalog(),
        cursors:CursorProtector(keys:[.init(identifier:ScalarText("k"),material:Data(repeating:3,count:32))],active:ScalarText("k"),clock:{1000}),instrumentation:instrumentation)
}
private func obsRequest(_ method:String = "tools/list") -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}".utf8)
}
private struct BadInstrumentation:ServerRequestInstrumentation {
    enum Mode:Sendable { case skip, twice, swallow, reject }
    let mode:Mode
    func withRequest(_ request:DiagnosticRequest,operation:@escaping @Sendable () async throws -> DiagnosticOutcome) async throws {
        switch mode {
        case .skip: return
        case .twice: _ = try await operation(); _ = try? await operation()
        case .swallow: _ = try? await operation()
        case .reject: throw InstrumentationFailure.capacity
        }
    }
}
private final class RetainingInstrumentation: ServerRequestInstrumentation {
    let operation = Mutex<(@Sendable () async throws -> DiagnosticOutcome)?>(nil)
    func withRequest(_ request:DiagnosticRequest,operation:@escaping @Sendable () async throws -> DiagnosticOutcome) async throws { self.operation.withLock { $0 = operation } }
}
@Suite struct NativeInstrumentation {
    @Test func injectedFacadesRedactInheritedMetadataErrorsAndContextBaggage() async throws {
        let capture = Capture(), instrumentation = try observer(capture)
        var inherited = ServiceContext.topLevel; inherited[Baggage.self] = "SENTINEL-ARGUMENT-SECRET"
        await ServiceContext.withValue(inherited) {
            await #expect(throws:CoreFailure.disconnected) {
                try await instrumentation.withRequest(diag()) {
                    #expect(ServiceContext.current?[Baggage.self] == nil)
                    #expect(DiagnosticTrace.current?.request.principal == identity())
                    throw CoreFailure.disconnected
                }
            }
            #expect(ServiceContext.current?[Baggage.self] == "SENTINEL-ARGUMENT-SECRET")
        }
        #expect(DiagnosticTrace.current == nil)
        let logs = capture.state.withLock { $0.logs.joined() }
        #expect(!logs.contains("SENTINEL") && !logs.contains("correlation"))
        #expect(logs.contains("disconnected") && logs.contains("tools/call"))
        #expect(await instrumentation.snapshot.active == 0); #expect(await instrumentation.snapshot.completed == 1)
        try await instrumentation.close(); try await instrumentation.close()
        #expect(capture.state.withLock { $0.destroyed.count == $0.metrics.count && !$0.duplicateDestroy })
    }
    @Test func concurrentPrincipalsHaveDistinctStructuredContextAndBoundedCorrelation() async throws {
        let capture = Capture(), instrumentation = try observer(capture,correlation:true), entered = Mutex(0), traces = Mutex(Set<String>())
        try await withThrowingTaskGroup(of:Void.self) { group in
            for index in 0..<12 { group.addTask {
                let subject = "principal-\(index)", correlation = try DiagnosticCorrelation("local-\(index)")
                try await instrumentation.withRequest(diag(.listTools,subject),correlation:correlation) {
                    entered.withLock { $0 += 1 }
                    while entered.withLock({ $0 }) < 12 { try Task.checkCancellation(); await Task.yield() }
                    try await withThrowingTaskGroup(of:Void.self) { children in
                        children.addTask {
                            let trace = try #require(DiagnosticTrace.current)
                            #expect(trace.request.principal == identity(subject) && trace.correlation == correlation)
                            _ = traces.withLock { $0.insert(trace.correlation.value) }
                        }
                        try await children.waitForAll()
                    }
                    return .completed
                }
            } }
            try await group.waitForAll()
        }
        #expect(traces.withLock { $0.count } == 12 && DiagnosticTrace.current == nil)
        #expect(await instrumentation.snapshot.instruments == 8); #expect(await instrumentation.snapshot.active == 0)
        #expect(capture.state.withLock { !$0.logs.joined().contains("principal-") })
        try await instrumentation.close()
        #expect(throws:InstrumentationFailure.invalidConfiguration) { try DiagnosticCorrelation("Bearer secret") }
        #expect(throws:InstrumentationFailure.invalidConfiguration) { try DiagnosticCorrelation(String(repeating:"x",count:129)) }
    }
    @Test func cancellationKeepsContextUntilOperationUnwindsAndCloseCannotDestroyLiveHandlers() async throws {
        let capture = Capture(), instrumentation = try observer(capture,active:1), entered = Mutex(false), unwind = Mutex(false)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                await #expect(throws:CancellationError.self) { try await instrumentation.withRequest(diag()) {
                    entered.withLock { $0 = true }
                    do { try await Task.sleep(for:.seconds(30)); return .completed }
                    catch { #expect(DiagnosticTrace.current?.request.principal == identity()); unwind.withLock { $0 = true }; throw error }
                } }
            }
            while !entered.withLock({ $0 }) { await Task.yield() }
            await #expect(throws:InstrumentationFailure.activeRequests) { try await instrumentation.close() }
            let effects = Mutex(0)
            await #expect(throws:InstrumentationFailure.capacity) { try await instrumentation.withRequest(diag()) { effects.withLock { $0 += 1 }; return .completed } }
            #expect(effects.withLock { $0 } == 0 && capture.state.withLock { $0.destroyed.isEmpty })
            group.cancelAll(); try await group.waitForAll()
        }
        #expect(unwind.withLock { $0 } && DiagnosticTrace.current == nil)
        #expect(await instrumentation.snapshot.active == 0); #expect(await instrumentation.snapshot.completed == 1)
        #expect(capture.state.withLock { $0.metrics.contains { $0.dimensions["outcome"] == "cancelled" && $0.values == [1] } })
        try await instrumentation.close()
        await #expect(throws:InstrumentationFailure.closed) { try await instrumentation.withRequest(diag()) { .completed } }
    }
    @Test func allFixedDimensionsRemainFiniteAndDestroyExactlyOnce() async throws {
        let capture = Capture(), instrumentation = try observer(capture)
        let methods:[WireMethod?] = WireMethod.allCases.map { $0 } + [nil]
        for method in methods { for transport in DiagnosticTransport.allCases { for outcome in DiagnosticOutcome.allCases {
            try await instrumentation.withRequest(.init(method:method,transport:transport,principal:identity(UUID().uuidString))) { outcome }
        } } }
        #expect(await instrumentation.snapshot.instruments == 665)
        #expect(capture.state.withLock { $0.metrics.count == 665 && $0.metrics.allSatisfy { Set($0.dimensions.keys).isSubset(of:["method","transport","outcome"]) } })
        #expect(capture.state.withLock { $0.metrics.filter { $0.kind == "timer" }.allSatisfy { $0.values.count == 8 && $0.values.allSatisfy { $0 >= 0 } } })
        try await instrumentation.close(); try await instrumentation.close()
        #expect(capture.state.withLock { $0.destroyed.count == 665 && !$0.duplicateDestroy })
    }
    @Test func admittedCoreUsesFrozenMethodTypedErrorsAndBalancedActivityGauges() async throws {
        let capture = Capture(), instrumentation = try observer(capture), server = try await obsCore(instrumentation)
        for method in ["tools/list","SENTINEL-UNSUPPORTED-METHOD"] {
            guard case .request(let ingress) = try await server.inspectIngress(obsRequest(method),principal:identity(),origin:ScalarText("SENTINEL-ORIGIN")) else { throw CoreFailure.invalidInput }
            try await server.dispatchEvents(ingress,mode:nil) { _ in }
            #expect(await ingress.discard() == false)
        }
        try await instrumentation.sample(server)
        #expect(capture.state.withLock { $0.metrics.contains { $0.dimensions["method"] == "tools/list" && $0.dimensions["outcome"] == "completed" } })
        #expect(capture.state.withLock { $0.metrics.contains { $0.dimensions["method"] == "unknown" && $0.dimensions["outcome"] == "protocolError" } })
        #expect(capture.state.withLock { !$0.logs.joined().contains("SENTINEL") && $0.metrics.filter { $0.kind == "gauge" }.allSatisfy { $0.values.last == 0 } })
        let activity = await server.activity; #expect(activity.active == 0 && activity.bufferedBytes == 0)
        try await instrumentation.close()
    }
    @Test func coreRejectsMissingRepeatedAndSwallowedInstrumentationInvocations() async throws {
        for mode in [BadInstrumentation.Mode.skip,.twice] {
            let server = try await obsCore(BadInstrumentation(mode:mode)), writes = Mutex(0)
            await #expect(throws:mode == .skip ? CoreFailure.invalidOutput : .duplicate) {
                try await server.dispatch(obsRequest(),principal:identity(),origin:ScalarText("origin")) { _ in writes.withLock { $0 += 1 } }
            }
            #expect(writes.withLock { $0 } == (mode == .skip ? 0 : 1))
            let activity = await server.activity; #expect(activity.active == 0 && activity.bufferedBytes == 0)
        }
        let swallowing = try await obsCore(BadInstrumentation(mode:.swallow))
        await #expect(throws:CoreFailure.disconnected) { try await swallowing.dispatch(obsRequest(),principal:identity(),origin:ScalarText("origin")) { _ in throw CoreFailure.disconnected } }
        let rejecting = try await obsCore(BadInstrumentation(mode:.reject))
        guard case .request(let ingress) = try await rejecting.inspectIngress(obsRequest(),principal:identity(),origin:ScalarText("origin")) else { throw CoreFailure.invalidInput }
        await #expect(throws:InstrumentationFailure.capacity) { try await rejecting.dispatchEvents(ingress,mode:nil) { _ in } }
        #expect(await ingress.discard() == false)
        let activity = await rejecting.activity; #expect(activity.bufferedBytes == 0 && activity.active == 0)
    }
    @Test func returnedInstrumentationCannotStartRetainedOperationLater() async throws {
        let instrumentation = RetainingInstrumentation(), server = try await obsCore(instrumentation), effects = Mutex(0)
        await #expect(throws:CoreFailure.invalidOutput) { try await server.dispatch(obsRequest(),principal:identity(),origin:ScalarText("origin")) { _ in effects.withLock { $0 += 1 } } }
        let operation = try #require(instrumentation.operation.withLock { $0 })
        await #expect(throws:CoreFailure.duplicate) { _ = try await operation() }
        #expect(effects.withLock { $0 } == 0)
        let activity = await server.activity; #expect(activity.active == 0 && activity.bufferedBytes == 0)
    }
    @Test func providerPayloadAndPoisonedBudgetNeverBecomeDiagnosticFields() async throws {
        let capture = Capture(), instrumentation = try observer(capture), budget = Mutex<RequestBudget?>(nil)
        let tool = ToolRegistration(definition:try obsJSON(#"{"name":"secret","inputSchema":{"type":"object"}}"#)) { input,context in
            guard case .value(let value) = input else { throw CoreFailure.invalidInput }
            #expect(value.objectValue?["private"]?.stringValue == "SENTINEL-ARGUMENT")
            #expect(DiagnosticTrace.current?.request.principal == context.principal)
            budget.withLock { $0 = context.budget }
            do { try await context.budget.consume(UInt64.max) } catch {}
            return try obsJSON(#"{"resultType":"complete","content":[{"type":"text","text":"SENTINEL-RESULT"}]}"#)
        }
        let server = try await Server.make(info:obsJSON(#"{"name":"redacted","version":"1"}"#),catalog:ServerCatalog(tools:[tool]),cursors:CursorProtector(keys:[.init(identifier:ScalarText("k"),material:Data(repeating:2,count:32))],active:ScalarText("k"),clock:{1000}),instrumentation:instrumentation)
        let bytes = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"secret","arguments":{"private":"SENTINEL-ARGUMENT"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
        guard case .request(let ingress) = try await server.inspectIngress(bytes,principal:identity(),origin:ScalarText("SENTINEL-ORIGIN")) else { throw CoreFailure.invalidInput }
        let writes = Mutex(0)
        try await server.dispatchEvents(ingress,mode:nil) { _ in writes.withLock { $0 += 1 } }
        let account = try #require(budget.withLock { $0 }), snapshot = await account.snapshot
        #expect(snapshot.isTerminal && snapshot.terminalTransitions == 1 && snapshot.activeReservations == 0)
        #expect(writes.withLock { $0 } == 1)
        #expect(capture.state.withLock { !$0.logs.joined().contains("SENTINEL") && $0.metrics.contains { $0.dimensions["outcome"] == "protocolError" } })
        try await instrumentation.close()
    }
    @Test func repeatedReleasedAdaptersDestroyTheirInstrumentsWithoutExplicitClose() async throws {
        let capture = Capture()
        for _ in 0..<16 {
            weak var released:RequestInstrumentation?
            do {
                let scope = try observer(capture); released = scope
                try await scope.withRequest(diag()) { .completed }
            }
            #expect(released == nil)
        }
        #expect(capture.state.withLock { $0.metrics.count == 128 && $0.destroyed.count == 128 && !$0.duplicateDestroy })
    }
    @Test func foreignAdmittedIdentityNeverEntersWrongServerDiagnosticsOrConsumesTicket() async throws {
        let correctCapture = Capture(), wrongCapture = Capture(), correct = try observer(correctCapture), wrong = try observer(wrongCapture)
        let owner = try await obsCore(correct), stranger = try await obsCore(wrong)
        guard case .request(let ingress) = try await owner.inspectIngress(obsRequest(),principal:identity("SENTINEL-FOREIGN-IDENTITY"),origin:ScalarText("original")) else { throw CoreFailure.invalidInput }
        await #expect(throws:CoreFailure.invalidInput) { try await stranger.dispatchEvents(ingress,mode:nil) { _ in Issue.record("Foreign write") } }
        #expect(await wrong.snapshot.completed == 0)
        #expect(wrongCapture.state.withLock { $0.logs.isEmpty && $0.metrics.count == 5 && $0.metrics.allSatisfy { $0.values.isEmpty } })
        let writes = Mutex(0)
        try await owner.dispatchEvents(ingress,mode:nil) { _ in writes.withLock { $0 += 1 } }
        #expect(writes.withLock { $0 } == 1); #expect(await correct.snapshot.completed == 1)
        #expect(await ingress.discard() == false)
        try await correct.close(); try await wrong.close()
    }
    @Test func omittedInstrumentationLeavesWireAndHostDefaultsUntouched() async throws {
        let capture = Capture(), unused = try observer(capture), server = try await obsCore()
        let response = try #require(await server.handle(obsRequest(),principal:identity(),origin:ScalarText("origin")))
        #expect(try obsJSON(String(decoding:response,as:UTF8.self)).objectValue?["result"] != nil)
        #expect(capture.state.withLock { $0.logs.isEmpty && $0.metrics.count == 5 && $0.metrics.allSatisfy { $0.values.isEmpty } })
        #expect(await unused.snapshot.completed == 0)
        try await unused.close()
    }
    @Test func supplementalNamesAndMiddlewarePayloadStayInFixedDiagnosticDimensions() async throws {
        let capture = Capture(), instrumentation = try observer(capture)
        let namespace = ScalarText("com.example/SENTINEL-NAMESPACE"), method = ScalarText("com.example/SENTINEL-NAMESPACE/run"), tag = ScalarText("com.example/SENTINEL-NAMESPACE/done")
        let registration = ExtensionRegistration(identifier: namespace, settingsSchema: .boolean(true), requests: [.init(method: method, parametersSchema: .boolean(true), resultTypes: [tag]) { _, context in
            #expect(DiagnosticTrace.current?.request.method == nil)
            #expect(DiagnosticTrace.current?.request.principal == context.principal)
            return try obsJSON(#"{"resultType":"com.example/SENTINEL-NAMESPACE/done"}"#)
        }], results: [.init(type: tag, schema: .boolean(true))])
        let middleware = RequestMiddleware { request, next in
            #expect(request.context.method.rawValue == method.description)
            return try await next.proceed(for: request)
        }
        let server = try await Server.make(info: obsJSON(#"{"name":"diagnostics","version":"1"}"#), catalog: ServerCatalog(extensions: [registration]),
            cursors: CursorProtector(keys: [.init(identifier:ScalarText("k"),material:Data(repeating:2,count:32))],active:ScalarText("k"),clock:{1000}), instrumentation: instrumentation, middleware: [middleware])
        let bytes = Data(#"{"jsonrpc":"2.0","id":"SENTINEL-ID","method":"com.example/SENTINEL-NAMESPACE/run","params":{"private":"SENTINEL-ARGUMENT","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"com.example/SENTINEL-NAMESPACE":{"private":"SENTINEL-SETTING"}}}}}}"#.utf8)
        _ = try await server.handle(bytes, principal: identity(), origin: ScalarText("SENTINEL-ORIGIN"))
        try await instrumentation.sample(server)
        #expect(capture.state.withLock { $0.metrics.contains { $0.dimensions["method"] == "unknown" && $0.dimensions["outcome"] == "completed" } })
        #expect(capture.state.withLock { !$0.logs.joined().contains("SENTINEL") && $0.metrics.allSatisfy { !$0.dimensions.values.joined().contains("SENTINEL") } })
        #expect(await server.activity.active == 0)
        try await instrumentation.close()
        #expect(capture.state.withLock { $0.destroyed.count == $0.metrics.count && !$0.duplicateDestroy })
    }

}
