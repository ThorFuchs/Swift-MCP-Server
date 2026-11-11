// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "ExampleStdioServer",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.1"),
        .package(name: "Swift-MCP-Server", path: "../../")],
    targets: [.target(name: "ExampleSupport", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), 
        .product(name: "MCPProtocol", package: "Swift-MCP-Server"), .product(name: "MCPServer", package: "Swift-MCP-Server"), .product(name: "JSON", package: "swift-json")]),
        .executableTarget(name: "ExampleStdioServer", dependencies: ["ExampleSupport",
        .product(name: "MCPProtocol", package: "Swift-MCP-Server"), .product(name: "JSON", package: "swift-json"),
        .product(name: "SystemPackage", package: "swift-system"), .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "MCPServer", package: "Swift-MCP-Server"),
        .product(name: "MCPStdio", package: "Swift-MCP-Server"),
        .product(name: "MCPServiceLifecycle", package: "Swift-MCP-Server"),
    ])],
    swiftLanguageModes: [.v6]
)
