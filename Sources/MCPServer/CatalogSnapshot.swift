// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

public struct ServerCatalog: Sendable {
    public let tools: [ToolRegistration]
    public let resources: [ResourceProvider]
    public let templates: [ResourceTemplateProvider]
    public let prompts: [PromptProvider]
    public let completion: CompletionProvider?
    public let extensions: [ExtensionRegistration]
    public let cache: CacheHints
    /// Host opt-in advertisement for production subscriptions/listen publication.
    /// Empty preserves a static catalog's discovery metadata. Replacement does
    /// not broadcast automatically; the host still supplies an explicit audience.
    public let listChanged: Set<WireMethod>
    public init(tools: [ToolRegistration] = [], resources: [ResourceProvider] = [],
        templates: [ResourceTemplateProvider] = [], prompts: [PromptProvider] = [],
        completion: CompletionProvider? = nil, extensions: [ExtensionRegistration] = [], cache: CacheHints? = nil,
        listChanged: Set<WireMethod> = []) throws {
        guard listChanged.isSubset(of: [.listTools, .listResources, .listPrompts]) else { throw CoreFailure.invalidPolicy }
        self.tools = tools; self.resources = resources; self.templates = templates; self.prompts = prompts
        self.completion = completion; self.extensions = extensions; self.cache = try cache ?? CacheHints()
        self.listChanged = listChanged
    }
}
struct PreparedTool: Sendable {
    let registration: ToolRegistration
    let name: ScalarText
    let input: PreparedSchema
    let output: PreparedSchema?
    let headers: [HeaderDeclaration]
    let rounds: PreparedRoundPlan?
}
struct CatalogSnapshot: Sendable {
    let generation: UInt64
    let tools: [PreparedTool]
    let resources: [ResourceProvider]
    let templates: [ResourceTemplateProvider]
    let prompts: [PromptProvider]
    let completion: CompletionProvider?
    let extensions: ExtensionRegistry
    let cache: CacheHints
    let listChanged: Set<WireMethod>
    let roundPlans: [ScalarText: PreparedRoundPlan]
    let weight: UInt64
    let toolIndex: [ScalarText: PreparedTool]
    let resourceIndex: [ScalarText: ResourceProvider]
    let promptIndex: [ScalarText: PromptProvider]

    static func prepare(_ catalog: ServerCatalog, generation: UInt64, wire: PreparedWire,
                        configuration: ServerConfiguration, budget: RequestBudget) async throws -> Self {
        try await budget.consume(UInt64(catalog.listChanged.count) * 64)
        var count = 0
        for addition in [catalog.tools.count, catalog.resources.count, catalog.templates.count, catalog.prompts.count] {
            guard addition <= configuration.catalogEntries - count else { throw CoreFailure.limit }; count += addition
        }
        guard catalog.extensions.count <= 64 else { throw CoreFailure.limit }
        let scopes = catalog.tools.map(\.requiredScopes) + catalog.resources.map(\.requiredScopes) + catalog.templates.map(\.requiredScopes) + catalog.prompts.map(\.requiredScopes) + [catalog.completion?.requiredScopes ?? []]
        for scope in scopes { try RuntimePolicy.scopes(scope); try await budget.consume(UInt64(scope.reduce(0) { $0 + $1.description.utf8.count + 1 })) }
        let empty = try await RuntimeJSON.object([], budget: budget)
        let declared = try await RuntimeJSON.object(catalog.extensions.map { .init($0.identifier.description, value: empty) }, budget: budget)
        let capabilities = try await RuntimeJSON.object([.init("extensions", value: declared)], budget: budget)
        guard try await wire.validate(capabilities, as: .ClientCapabilities, budget: budget) else { throw CoreFailure.invalidInput }
        var weight: UInt64 = 0
        func admit(_ raw: JSON, as definition: FrozenWireDefinition, identity: String) async throws -> ScalarText {
            guard try await wire.validate(raw, as: definition, budget: budget),
                  let name = raw.objectValue?[identity]?.stringValue, !name.isEmpty, name.utf8.count <= 4096 else { throw CoreFailure.invalidInput }
            let data = try await budget.performJSON { try WireCodec.write(raw, limits: $0) }
            let addition = UInt64(data.count) * 16 + 4096
            guard addition <= 33_554_432 - weight else { throw CoreFailure.limit }
            weight += addition
            return ScalarText(name)
        }
        var names = Set<ScalarText>(), tools: [PreparedTool] = [], roundPlans: [ScalarText: PreparedRoundPlan] = [:]
        func rounds(_ provider: MultiRoundProvider?, definition: JSON, scopes: Set<ScalarText>, features: Set<ClientFeature>) async throws -> PreparedRoundPlan? {
            guard let provider else { return nil }
            let plan = try await PreparedRoundPlan.prepare(provider, definition: definition, scopes: scopes, features: features, wire: wire, generation: generation, budget: budget)
            guard plan.weight <= 33_554_432 - weight else { throw CoreFailure.limit }; weight += plan.weight
            return plan
        }
        for tool in catalog.tools {
            let name = try await admit(tool.definition, as: .Tool, identity: "name")
            guard names.insert(name).inserted else { throw CoreFailure.duplicate }
            let object = tool.definition.objectValue!
            let input = try await SchemaPreparation.prepare(object["inputSchema"]!, identifier: generation, budget: budget)
            let output: PreparedSchema?
            if let raw = object["outputSchema"] { output = try await SchemaPreparation.prepare(raw, identifier: generation, budget: budget) } else { output = nil }
            let headers = try await SchemaPreparation.headers(for: input, budget: budget)
            let addition = input.logicalRetainedUpperBound + (output?.logicalRetainedUpperBound ?? 0)
            guard addition <= 33_554_432 - weight else { throw CoreFailure.limit }; weight += addition
            let plan = try await rounds(tool.continuation, definition: tool.definition, scopes: tool.requiredScopes, features: tool.requiredFeatures)
            tools.append(.init(registration: tool, name: name, input: input, output: output, headers: headers, rounds: plan))
        }
        names.removeAll()
        for resource in catalog.resources {
            let uri = try await admit(resource.definition, as: .Resource, identity: "uri")
            guard names.insert(uri).inserted else { throw CoreFailure.duplicate }
            if let plan = try await rounds(resource.continuation, definition: resource.definition, scopes: resource.requiredScopes, features: resource.requiredFeatures) { roundPlans[ScalarText("resources/read\0" + uri.description)] = plan }
        }
        names.removeAll()
        for template in catalog.templates {
            let value = try await admit(template.definition, as: .ResourceTemplate, identity: "uriTemplate")
            guard names.insert(value).inserted else { throw CoreFailure.duplicate }
            _ = try await URITemplate.prepare(value.description, budget: budget)
            if let plan = try await rounds(template.continuation, definition: template.definition, scopes: template.requiredScopes, features: template.requiredFeatures) { roundPlans[ScalarText("resources/template\0" + value.description)] = plan }
        }
        names.removeAll()
        for prompt in catalog.prompts {
            let name = try await admit(prompt.definition, as: .Prompt, identity: "name")
            guard names.insert(name).inserted else { throw CoreFailure.duplicate }
            if let plan = try await rounds(prompt.continuation, definition: prompt.definition, scopes: prompt.requiredScopes, features: prompt.requiredFeatures) { roundPlans[ScalarText("prompts/get\0" + name.description)] = plan }
            var arguments = Set<ScalarText>()
            for argument in prompt.definition.objectValue?["arguments"]?.arrayValue ?? [] {
                let key = ScalarText(argument.objectValue!["name"]!.stringValue!)
                guard arguments.insert(key).inserted else { throw CoreFailure.duplicate }
            }
        }
        let extensions = try await ExtensionRegistry.prepare(catalog.extensions, generation: generation, budget: budget, wire: wire)
        guard extensions.weight <= 33_554_432 - weight else { throw CoreFailure.limit }; weight += extensions.weight
        let sortedTools = tools.sorted { $0.name.description.utf8.lexicographicallyPrecedes($1.name.description.utf8) }
        func sort<Value>(_ values: [Value], key: (Value) -> String) -> [Value] { values.sorted { key($0).utf8.lexicographicallyPrecedes(key($1).utf8) } }
        return .init(generation: generation, tools: sortedTools,
            resources: sort(catalog.resources, key: { $0.definition.objectValue!["uri"]!.stringValue! }),
            templates: sort(catalog.templates, key: { $0.definition.objectValue!["uriTemplate"]!.stringValue! }),
            prompts: sort(catalog.prompts, key: { $0.definition.objectValue!["name"]!.stringValue! }),
            completion: catalog.completion, extensions: extensions, cache: catalog.cache, listChanged: catalog.listChanged, roundPlans: roundPlans, weight: weight,
            toolIndex: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }),
            resourceIndex: Dictionary(uniqueKeysWithValues: catalog.resources.map { (ScalarText($0.definition.objectValue!["uri"]!.stringValue!), $0) }),
            promptIndex: Dictionary(uniqueKeysWithValues: catalog.prompts.map { (ScalarText($0.definition.objectValue!["name"]!.stringValue!), $0) }))
    }
}

actor CatalogStore {
    struct Lease: Sendable { let snapshot: CatalogSnapshot }
    private var current: CatalogSnapshot
    private var held: [UInt64: (snapshot: CatalogSnapshot, count: Int)] = [:]
    private var preparing = false
    private let limit: UInt64
    init(_ current: CatalogSnapshot, wireWeight: UInt64) throws {
        guard wireWeight < 33_554_432, current.weight <= 33_554_432 - wireWeight else { throw CoreFailure.limit }
        self.current = current; limit = 33_554_432 - wireWeight
    }
    func acquire() -> Lease {
        let id = current.generation
        let count = held[id]?.count ?? 0; held[id] = (current, count + 1)
        return .init(snapshot: current)
    }
    func release(_ lease: Lease) throws {
        let id = lease.snapshot.generation
        guard let entry = held[id], entry.count > 0 else { throw CoreFailure.staleGeneration }
        if entry.count == 1 { held.removeValue(forKey: id) } else { held[id] = (entry.snapshot, entry.count - 1) }
    }
    func replace(_ catalog: ServerCatalog, wire: PreparedWire, configuration: ServerConfiguration, budget: RequestBudget) async throws {
        guard !preparing, current.generation < UInt64.max else { throw CoreFailure.staleGeneration }
        preparing = true
        do {
            let next = try await CatalogSnapshot.prepare(catalog, generation: current.generation + 1, wire: wire, configuration: configuration, budget: budget)
            let retained = held.values.reduce(UInt64(0)) { $0 + $1.snapshot.weight }
            guard retained <= limit, next.weight <= limit - retained else { throw CoreFailure.limit }
            current = next; preparing = false
        } catch { preparing = false; throw error }
    }
    var generation: UInt64 { current.generation }
    var activeLeases: Int { held.values.reduce(0) { $0 + $1.count } }
}
