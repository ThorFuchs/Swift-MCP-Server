// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let core = "swift-mcp-server"
let http = "swift-mcp-server-http"

let package = Package(
    name: "ResearchExplorer",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "research-explorer", targets: ["ResearchExplorer"]),
        .executable(name: "ResearchExplorerApp", targets: ["ResearchExplorerApp"]),
    ],
    dependencies: [
        // Core and HTTP by URL: the HTTP package depends on the core by URL, so a local path
        // dependency would create a second package with the same modules. Pre-1.0: `main`.
        .package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", branch: "main"),
        .package(url: "https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git", branch: "main"),
        .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        // Swift-HTML: source-audited HTML parsing (vendors SwiftSoup source only, with MIT notices).
        // Pre-1.0, so pinned to the 0.2 minor line whose public DOM traversal the normalizer uses.
        .package(url: "https://github.com/ThorFuchs/Swift-HTML.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(name: "ExplorerDomain"),
        .target(name: "WikimediaAccess", dependencies: ["ExplorerDomain",
            .product(name: "JSON", package: "swift-json"), .product(name: "SwiftHTML", package: "swift-html")],
            resources: [.copy("Fixtures")]),
        .target(name: "ExplorerMCP", dependencies: ["ExplorerDomain", "WikimediaAccess",
            .product(name: "MCPProtocol", package: core), .product(name: "MCPServer", package: core),
            .product(name: "MCPClient", package: core),
            .product(name: "JSON", package: "swift-json")],
            resources: [.copy("Contracts")]),
        .target(name: "ExplorerPresentation", dependencies: ["ExplorerDomain", "WikimediaAccess", "ExplorerMCP",
            .product(name: "MCPHTTP", package: http), .product(name: "MCPHTTPClient", package: http),
            .product(name: "MCPClient", package: core), .product(name: "MCPServer", package: core),
            .product(name: "MCPProtocol", package: core), .product(name: "MCPServiceLifecycle", package: core),
            .product(name: "JSON", package: "swift-json")]),
        .executableTarget(name: "ResearchExplorer", dependencies: ["ExplorerDomain", "WikimediaAccess", "ExplorerMCP",
            .product(name: "MCPProtocol", package: core), .product(name: "MCPServer", package: core),
            .product(name: "MCPStdio", package: core), .product(name: "MCPClient", package: core),
            .product(name: "MCPClientStdio", package: core), .product(name: "SystemPackage", package: "swift-system")]),
        .executableTarget(name: "ResearchExplorerApp", dependencies: ["ExplorerPresentation", "ExplorerDomain", "WikimediaAccess"]),
        .testTarget(name: "ExplorerDomainTests", dependencies: ["ExplorerDomain"]),
        .testTarget(name: "WikimediaAccessTests", dependencies: ["ExplorerDomain", "WikimediaAccess",
            .product(name: "JSON", package: "swift-json")]),
        .testTarget(name: "ExplorerMCPTests", dependencies: ["ExplorerDomain", "WikimediaAccess", "ExplorerMCP",
            .product(name: "MCPProtocol", package: core), .product(name: "MCPServer", package: core),
            .product(name: "MCPServerTesting", package: core), .product(name: "JSON", package: "swift-json"),
            .product(name: "MCPClient", package: core), .product(name: "MCPClientStdio", package: core)]),
        .testTarget(name: "ExplorerPresentationTests", dependencies: ["ExplorerPresentation", "ExplorerDomain", "WikimediaAccess",
            "ExplorerMCP", .product(name: "JSON", package: "swift-json"), .product(name: "MCPProtocol", package: core),
            .product(name: "MCPClient", package: core), .product(name: "MCPHTTPClient", package: http)]),
        .testTarget(name: "ExplorerAppTests", dependencies: ["ResearchExplorerApp", "ExplorerPresentation",
            "ExplorerDomain", "WikimediaAccess"]),
    ],
    swiftLanguageModes: [.v6]
)
