// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

enum SupplementalDispatch {
    static func execute(_ request: IncomingEnvelope.Request, context: RequestContext, plan: PreparedExtensionRequest,
        wire: PreparedWire, info: JSON, maximumBytes: Int, mirror: RequestMirrorValidator?, continuations: RequestStateProtector?,
        requestWork: UInt64, middleware: [RequestMiddleware]) async throws -> JSON {
        let budget = context.budget
        try await ProviderDispatch.require(plan.registration.requiredScopes, features: [], context: context, wire: wire)
        let application = try await RuntimeJSON.object(request.params.filter { !["_meta", "requestState", "inputResponses"].contains($0.key.string) }, budget: budget)
        guard try await SchemaPreparation.validate(application, against: plan.parameters, budget: budget) else { throw CoreFailure.invalidInput }
        if let mirror { try await mirror(plan.headers, .value(application), budget) }
        let result: JSON
        if let rounds = plan.rounds {
            if let state = request.params["requestState"], state.stringValue == nil { throw CoreFailure.invalidInput }
            if let input = request.params["inputResponses"] {
                guard let responses = input.objectValue, responses.count <= 64 else { throw CoreFailure.invalidInput }
                // Literal supplemental admission permits only a declared core or
                // supplemental response shape. Unrelated valid keys remain data.
                for value in responses {
                    var valid = false
                    for prepared in rounds.inputs.values {
                        if let supplemental = prepared.supplemental {
                            if try await SchemaPreparation.validate(value.value, against: supplemental.response, budget: budget) { valid = true; break }
                        } else if let response = prepared.response, try await wire.validate(value.value, as: response, budget: budget) { valid = true; break }
                    }
                    guard valid else { throw CoreFailure.invalidInput }
                }
            }
            result = try await InputCoordinator.execute(request, input: .value(application), context: context, plan: rounds,
                protector: continuations, wire: wire, requestWork: requestWork, middleware: middleware)
        } else {
            guard request.params["requestState"] == nil, request.params["inputResponses"] == nil, let handler = plan.registration.handler else { throw CoreFailure.invalidInput }
            result = try await MiddlewarePipeline.run(middleware, context: context) { try await handler(.value(application), context) }
        }
        try context.checkCancellation()
        guard result.objectValue != nil else { throw CoreFailure.invalidOutput }
        var limits = JSONLimits.balanced; limits[.outputBytes] = UInt64(maximumBytes)
        let bytes = try await budget.performJSON(limits: limits) { try WireCodec.write(result, limits: $0) }
        try await budget.consume(UInt64(bytes.count) * 16 + 1)
        let supplied: JSON
        if let declared = result.objectValue?["_meta"] { guard declared.objectValue != nil else { throw CoreFailure.invalidOutput }; supplied = declared } else { supplied = try await RuntimeJSON.object([], budget: budget) }
        let meta = try await RuntimeJSON.overlay(supplied, members: [.init(ProtocolMetadata.serverInfo, value: info)], budget: budget)
        let final = try await RuntimeJSON.overlay(result, members: [.init("_meta", value: meta)], budget: budget)
        guard try await wire.validate(meta, as: .ResultMetaObject, budget: budget) else { throw CoreFailure.invalidOutput }
        if result.objectValue?["resultType"]?.stringValue == "input_required" {
            guard plan.rounds != nil, try await wire.validate(final, as: .Result, budget: budget) else { throw CoreFailure.invalidOutput }
        } else {
            guard let shape = context.extensionRegistry.result(final, method: context.method, negotiated: context.extensions),
                  try await SchemaPreparation.validate(final, against: shape.schema, budget: budget) else { throw CoreFailure.invalidOutput }
        }
        guard !(await budget.snapshot.isTerminal) else { throw RequestBudget.Failure.exhausted }
        return final
    }
}
