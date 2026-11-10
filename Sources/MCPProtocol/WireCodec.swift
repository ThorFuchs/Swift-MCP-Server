// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON

public enum WireCodec {
    public static func parse(_ bytes: [UInt8], limits: JSONLimits) throws -> JSONOperationReport<JSON> {
        try JSONParser(options: .init(limits: limits)).parseWithReport(bytes)
    }
    public static func write(_ value: JSON, limits: JSONLimits) throws -> JSONOperationReport<Data> {
        try JSONWriter(options: .init(limits: limits, numberStyle: .preserved)).writeWithReport(value)
    }
}
