// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import ExplorerDomain

struct RESTSearch: Decodable, Sendable {
    struct Page: Decodable, Sendable { let id: Int64; let key, title: String; let description: String? }
    let pages: [Page]
}
public struct RESTPage: Decodable, Sendable {
    public struct Revision: Decodable, Sendable { public let id: Int64; public let timestamp: String }
    public struct License: Decodable, Sendable { public let url, title: String }
    public let id: Int64
    public let key, title: String
    public let latest: Revision
    public let contentModel: String
    public let license: License
    public let html: String
    enum CodingKeys: String, CodingKey { case id, key, title, latest, contentModel = "content_model", license, html }
}
enum RESTCodec {
    static func decode<T: Decodable & Sendable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= 4_194_304 else { throw LiveFailure.bodyLimit }
        var limits = JSONLimits.balanced
        limits[.inputBytes] = 4_194_304; limits[.stringBytes] = 4_194_304
        limits[.maxDepth] = 32; limits[.workUnits] = 64_000_000
        let parsed = try JSONParser(options: .init(limits: limits)).parseWithReport(Array(data)).result
        return try JSONValueDecoder(options: .init(limits: limits)).decodeWithReport(type, from: parsed).result
    }
}
