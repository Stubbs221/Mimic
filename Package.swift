// swift-tools-version: 6.2
//
//  Package.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import PackageDescription

let package = Package(
    name: "Mimic",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mimic", targets: ["Mimic"]),
        .executable(name: "TaskHost", targets: ["TaskHost"]),
        .executable(name: "MimicMCP", targets: ["MimicMCP"]),
        .executable(name: "MimicCLI", targets: ["MimicCLI"]),
        .executable(name: "MimicAppleProbe", targets: ["MimicAppleProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "MimicCore", dependencies: ["ZIPFoundation"], resources: [.process("Resources")]),
        .target(name: "XcodeMCPTransport", dependencies: ["MimicCore", .product(name: "MCP", package: "swift-sdk")]),
        .target(name: "AppleSimulatorMCP", dependencies: ["MimicCore", "XcodeMCPTransport", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "MimicAppleProbe", dependencies: ["MimicCore", "AppleSimulatorMCP"]),
        .executableTarget(name: "TaskHost"),
        .executableTarget(name: "MimicMCP", dependencies: ["MimicCore", .product(name: "MCP", package: "swift-sdk")], resources: [.process("Resources")]),
        .executableTarget(name: "MimicCLI", dependencies: ["MimicCore"]),
        .executableTarget(name: "Mimic", dependencies: ["MimicCore", "AppleSimulatorMCP", "XcodeMCPTransport", "SwiftTerm", .product(name: "Sparkle", package: "Sparkle"), .product(name: "MCP", package: "swift-sdk")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MimicCoreTests", dependencies: ["MimicCore", "ZIPFoundation"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MimicMCPTests", dependencies: ["MimicMCP", "MimicCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "MimicAppTests", dependencies: ["Mimic", "AppleSimulatorMCP", "ZIPFoundation"])
    ]
)
