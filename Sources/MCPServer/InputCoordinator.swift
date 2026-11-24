// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import JSON
import MCPProtocol

struct PreparedInput: Sendable {
    let descriptor: InputDescriptor
    let response: FrozenWireDefinition?
    let supplemental: PreparedExtensionInput?
    let features: Set<ClientFeature>
    let form: PreparedSchema?
    let samplingTools: [ScalarText: PreparedSchema]
}
struct PreparedRoundPlan: Sendable {
    let provider: MultiRoundProvider
    let inputs: [ScalarText: PreparedInput]
    let binding: String
    let weight: UInt64
    static func prepare(_ provider: MultiRoundProvider, definition: JSON, scopes: Set<ScalarText>, features: Set<ClientFeature>,
        wire: PreparedWire, generation: UInt64, budget: RequestBudget, supplemental: [ScalarText: PreparedExtensionInput] = [:]) async throws -> Self {
        guard !provider.version.description.isEmpty, provider.version.description.utf8.count <= 256,
              provider.inputs.count <= 64 else { throw CoreFailure.invalidInput }
        var inputs: [ScalarText: PreparedInput] = [:], weight: UInt64 = 0
        for descriptor in provider.inputs {
            guard !descriptor.identifier.description.isEmpty, descriptor.identifier.description.utf8.count <= 256,
                  inputs[descriptor.identifier] == nil else { throw CoreFailure.invalidInput }
            if let method = descriptor.request.objectValue?["method"]?.stringValue, let declared = supplemental[ScalarText(method)] {
                guard try await SchemaPreparation.validate(descriptor.request, against: declared.request, budget: budget) else { throw CoreFailure.invalidInput }
                inputs[descriptor.identifier] = .init(descriptor: descriptor, response: nil, supplemental: declared, features: [], form: nil, samplingTools: [:])
                let encoded = try await budget.performJSON { try WireCodec.write(descriptor.request, limits: $0) }
                weight += UInt64(encoded.count) * 16 + 4096
                guard weight <= 8_388_608 else { throw CoreFailure.limit }
                continue
            }
            guard try await wire.validate(descriptor.request, as: .InputRequest, budget: budget) else { throw CoreFailure.invalidInput }
            let object = descriptor.request.objectValue!, params = object["params"]?.objectValue
            let response: FrozenWireDefinition?
            let features: Set<ClientFeature>, form: PreparedSchema?
            var samplingTools: [ScalarText: PreparedSchema] = [:]
            switch object["method"]!.stringValue! {
            case "roots/list": response = .ListRootsResult; features = [.roots]; form = nil
            case "sampling/createMessage":
                response = .CreateMessageResult; form = nil
                var required: Set<ClientFeature> = [.sampling]
                if params?["tools"] != nil || params?["toolChoice"] != nil { required.insert(.samplingTools) }
                if let context = params?["includeContext"]?.stringValue, context != "none" { required.insert(.samplingContext) }
                for message in params?["messages"]?.arrayValue ?? [] {
                    let content = message.objectValue?["content"]
                    for block in content?.arrayValue ?? content.map({ [$0] }) ?? [] {
                        if ["tool_use", "tool_result"].contains(block.objectValue?["type"]?.stringValue ?? "") { required.insert(.samplingTools) }
                    }
                }
                let tools = params?["tools"]?.arrayValue ?? []
                guard tools.count <= 64 else { throw CoreFailure.limit }
                for tool in tools {
                    let name = ScalarText(tool.objectValue!["name"]!.stringValue!)
                    guard samplingTools[name] == nil else { throw CoreFailure.invalidInput }
                    let prepared = try await SchemaPreparation.prepare(tool.objectValue!["inputSchema"]!, identifier: generation, budget: budget)
                    samplingTools[name] = prepared; weight += prepared.logicalRetainedUpperBound
                }
                try await SamplingValidation.history(params!, budget: budget)
                features = required
            default:
                response = .ElicitResult
                if params?["mode"]?.stringValue == "url" { features = [.elicitationURL]; form = nil }
                else {
                    features = [.elicitationForm]
                    form = try await SchemaPreparation.prepare(params!["requestedSchema"]!, identifier: generation, budget: budget)
                }
            }
            let bytes = try await budget.performJSON { try WireCodec.write(descriptor.request, limits: $0) }
            weight += UInt64(bytes.count) * 16 + (form?.logicalRetainedUpperBound ?? 0) + 4096
            guard weight <= 8_388_608 else { throw CoreFailure.limit }
            inputs[descriptor.identifier] = .init(descriptor: descriptor, response: response, supplemental: nil, features: features, form: form, samplingTools: samplingTools)
        }
        if let ids = provider.inputOnlyReconstruction {
            guard ids.count <= 64, Set(ids).count == ids.count, ids.allSatisfy({ inputs[$0] != nil }) else { throw CoreFailure.invalidInput }
            if case .consuming = provider.replay { throw CoreFailure.invalidPolicy }
        }
        let requests = try await RuntimeJSON.object(provider.inputs.map { .init($0.identifier.description, value: $0.request) }, budget: budget)
        let replay: String
        switch provider.replay { case .integrityOnly: replay = "integrity-only"; case .consuming: replay = "consuming" }
        var bindingMembers: [JSONMember] = [.init("version", value: .string(provider.version.description)),
            .init("features", value: .array(features.map(\.rawValue).sorted().map(JSON.string))),
            .init("replay", value: .string(replay)),
            .init("reconstruction", value: provider.inputOnlyReconstruction.map { .array($0.map { .string($0.description) }) } ?? .null),
            .init("definition", value: definition), .init("inputs", value: requests),
            .init("scopes", value: .array(scopes.sorted { $0.description.utf8.lexicographicallyPrecedes($1.description.utf8) }.map { .string($0.description) }))]
        if !supplemental.isEmpty {
            let declarations = try await RuntimeJSON.object(supplemental.map { entry in
                .init(entry.key.description, value: entry.value.response.raw)
            }, budget: budget)
            bindingMembers.append(.init("supplementalResponses", value: declarations))
        }
        let projection = try await RuntimeJSON.object(bindingMembers, budget: budget)
        return .init(provider: provider, inputs: inputs, binding: RequestStateProtector.hex(try await ParameterBinding.digest(.value(projection), budget: budget)), weight: weight)
    }
}

enum InputCoordinator {
    static func execute(_ request: IncomingEnvelope.Request, input: JSONPresence<JSON>, context: RequestContext,
        plan: PreparedRoundPlan, protector: RequestStateProtector?, wire: PreparedWire, requestWork: UInt64, middleware: [RequestMiddleware] = []) async throws -> JSON {
        let budget = context.budget
        let empty = try await RuntimeJSON.object([], budget: budget)
        var claims: ContinuationClaims?, expected: [ScalarText] = [], responses = empty.objectValue!
        let supplied = request.params["inputResponses"]?.objectValue
        let token = request.params["requestState"]?.stringValue
        if let token {
            guard let protector else { throw CoreFailure.invalidState }
            var c = try await protector.open(token, budget: budget)
            let principal = try await protector.principalBinding(context.principal, budget: budget)
            let parameters = RequestStateProtector.hex(try await parameterBinding(request, context: context))
            let id = RequestStateProtector.hex(try await ParameterBinding.digest(.value(context.id.value), budget: budget))
            guard ScalarText(c.principal) == ScalarText(principal), c.method.utf8.elementsEqual(context.method.rawValue.utf8),
                  ScalarText(c.parameters) == ScalarText(parameters), ScalarText(c.plan) == ScalarText(plan.binding),
                  ScalarText(c.priorID) != ScalarText(id), c.attempts < c.maximumAttempts,
                  requestWork <= c.maximumWork - c.spent else { throw CoreFailure.invalidState }
            c.attempts += 1; c.spent += requestWork; c.priorID = id
            expected = c.pending.map(ScalarText.init)
            guard expected.allSatisfy({ plan.inputs[$0] != nil }), let received = c.responses.objectValue else { throw CoreFailure.invalidState }
            responses = received; claims = c
        } else if supplied != nil {
            guard let reconstruction = plan.provider.inputOnlyReconstruction else { throw CoreFailure.invalidInput }
            expected = reconstruction
        }
        for identifier in expected {
            guard let descriptor = plan.inputs[identifier] else { throw CoreFailure.invalidState }
            try await require(descriptor, context: context, wire: wire)
            if let response = supplied?[identifier.description] {
                try await validate(response, expected: descriptor, context: context, wire: wire)
                responses = try await RuntimeJSON.overlay(.object(responses), members: [.init(identifier.description, value: response)], budget: budget).objectValue!
            } else if let saved = responses[identifier.description] {
                try await validate(saved, expected: descriptor, context: context, wire: wire)
            }
        }
        let missing = expected.filter { responses[$0.description] == nil }
        if !missing.isEmpty {
            if var c = claims {
                c.responses = .object(responses)
                return try await intermediate(.init(inputs: missing, state: presence(c)), context: context, request: request,
                    plan: plan, protector: protector, wire: wire, requestWork: requestWork, previous: c, advance: false)
            }
            return try await intermediate(.init(inputs: expected, inputOnly: true), context: context, request: request,
                plan: plan, protector: protector, wire: wire, requestWork: requestWork, previous: nil, advance: false)
        }
        var effect: ContinuationEffect?
        if let c = claims, case .consuming(let store) = plan.provider.replay {
            try context.checkCancellation()
            let allowance = store.maximumSettlementWork
            guard allowance > 0, allowance <= 16_777_216 else { throw CoreFailure.invalidPolicy }
            try await budget.consume(allowance)
            let cleanup = try RequestBudget(workUnits: allowance)
            let keyValue = try await RuntimeJSON.object([.init("purpose", value: .string("Swift-MCP/continuation-consumption/v1")),
                .init("namespace", value: .string(c.namespace)), .init("epoch", value: .string(c.epoch)),
                .init("chain", value: .string(c.chain)), .init("round", value: .number(JSONNumber(integer: c.logicalRound)))], budget: budget)
            let key = try await ParameterBinding.digest(.value(keyValue), budget: budget)
            let receipt: ConsumptionClaim
            do { receipt = try await store.claim(key: key, expiresAt: c.expires, budget: budget) }
            catch let failure as StateConsumptionStore.Failure where failure == .alreadyClaimed || failure == .expired { throw CoreFailure.invalidState }
            effect = .init(store: store, claim: receipt, cleanup: cleanup)
        }
        let invoked = Mutex(false)
        let invocation = RoundInvocation(state: claims.map(presence) ?? .absent, responses: responses,
            attempt: claims?.attempts ?? 1, isRetry: claims != nil || supplied != nil, effect: effect)
        let outcome: ProviderOutcome
        do {
            try context.checkCancellation()
            outcome = try await MiddlewarePipeline.run(middleware, context: context) {
                try context.checkCancellation(); invoked.withLock { $0 = true }
                return try await plan.provider.handler(input, invocation, context)
            }
        } catch {
            if let effect {
                if invoked.withLock({ $0 }) { try await effect.finish(allowReleased: true) } else { try await effect.abandonBeforeProvider() }
            }
            throw error
        }
        if let effect { try await effect.finish() }
        try context.checkCancellation()
        switch outcome {
        case .complete(let raw):
            guard raw.objectValue?["resultType"]?.stringValue == "complete" else { throw CoreFailure.invalidOutput }; return raw
        case .supplemental(let raw):
            guard context.extensionRegistry.result(raw, method: context.method, negotiated: context.extensions) != nil else { throw CoreFailure.invalidOutput }
            return raw
        case .inputRequired(let instruction):
            return try await intermediate(instruction, context: context, request: request, plan: plan, protector: protector,
                wire: wire, requestWork: requestWork, previous: claims, advance: true)
        }
    }
    private static func parameterBinding(_ request: IncomingEnvelope.Request, context: RequestContext) async throws -> [UInt8] {
        if context.method.core != nil { return try await ParameterBinding.forRequest(request, budget: context.budget) }
        return try await ParameterBinding.forSupplementalRequest(request, context: context)
    }
    private static func require(_ input: PreparedInput, context: RequestContext, wire: PreparedWire) async throws {
        if let supplemental = input.supplemental {
            guard context.extensions[supplemental.namespace.description] != nil else { throw CoreFailure.missingCapability }
        }
        try await ProviderDispatch.require([], features: input.features, context: context, wire: wire)
    }
    private static func presence(_ c: ContinuationClaims) -> JSONPresence<JSON> {
        c.statePresence == 0 ? .absent : c.statePresence == 1 ? .null : .value(c.state)
    }
    private static func validate(_ response: JSON, expected: PreparedInput, context: RequestContext, wire: PreparedWire) async throws {
        if let supplemental = expected.supplemental {
            guard context.extensions[supplemental.namespace.description] != nil, try await SchemaPreparation.validate(response, against: supplemental.response, budget: context.budget) else { throw CoreFailure.invalidInput }; return
        }
        guard let definition = expected.response, try await wire.validate(response, as: definition, budget: context.budget) else { throw CoreFailure.invalidInput }
        if expected.response == .ElicitResult {
            let object = response.objectValue!
            if object["action"]?.stringValue == "accept", let form = expected.form {
                guard let content = object["content"], try await SchemaPreparation.validate(content, against: form, budget: context.budget) else { throw CoreFailure.invalidInput }
            } else if object["content"] != nil { throw CoreFailure.invalidInput }
        }
        if expected.response == .CreateMessageResult {
            let content = response.objectValue?["content"]
            let blocks = content?.arrayValue ?? content.map({ [$0] }) ?? []
            try await SamplingValidation.response(response, request: expected.descriptor.request, tools: expected.samplingTools, budget: context.budget)
            if blocks.contains(where: { ["tool_use","tool_result"].contains($0.objectValue?["type"]?.stringValue ?? "") }) {
                try await ProviderDispatch.require([], features: [.samplingTools], context: context, wire: wire)
            }
        }
    }
    private static func intermediate(_ instruction: InputInstruction, context: RequestContext, request: IncomingEnvelope.Request,
        plan: PreparedRoundPlan, protector: RequestStateProtector?, wire: PreparedWire, requestWork: UInt64,
        previous: ContinuationClaims?, advance: Bool) async throws -> JSON {
        let budget = context.budget
        guard instruction.inputs != nil || { if case .absent = instruction.state { return false }; return true }() else { throw CoreFailure.invalidOutput }
        let ids = instruction.inputs ?? []
        guard ids.count <= (protector?.policy.maximumInputs ?? 16), Set(ids).count == ids.count,
              ids.allSatisfy({ plan.inputs[$0] != nil }) else { throw CoreFailure.invalidOutput }
        for id in ids { try await require(plan.inputs[id]!, context: context, wire: wire) }
        var members: [JSONMember] = [.init("resultType", value: .string("input_required"))]
        if let ids = instruction.inputs {
            members.append(.init("inputRequests", value: try await RuntimeJSON.object(ids.map { .init($0.description, value: plan.inputs[$0]!.descriptor.request) }, budget: budget)))
        }
        if instruction.inputOnly {
            guard case .absent = instruction.state, let reconstruction = plan.provider.inputOnlyReconstruction,
                  previous == nil, Set(ids).isSubset(of: Set(reconstruction)) else { throw CoreFailure.invalidOutput }
        } else {
            guard let protector else { throw CoreFailure.invalidPolicy }
            let state: JSON, tag: Int
            switch instruction.state { case .absent: state = .null; tag = 0; case .null: state = .null; tag = 1; case .value(let value): state = value; tag = 2 }
            var limits = JSONLimits.balanced; limits[.outputBytes] = UInt64(protector.policy.maximumStateBytes)
            _ = try await budget.performJSON(limits: limits) { try WireCodec.write(state, limits: $0) }
            var c: ContinuationClaims
            if var old = previous {
                if advance {
                    guard old.logicalRound < old.maximumAttempts else { throw CoreFailure.limit }
                    old.logicalRound += 1; old.responses = try await RuntimeJSON.object([], budget: budget)
                }
                old.state = state; old.statePresence = tag
                // Partial retries preserve the full trusted descriptor set and
                // validated inputs; only the missing subset is re-requested.
                if advance { old.pending = ids.map(\.description) }
                c = old
            } else {
                let now = protector.clock(), expiry = now.addingReportingOverflow(protector.policy.lifetimeMilliseconds)
                guard now >= 0, !expiry.overflow, requestWork <= protector.policy.maximumChainWork else { throw CoreFailure.invalidPolicy }
                c = .init(version: 1, bindingVersion: 1, namespace: protector.namespace.description, epoch: protector.epoch.description,
                    principal: try await protector.principalBinding(context.principal, budget: budget), method: context.method.rawValue,
                    parameters: RequestStateProtector.hex(try await parameterBinding(request, context: context)), plan: plan.binding,
                    issued: now, expires: expiry.partialValue, attempts: 1, spent: requestWork, logicalRound: 1,
                    maximumAttempts: protector.policy.maximumAttempts, maximumWork: protector.policy.maximumChainWork, chain: UUID().uuidString,
                    priorID: RequestStateProtector.hex(try await ParameterBinding.digest(.value(context.id.value), budget: budget)),
                    pending: ids.map(\.description), responses: try await RuntimeJSON.object([], budget: budget), state: state, statePresence: tag)
            }
            members.append(.init("requestState", value: .string(try await protector.seal(c, budget: budget))))
        }
        let raw = try await RuntimeJSON.object(members, budget: budget)
        if context.method.core != nil {
            guard try await wire.validate(raw, as: .InputRequiredResult, budget: budget) else { throw CoreFailure.invalidOutput }
        } else {
            guard try await wire.validate(raw, as: .Result, budget: budget) else { throw CoreFailure.invalidOutput }
        }
        return raw
    }
}
