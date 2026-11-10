// SPDX-License-Identifier: Apache-2.0
import JSON
import JSONSchema

public enum SchemaValidatorAdapter {
    /// An invalid verdict is a result. Operational failures propagate unchanged.
    public static func validate(_ value: JSON, against plan: CompiledJSONSchema,
                                limits: JSONLimits) throws -> JSONOperationReport<JSONValidationResult> {
        try JSONSchemaValidator(options: .init(limits: limits, output: .flag)).validateWithReport(value, against: plan)
    }
}
