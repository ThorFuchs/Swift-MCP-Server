// SPDX-License-Identifier: Apache-2.0
import JSON
import JSONSchema

/// Only public report APIs. The owning server supplies remaining finite limits.
public enum SchemaInspectionAdapter {
    public static func inspect(_ document: JSONSchemaDocument, at pointer: JSONPointer,
                               limits: JSONLimits) throws -> JSONOperationReport<JSONSchemaNodeView> {
        try document.nodeWithReport(at: pointer, limits: limits)
    }
}
