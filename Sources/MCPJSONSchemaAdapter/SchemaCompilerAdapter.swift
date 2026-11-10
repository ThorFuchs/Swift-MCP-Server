// SPDX-License-Identifier: Apache-2.0
import JSON
import JSONSchema

public enum SchemaCompilerAdapter {
    /// Raw overload charges admission once inside the compiler. Registry is
    /// explicit/offline; no URL/file resolver or hidden document construction.
    public static func compile(_ raw: JSON, limits: JSONLimits,
                               registry: JSONSchemaRegistry = .empty) throws -> JSONOperationReport<CompiledJSONSchema> {
        try JSONSchemaCompiler(options: .init(limits: limits)).compileWithReport(raw, registry: registry)
    }
}
