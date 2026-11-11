// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription
let package = Package(name: "StdioFixture", platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
    .package(name: "Swift-MCP-Server", path: "../.."), .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1")],
    targets: [.executableTarget(name: "StdioFixture", dependencies: [
        .product(name:"MCPStdio",package:"Swift-MCP-Server"), .product(name:"MCPServer",package:"Swift-MCP-Server"),
        .product(name:"MCPProtocol",package:"Swift-MCP-Server"), .product(name:"JSON",package:"swift-json"),
        .product(name:"SystemPackage",package:"swift-system")])], swiftLanguageModes: [.v6])
