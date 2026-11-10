// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackgroundComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BackgroundComputerUse", targets: ["BackgroundComputerUse"]),
        // Also the engine for host apps: `bcu serve` (see docs/embedding.md).
        .executable(name: "bcu", targets: ["bcu"]),
        // The engine as a library, for a Swift host that runs it in process.
        .library(name: "BCUCore", targets: ["BCUCore", "BCUShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Private macOS APIs (CGVirtualDisplay, SkyLight) wrapped in plain C/ObjC calls.
        .target(
            name: "CPrivate",
            path: "Sources/CPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Wire protocol, tool catalog and socket client shared by the app and the CLI.
        .target(
            name: "BCUShared",
            path: "Sources/BCUShared",
            // A symlink to shared/tools.json, which the Windows app reads too,
            // and one to VERSION, so a `bcu` outside the app knows its version.
            resources: [.embedInCode("tools.json"), .embedInCode("VERSION")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Display, input, accessibility, capture, window management and the focus guard.
        .target(
            name: "BCUCore",
            dependencies: ["CPrivate", "BCUShared"],
            path: "Sources/BCUCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        // The menu bar app. Owns the virtual display and serves tool calls over a unix socket.
        .executableTarget(
            name: "BackgroundComputerUse",
            dependencies: ["BCUCore", "BCUShared", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BackgroundComputerUse",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI: `bcu mcp` (stdio MCP server for agents), `bcu serve` (the engine
        // without the menu bar app, for host apps) and `bcu call` (debugging).
        .executableTarget(
            name: "bcu",
            dependencies: ["BCUCore", "BCUShared"],
            path: "Sources/bcu",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BCUCoreTests",
            dependencies: ["BCUCore"],
            path: "Tests/BCUCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
