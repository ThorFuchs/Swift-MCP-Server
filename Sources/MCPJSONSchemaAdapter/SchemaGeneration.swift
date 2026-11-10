// SPDX-License-Identifier: Apache-2.0
import JSON
import JSONSchema

/// Registration owns a separate finite preparation account. Requests retain one
/// generation value; validator invocations own independent upstream evaluation.
public struct SchemaGeneration: Sendable {
    public let identifier: UInt64
    public let raw: JSON
    public let plan: CompiledJSONSchema
    public let document: JSONSchemaDocument
    public init(identifier: UInt64, raw: JSON, plan: CompiledJSONSchema, document: JSONSchemaDocument) {
        self.identifier = identifier; self.raw = raw; self.plan = plan; self.document = document
    }
}
