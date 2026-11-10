// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

/// Dated normative sampling rules beyond the frozen structural schemas.
/// Model execution and tool execution remain host/client responsibilities.
enum SamplingValidation {
    static func blocks(_ message: JSON) -> [JSON] {
        guard let content = message.objectValue?["content"] else { return [] }
        return content.arrayValue ?? [content]
    }
    static func history(_ params: JSONObject, budget: RequestBudget) async throws {
        let messages = params["messages"]?.arrayValue ?? []
        guard messages.count <= 4096 else { throw CoreFailure.limit }
        var pending = Set<ScalarText>()
        for message in messages {
            let content = blocks(message), role = message.objectValue?["role"]?.stringValue
            guard content.count <= 1024 else { throw CoreFailure.limit }
            try await budget.consume(UInt64(content.count) * 16 + 1)
            let results = content.filter { $0.objectValue?["type"]?.stringValue == "tool_result" }
            let uses = content.filter { $0.objectValue?["type"]?.stringValue == "tool_use" }
            if !pending.isEmpty {
                let ids = results.compactMap { $0.objectValue?["toolUseId"]?.stringValue }.map(ScalarText.init)
                guard role == "user", results.count == content.count, Set(ids).count == ids.count, Set(ids) == pending else { throw CoreFailure.invalidInput }
                pending.removeAll()
            } else if !results.isEmpty { throw CoreFailure.invalidInput }
            if !uses.isEmpty {
                let ids = uses.compactMap { $0.objectValue?["id"]?.stringValue }.map(ScalarText.init)
                guard role == "assistant", Set(ids).count == ids.count else { throw CoreFailure.invalidInput }
                pending = Set(ids)
            }
            try await binary(content, budget: budget)
        }
        guard pending.isEmpty else { throw CoreFailure.invalidInput }
    }
    static func response(_ response: JSON, request: JSON, tools: [ScalarText: PreparedSchema], budget: RequestBudget) async throws {
        let content = blocks(response)
        guard content.count <= 1024 else { throw CoreFailure.limit }
        try await budget.consume(UInt64(content.count) * 16 + 1)
        let uses = content.filter { $0.objectValue?["type"]?.stringValue == "tool_use" }
        let mode = request.objectValue?["params"]?.objectValue?["toolChoice"]?.objectValue?["mode"]?.stringValue
        guard !(mode == "required" && uses.isEmpty), !(mode == "none" && !uses.isEmpty),
              !content.contains(where: { $0.objectValue?["type"]?.stringValue == "tool_result" }) else { throw CoreFailure.invalidInput }
        var ids = Set<ScalarText>()
        for use in uses {
            let o = use.objectValue!
            guard response.objectValue?["role"]?.stringValue == "assistant", let id = o["id"]?.stringValue,
                  ids.insert(ScalarText(id)).inserted, let name = o["name"]?.stringValue, let schema = tools[ScalarText(name)],
                  let input = o["input"], try await SchemaPreparation.validate(input, against: schema, budget: budget) else { throw CoreFailure.invalidInput }
        }
        try await binary(content, budget: budget)
    }
    private static func binary(_ content: [JSON], budget: RequestBudget) async throws {
        // Bounded iterative traversal only through frozen sampling content fields.
        var pending = content
        var count = 0
        while let block = pending.popLast() {
            count += 1
            guard count <= 4096 else { throw CoreFailure.limit }
            try await budget.consume(1)
            let o = block.objectValue, kind = o?["type"]?.stringValue
            if kind == "tool_result" { pending.append(contentsOf: o?["content"]?.arrayValue ?? []) }
            if kind == "image" || kind == "audio" {
                guard let text = o?["data"]?.stringValue else { throw CoreFailure.invalidInput }
                guard text.utf8.count <= 1_048_576 else { throw CoreFailure.limit }
                try await budget.consume(UInt64(text.utf8.count) * 8 + 1)
                guard let data = Data(base64Encoded: text), data.base64EncodedString().utf8.elementsEqual(text.utf8) else { throw CoreFailure.invalidInput }
            }
        }
    }
}
