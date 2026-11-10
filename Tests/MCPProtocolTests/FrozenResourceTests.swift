// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Testing
@testable import MCPProtocol

// These owner-native tests are authored by SDK-S01, NOT_COMPILED / NOT_RUN.
// Expected bytes come from the immutable source resource, independently of the
// loader under test. The unchanged WRE catalog oracle remains consumer-owned.
private enum SchemaBundleLayout: String, CaseIterable, Sendable {
    case flat, macOS
}

private func sourceSchemaBytes() throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let bytes = try Data(contentsOf: root.appendingPathComponent("Sources/MCPProtocol/Resources/schema.json"))
    #expect(bytes.count == FrozenWireSchema.byteCount)
    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == FrozenWireSchema.sha256)
    return bytes
}

private func withSchemaBundle<Result>(layout: SchemaBundleLayout,
                                      body: (Bundle, URL) throws -> Result) throws -> Result {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MCPProtocol-SDKS01-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Swift-MCP-Server_MCPProtocol.bundle", isDirectory: true)
    let base = layout == .flat ? url : url.appendingPathComponent("Contents", isDirectory: true)
    let resources = layout == .flat ? url : base.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("Resources"),
                                            withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": "org.swift-mcp-server.schema.\(UUID().uuidString)",
                                "CFBundleName": "MCPProtocol", "CFBundlePackageType": "BNDL",
                                "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: base.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: url))
    return try body(bundle, resources.appendingPathComponent("Resources/schema.json"))
}

@Test func currentModuleReadsExactFrozenSchemaThroughPublicAPI() throws {
    let bytes = try FrozenWireSchema.read(maximumBytes: FrozenWireSchema.byteCount)
    let expected = try sourceSchemaBytes()
    #expect(bytes == expected)
    _ = try FrozenWireSchema.parse(bytes, limits: .balanced)
}

@Test(arguments: SchemaBundleLayout.allCases)
private func copiedSchemaUsesOwnedFlatOrCanonicalBundle(layout: SchemaBundleLayout) throws {
    let expected = try sourceSchemaBytes()
    try withSchemaBundle(layout: layout) { bundle, url in
        try expected.write(to: url)
        #expect(try FrozenWireSchema.schemaURL(bundleURL: bundle.bundleURL, resourceURL: bundle.resourceURL)
                    .standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(try FrozenWireSchema.read(maximumBytes: expected.count, in: bundle) == expected)
    }
}

@Test(arguments: SchemaBundleLayout.allCases)
private func missingOwnedSchemaDoesNotUseAlternateCopy(layout: SchemaBundleLayout) throws {
    let expected = try sourceSchemaBytes()
    try withSchemaBundle(layout: layout) { bundle, selected in
        // A readable, correctly hashed file at the other layout must not rescue
        // a missing selected resource. This includes the old duplicated path.
        let decoy = layout == .flat
            ? bundle.bundleURL.appendingPathComponent("Resources/Resources/schema.json")
            : bundle.bundleURL.appendingPathComponent("Resources/schema.json")
        try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try expected.write(to: decoy)
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(throws: CocoaError.self) {
            _ = try FrozenWireSchema.read(maximumBytes: expected.count, in: bundle)
        }
    }
}

@Test(arguments: SchemaBundleLayout.allCases)
private func corruptShortAndOversizedOwnedSchemasFailClosed(layout: SchemaBundleLayout) throws {
    let expected = try sourceSchemaBytes()
    try withSchemaBundle(layout: layout) { bundle, selected in
        var corrupt = expected; corrupt[corrupt.startIndex] ^= 1
        let alternatives = [corrupt, Data(expected.dropLast()), expected + Data([0])]
        for invalid in alternatives {
            try invalid.write(to: selected)
            #expect(throws: WireFailure.invalidRequest) {
                _ = try FrozenWireSchema.read(maximumBytes: Int.max, in: bundle)
            }
        }
    }
}

@Test func schemaByteAdmissionPrecedesMissingResourceIO() throws {
    try withSchemaBundle(layout: .flat) { bundle, _ in
        for maximum in [Int.min, -1, 0, FrozenWireSchema.byteCount - 1] {
            #expect(throws: WireFailure.limit) {
                _ = try FrozenWireSchema.read(maximumBytes: maximum, in: bundle)
            }
        }
    }
}

@Test func schemaLocatorRejectsForeignAndUnknownResourceRoots() throws {
    let root = URL(fileURLWithPath: "/unused/Swift-MCP-Server_MCPProtocol.bundle", isDirectory: true)
    for resources in [nil, URL(string: "https://example.invalid/Resources"),
                      URL(fileURLWithPath: "/other/Resources"),
                      root.appendingPathComponent("Resources/Resources", isDirectory: true)] {
        #expect(throws: WireFailure.invalidRequest) {
            _ = try FrozenWireSchema.schemaURL(bundleURL: root, resourceURL: resources)
        }
    }
}
