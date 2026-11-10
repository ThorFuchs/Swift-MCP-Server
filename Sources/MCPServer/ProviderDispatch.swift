// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

struct ProtocolRejection: Error, Sendable {
    let error: ModernProtocolError
    /// `-32021` naming one required extension: `{"extensions": {identifier: {}}}`.
    static func missingExtension(_ identifier: ScalarText, wire: PreparedWire, budget: RequestBudget) async throws -> Self {
        let empty = try await RuntimeJSON.object([], budget: budget)
        let extensions = try await RuntimeJSON.object([.init(identifier.description, value: empty)], budget: budget)
        let required = try await RuntimeJSON.object([.init("extensions", value: extensions)], budget: budget)
        guard let plan = wire.plans[.ClientCapabilities],
              let projection = try await budget.performJSON({ try plan.project(required, as: MCPWire.ClientCapabilities.self, limits: $0) })
        else { throw CoreFailure.invalidOutput }
        return .init(error: .missingCapability(required: projection))
    }
}
public typealias RequestMirrorValidator = @Sendable ([HeaderDeclaration], JSONPresence<JSON>, RequestBudget) async throws -> Void

enum ProviderDispatch {
    static func require(_ scopes: Set<ScalarText>, features: Set<ClientFeature>, context: RequestContext, wire: PreparedWire) async throws {
        try context.checkCancellation()
        guard scopes.count <= 256 else { throw CoreFailure.limit }
        try await context.budget.consume(UInt64(scopes.reduce(0) { $0 + $1.description.utf8.count + 1 }) * 4 + 1)
        if let validator = context.scopeValidator { try await validator(scopes,context.budget) }
        guard context.principal.scopes.isSuperset(of: scopes) else { throw CoreFailure.insufficientScopes }
        var missing = Set<ClientFeature>()
        for feature in features {
            var value: JSON? = .object(context.capabilities)
            for part in feature.path {
                if let object = value?.objectValue {
                    try await context.budget.consume(UInt64(object.reduce(0) { $0 + $1.key.string.utf8.count + part.utf8.count + 1 }))
                    value = object[part]
                } else { value = nil }
            }
            if value?.objectValue == nil {
                // The frozen 2026-07-28 elicitation contract explicitly makes
                // elicitation:{} equivalent to form:{}; url-only does not imply
                // form. Keep the original declaration/binding unchanged.
                try await context.budget.consume(UInt64(context.capabilities.reduce(0) { $0 + $1.key.string.utf8.count + 12 }))
                let implicitForm = feature == .elicitationForm && context.capabilities["elicitation"]?.objectValue?.isEmpty == true
                if !implicitForm { missing.insert(feature) }
            }
        }
        if !missing.isEmpty {
            let empty = try await RuntimeJSON.object([], budget: context.budget)
            var top: [String: [JSONMember]] = [:], direct: [JSONMember] = []
            for feature in missing.sorted(by: { $0.rawValue < $1.rawValue }) {
                let path = feature.path
                if path.count == 1 { direct.append(.init(path[0], value: empty)) }
                else { top[path[0], default: []].append(.init(path[1], value: empty)) }
            }
            for key in top.keys.sorted() {
                direct.removeAll { $0.key.string == key }
                direct.append(.init(key, value: try await RuntimeJSON.object(top[key]!, budget: context.budget)))
            }
            let required = try await RuntimeJSON.object(direct, budget: context.budget)
            let plan = wire.plans[.ClientCapabilities]!
            let projection = try await context.budget.performJSON { try plan.project(required, as: MCPWire.ClientCapabilities.self, limits: $0) }
            guard let projection else { throw CoreFailure.invalidOutput }
            throw ProtocolRejection(error: .missingCapability(required: projection))
        }
    }
    static func execute(_ request: IncomingEnvelope.Request, context: RequestContext, snapshot: CatalogSnapshot,
        wire: PreparedWire, info: JSON, cursor: CursorProtector, instance: ScalarText,
        pageSize: Int, maximumBytes: Int, mirror: RequestMirrorValidator?, continuations: RequestStateProtector?, requestWork: UInt64, loggingEnabled: Bool, middleware: [RequestMiddleware] = []) async throws -> JSON {
        let budget = context.budget, params = request.params
        try await budget.consume(UInt64(params.reduce(0) { $0 + $1.key.string.utf8.count + 1 }) * 16 + 1)
        let result: JSON
        switch context.method {
        case .discover:
            let empty = try await RuntimeJSON.object([], budget: budget)
            let changed = try await RuntimeJSON.object([.init("listChanged", value: .boolean(true))], budget: budget)
            var caps: [JSONMember] = [.init("tools", value: snapshot.listChanged.contains(.listTools) ? changed : empty),
                .init("resources", value: snapshot.listChanged.contains(.listResources) ? changed : empty),
                .init("prompts", value: snapshot.listChanged.contains(.listPrompts) ? changed : empty)]
            if loggingEnabled { caps.append(.init("logging", value: empty)) }
            if snapshot.completion != nil { caps.append(.init("completions", value: empty)) }
            if !snapshot.extensions.entries.isEmpty {
                caps.append(.init("extensions", value: try await RuntimeJSON.object(snapshot.extensions.entries.map { .init($0.identifier.description, value: $0.capabilities) }, budget: budget)))
            }
            result = try await RuntimeJSON.object([.init("resultType", value: .string("complete")),
                .init("supportedVersions", value: .array([.string(ProtocolMetadata.version)])),
                .init("capabilities", value: try await RuntimeJSON.object(caps, budget: budget))], budget: budget)
        case .listTools, .listResources, .listResourceTemplates, .listPrompts:
            var visible: [JSON] = []
            func include(_ scopes: Set<ScalarText>, definition: JSON) async throws {
                try await budget.consume(UInt64(scopes.reduce(0) { $0 + $1.description.utf8.count + 1 }) * 4 + 1)
                if context.principal.scopes.isSuperset(of: scopes) { visible.append(definition) }
            }
            let field: String
            switch context.method {
            case .listTools:
                field = "tools"; for value in snapshot.tools { try await include(value.registration.requiredScopes, definition: value.registration.definition) }
            case .listResources:
                field = "resources"; for value in snapshot.resources { try await include(value.requiredScopes, definition: value.definition) }
            case .listResourceTemplates:
                field = "resourceTemplates"; for value in snapshot.templates { try await include(value.requiredScopes, definition: value.definition) }
            default:
                field = "prompts"; for value in snapshot.prompts { try await include(value.requiredScopes, definition: value.definition) }
            }
            let salient = try await RuntimeJSON.object(params.filter { $0.key.string != "cursor" && $0.key.string != "_meta" }, budget: budget)
            let binding = CursorContext(principal: context.principal, method: context.method.core!, parameters: salient,
                generation: snapshot.generation, catalogInstance: instance)
            let offset: Int
            if let token = params["cursor"] { guard let text = token.stringValue else { throw CoreFailure.invalidCursor }; offset = try await cursor.open(text, context: binding, budget: budget) }
            else { offset = 0 }
            guard offset <= visible.count else { throw CoreFailure.invalidCursor }
            let end = offset + min(pageSize, visible.count - offset)
            var members: [JSONMember] = [.init("resultType", value: .string("complete")), .init(field, value: .array(Array(visible[offset..<end])))]
            if end < visible.count { members.append(.init("nextCursor", value: .string(try await cursor.seal(offset: end, context: binding, budget: budget)))) }
            result = try await RuntimeJSON.object(members, budget: budget)
        case .callTool:
            guard let name = params["name"]?.stringValue, name.utf8.count <= 4096 else { throw CoreFailure.invalidInput }
            guard let tool = snapshot.toolIndex[ScalarText(name)] else { throw CoreFailure.unknownProvider }
            try await require(tool.registration.requiredScopes, features: tool.registration.requiredFeatures, context: context, wire: wire)
            let presence = params.presence(of: "arguments")
            let input: JSON
            switch presence { case .absent: input = try await RuntimeJSON.object([], budget: budget); case .null: input = .null; case .value(let value): input = value }
            guard try await SchemaPreparation.validate(input, against: tool.input, budget: budget) else { throw CoreFailure.invalidInput }
            if let mirror { try await mirror(tool.headers, presence, budget) }
            try context.checkCancellation()
            if let plan = tool.rounds {
                do { result = try await InputCoordinator.execute(request, input: presence, context: context, plan: plan, protector: continuations, wire: wire, requestWork: requestWork, middleware: middleware) }
                catch let required as ExtensionCapabilityRequired { throw try await ProtocolRejection.missingExtension(required.identifier, wire: wire, budget: budget) }
            }
            else {
                guard params["requestState"] == nil, params["inputResponses"] == nil else { throw CoreFailure.invalidInput }
                do { result = try await MiddlewarePipeline.run(middleware, context: context) { try await tool.registration.handler(presence, context) } }
                catch let required as ExtensionCapabilityRequired { throw try await ProtocolRejection.missingExtension(required.identifier, wire: wire, budget: budget) }
                guard result.objectValue?["resultType"]?.stringValue == "complete" || snapshot.extensions.result(result, method: context.method, negotiated: context.extensions) != nil else { throw CoreFailure.invalidOutput }
            }
            try context.checkCancellation()
            if result.objectValue?["resultType"]?.stringValue == "complete", let output = tool.output {
                guard let structured = result.objectValue?["structuredContent"],
                      try await SchemaPreparation.validate(structured, against: output, budget: budget) else { throw CoreFailure.invalidOutput }
            }
        case .readResource:
            guard let uri = params["uri"]?.stringValue, uri.utf8.count <= 4096 else { throw CoreFailure.invalidInput }
            if let resource = snapshot.resourceIndex[ScalarText(uri)] {
                try await require(resource.requiredScopes, features: resource.requiredFeatures, context: context, wire: wire)
                if let plan = snapshot.roundPlans[ScalarText("resources/read\0" + uri)] { result = try await InputCoordinator.execute(request, input: .value(.string(uri)), context: context, plan: plan, protector: continuations, wire: wire, requestWork: requestWork, middleware: middleware) }
                else {
                    guard params["requestState"] == nil, params["inputResponses"] == nil else { throw CoreFailure.invalidInput }
                    result = try await MiddlewarePipeline.run(middleware, context: context) { try await resource.handler(.value(.string(uri)), context) }
                    guard result.objectValue?["resultType"]?.stringValue == "complete" || snapshot.extensions.result(result, method: context.method, negotiated: context.extensions) != nil else { throw CoreFailure.invalidOutput }
                }
            } else {
                var found: ResourceTemplateProvider?
                for template in snapshot.templates {
                    try await budget.consume(1)
                    guard context.principal.scopes.isSuperset(of: template.requiredScopes) else { continue }
                    if try await template.matches(uri, context) { found = template; break }
                    try context.checkCancellation()
                }
                guard let template = found else { throw CoreFailure.unknownProvider }
                try await require(template.requiredScopes, features: template.requiredFeatures, context: context, wire: wire)
                let key = ScalarText("resources/template\0" + template.definition.objectValue!["uriTemplate"]!.stringValue!)
                if let plan = snapshot.roundPlans[key] {
                    result = try await InputCoordinator.execute(request, input: .value(.string(uri)), context: context, plan: plan, protector: continuations, wire: wire, requestWork: requestWork, middleware: middleware)
                } else {
                    guard params["requestState"] == nil, params["inputResponses"] == nil else { throw CoreFailure.invalidInput }
                    result = try await MiddlewarePipeline.run(middleware, context: context) { try await template.handler(.value(.string(uri)), context) }
                    guard result.objectValue?["resultType"]?.stringValue == "complete" || snapshot.extensions.result(result, method: context.method, negotiated: context.extensions) != nil else { throw CoreFailure.invalidOutput }
                }
            }
        case .getPrompt:
            guard let name = params["name"]?.stringValue, name.utf8.count <= 4096 else { throw CoreFailure.invalidInput }
            guard let prompt = snapshot.promptIndex[ScalarText(name)] else { throw CoreFailure.unknownProvider }
            try await require(prompt.requiredScopes, features: prompt.requiredFeatures, context: context, wire: wire)
            let supplied = params["arguments"]?.objectValue
            for argument in prompt.definition.objectValue?["arguments"]?.arrayValue ?? [] {
                let object = argument.objectValue!, name = object["name"]!.stringValue!
                try await budget.consume(UInt64(name.utf8.count + (supplied?.count ?? 0) + 1))
                if object["required"]?.booleanValue == true, supplied?[name]?.stringValue == nil { throw CoreFailure.invalidInput }
            }
            if let plan = snapshot.roundPlans[ScalarText("prompts/get\0" + name)] { result = try await InputCoordinator.execute(request, input: params.presence(of: "arguments"), context: context, plan: plan, protector: continuations, wire: wire, requestWork: requestWork, middleware: middleware) }
            else {
                guard params["requestState"] == nil, params["inputResponses"] == nil else { throw CoreFailure.invalidInput }
                result = try await MiddlewarePipeline.run(middleware, context: context) { try await prompt.handler(params.presence(of: "arguments"), context) }
                guard result.objectValue?["resultType"]?.stringValue == "complete" || snapshot.extensions.result(result, method: context.method, negotiated: context.extensions) != nil else { throw CoreFailure.invalidOutput }
            }
        case .complete:
            guard let provider = snapshot.completion else { throw CoreFailure.unknownMethod }
            try await require(provider.requiredScopes, features: [], context: context, wire: wire)
            let page = try await MiddlewarePipeline.run(middleware, context: context) { try await provider.handler(.object(params), context) }
            try context.checkCancellation()
            struct Completion: Encodable {
                let values: [String]; let total: Int?; let hasMore: Bool
            }
            let complete = Completion(values: Array(page.values.prefix(100)), total: page.total ?? (page.hasMore ? nil : page.values.count),
                hasMore: page.hasMore || page.values.count > 100 || page.total.map { $0 > min(page.values.count, 100) } == true)
            let value = try await budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(complete) }
            result = try await RuntimeJSON.object([.init("resultType", value: .string("complete")), .init("completion", value: value)], budget: budget)
        default: throw CoreFailure.unknownMethod
        }
        try context.checkCancellation()
        guard !(await budget.snapshot.isTerminal), let definition = context.method.resultDefinition else { throw RequestBudget.Failure.exhausted }
        var final = result
        var outputLimits = JSONLimits.balanced; outputLimits[.outputBytes] = UInt64(maximumBytes)
        // Bound the provider's serialized representation before further server
        // lookups; native shape/live ceilings separately bound JSON work/space.
        let representation = try await budget.performJSON(limits: outputLimits) { try WireCodec.write(result, limits: $0) }
        try await budget.consume(UInt64(representation.count) * 16 + 1)
        let intermediate = result.objectValue?["resultType"]?.stringValue == "input_required"
        guard !intermediate || context.method.permitsInputRequired else { throw CoreFailure.invalidOutput }
        if result.objectValue?["resultType"]?.stringValue == "complete" && context.method.requiresCacheHints { final = try await snapshot.cache.apply(to: final, budget: budget) }
        let meta: JSON
        if let supplied = final.objectValue?["_meta"] { guard supplied.objectValue != nil else { throw CoreFailure.invalidOutput }; meta = supplied }
        else { meta = try await RuntimeJSON.object([], budget: budget) }
        let metadata = try await RuntimeJSON.overlay(meta, members: [.init(ProtocolMetadata.serverInfo, value: info)], budget: budget)
        final = try await RuntimeJSON.overlay(final, members: [.init("_meta", value: metadata)], budget: budget)
        if let supplemental = snapshot.extensions.result(final, method: context.method, negotiated: context.extensions) {
            guard try await SchemaPreparation.validate(final, against: supplemental.schema, budget: budget),
                  try await wire.validate(metadata, as: .ResultMetaObject, budget: budget) else { throw CoreFailure.invalidOutput }
        } else {
            guard try await wire.validate(final, as: intermediate ? .InputRequiredResult : definition, budget: budget) else { throw CoreFailure.invalidOutput }
            if !intermediate { try await validateBinary(final, method: context.method.core!, maximumBytes: maximumBytes, budget: budget) }
        }
        return final
    }

    private static func validateBinary(_ raw: JSON, method: WireMethod, maximumBytes: Int, budget: RequestBudget) async throws {
        // Only frozen content positions are binary. Application structuredContent
        // and permitted unknown metadata may contain ordinary fields named blob.
        let contents: [JSON]
        switch method {
        case .callTool: contents = raw.objectValue?["content"]?.arrayValue ?? []
        case .readResource: contents = raw.objectValue?["contents"]?.arrayValue ?? []
        case .getPrompt: contents = (raw.objectValue?["messages"]?.arrayValue ?? []).compactMap { $0.objectValue?["content"] }
        default: contents = []
        }
        guard contents.count <= 100_000 else { await budget.terminate(); throw CoreFailure.limit }
        for value in contents {
            try Task.checkCancellation()
            try await budget.consume(1)
            if let object = value.objectValue {
                if let type = object["type"]?.stringValue, type == "image" || type == "audio" {
                    guard let data = object["data"]?.stringValue else { throw CoreFailure.invalidOutput }
                    try await binary(data, maximumBytes: maximumBytes, budget: budget)
                }
                if method == .readResource, let blob = object["blob"]?.stringValue { try await binary(blob, maximumBytes: maximumBytes, budget: budget) }
                if object["type"]?.stringValue == "resource", let blob = object["resource"]?.objectValue?["blob"]?.stringValue {
                    try await binary(blob, maximumBytes: maximumBytes, budget: budget)
                }
            }
        }
    }
    private static func binary(_ text: String, maximumBytes: Int, budget: RequestBudget) async throws {
        guard text.utf8.count <= maximumBytes else { await budget.terminate(); throw CoreFailure.limit }
        try await budget.consume(UInt64(text.utf8.count) * 8 + 1)
        guard let data = Data(base64Encoded: text), data.count <= maximumBytes,
              data.base64EncodedString().utf8.elementsEqual(text.utf8) else { throw CoreFailure.invalidOutput }
    }
}
