// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Swift-MCP-Server",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MCPProtocol", targets: ["MCPProtocol"]),
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .library(name: "MCPStdio", targets: ["MCPStdio"]),
        .library(name: "MCPServiceLifecycle", targets: ["MCPServiceLifecycle"]),
        .library(name: "MCPObservability", targets: ["MCPObservability"]),
        .library(name: "MCPServerTesting", targets: ["MCPServerTesting"]),
        .library(name: "MCPClient", targets: ["MCPClient"]),
        .library(name: "MCPClientStdio", targets: ["MCPClientStdio"]),
        .library(name: "MCPTasks", targets: ["MCPTasks"]),
        .library(name: "MCPSkills", targets: ["MCPSkills"]),
    ],
    dependencies: [
        // Swift-JSON 1.9.0 (macOS 15 / iOS 18 / Linux, like this package).
        .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.9.0"),
        // CryptoKit on Apple platforms; the API-compatible swift-crypto elsewhere.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.12.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
    ],
    targets: [
        .target(name: "MCPProtocol", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), .product(name: "JSON", package: "swift-json"), .product(name: "JSONSchema", package: "swift-json")], resources: [.copy("Resources")]),
        .target(name: "MCPJSONSchemaAdapter", dependencies: ["MCPProtocol", .product(name: "JSON", package: "swift-json"), .product(name: "JSONSchema", package: "swift-json")]),
        .target(name: "MCPServer", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), "MCPProtocol", "MCPJSONSchemaAdapter", .product(name: "JSON", package: "swift-json"), .product(name: "JSONSchema", package: "swift-json"), .product(name: "Logging", package: "swift-log")]),
        .target(name: "MCPStdio", dependencies: ["MCPServer", "MCPProtocol", .product(name: "SystemPackage", package: "swift-system")]),
        .target(name: "MCPServiceLifecycle", dependencies: ["MCPServer", .product(name: "Logging", package: "swift-log"), .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")]),
        .target(name: "MCPObservability", dependencies: ["MCPServer", "MCPProtocol", .product(name: "Logging", package: "swift-log"), .product(name: "Metrics", package: "swift-metrics"), .product(name: "ServiceContextModule", package: "swift-service-context")]),
        .target(name: "MCPServerTesting", dependencies: ["MCPServer", "MCPProtocol", "MCPClient"]),
        .target(name: "MCPClient", dependencies: ["MCPProtocol", .product(name: "JSON", package: "swift-json")]),
        .target(name: "MCPClientStdio", dependencies: ["MCPClient", "MCPProtocol", .product(name: "JSON", package: "swift-json"),
            .product(name: "Subprocess", package: "swift-subprocess"),
            .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux]))]),
        .target(name: "MCPTasks", dependencies: ["MCPServer", "MCPProtocol", .product(name: "JSON", package: "swift-json"), .product(name: "JSONSchema", package: "swift-json")]),
        .target(name: "MCPSkills", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), "MCPServer", "MCPProtocol", .product(name: "JSON", package: "swift-json")]),
        .testTarget(name: "MCPProtocolTests", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), "MCPProtocol"], exclude: ["TEST_PLAN.md"], resources: [.copy("Resources")]),
        .testTarget(name: "MCPServerTests", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), "MCPServer", "MCPProtocol", "MCPServerTesting", .product(name: "JSON", package: "swift-json")], exclude: ["TEST_PLAN.md"], resources: [.copy("Resources")]),
        .testTarget(name: "MCPStdioTests", dependencies: ["MCPStdio", "MCPServerTesting", "MCPServer", "MCPProtocol", .product(name: "JSON", package: "swift-json"), .product(name: "SystemPackage", package: "swift-system")], exclude: ["TEST_PLAN.md"]),
        .testTarget(name: "MCPServiceLifecycleTests", dependencies: ["MCPServiceLifecycle", "MCPServerTesting", "MCPServer", "MCPProtocol", "MCPStdio", .product(name:"Logging",package:"swift-log"), .product(name:"ServiceLifecycle",package:"swift-service-lifecycle"), .product(name:"SystemPackage",package:"swift-system"), .product(name:"JSON",package:"swift-json")], exclude: ["TEST_PLAN.md"]),
        .testTarget(name: "MCPObservabilityTests", dependencies: ["MCPObservability", "MCPServerTesting", "MCPServer", "MCPProtocol", .product(name:"Logging",package:"swift-log"), .product(name:"Metrics",package:"swift-metrics"), .product(name:"ServiceContextModule",package:"swift-service-context"), .product(name:"JSON",package:"swift-json")], exclude: ["TEST_PLAN.md"]),
        .testTarget(name: "MCPTasksTests", dependencies: ["MCPTasks", "MCPServer", "MCPProtocol", "MCPServerTesting", .product(name: "JSON", package: "swift-json")]),
        .testTarget(name: "MCPClientTests", dependencies: ["MCPClient", "MCPClientStdio", "MCPServerTesting", "MCPServer", "MCPProtocol", .product(name: "JSON", package: "swift-json")]),
        .testTarget(name: "MCPSkillsTests", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), "MCPSkills", "MCPServer", "MCPProtocol", .product(name: "JSON", package: "swift-json")]),
        .testTarget(name: "MCPServerTestingTests", dependencies: ["MCPServerTesting", "MCPServer", "MCPProtocol", .product(name: "JSON", package: "swift-json")], exclude: ["TEST_PLAN.md"]),
        .testTarget(name: "MCPJSONSchemaAdapterTests", dependencies: ["MCPJSONSchemaAdapter", .product(name: "JSON", package: "swift-json"), .product(name: "JSONSchema", package: "swift-json")], exclude: ["TEST_PLAN.md"]),
    ],
    swiftLanguageModes: [.v6]
)
